import SwiftUI
import AVFoundation
import Vision
import CoreImage
import Combine
import PhotosUI

final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    @Published var message = "Læg ét kort i rammen"
    @Published var denied = false
    @Published var available = true
    @Published var detectionState = 0
    @Published var captured: Data?
    var autoCapture = true
    private let queue = DispatchQueue(label: "kortscanner.camera")
    private let ciContext = CIContext()
    private var slabMode = false
    private var configured = false
    private var captureRequested = false
    private var stableFrames = 0
    private var previousRect: CGRect?
    private var lastFrameTime: CFTimeInterval = 0
    private var cooldownUntil: CFTimeInterval = 0

    func start() {
        Task { @MainActor in
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            denied = !allowed
            guard allowed else { DebugLog.shared.info("Kameraadgang mangler"); return }
            denied = false
            queue.async { [weak self] in self?.configureAndStart() }
        }
    }
    func stop() { queue.async { [weak self] in self?.session.stopRunning() } }
    func captureNow() { queue.async { [weak self] in self?.captureRequested = true } }
    func resume() {
        DispatchQueue.main.async { self.captured = nil; self.detectionState = 0 }
        queue.async { [weak self] in
            self?.stableFrames = 0
            self?.previousRect = nil
            self?.captureRequested = false
            self?.cooldownUntil = CACurrentMediaTime() + 2
        }
    }
    func setSlab(_ value: Bool) { queue.async { [weak self] in self?.slabMode = value } }
    func setAuto(_ value: Bool) { queue.async { [weak self] in self?.autoCapture = value } }

    private func configureAndStart() {
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.available = false; self.message = "Kameraet kunne ikke startes" }
                return
            }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { session.commitConfiguration(); return }
            session.addOutput(output)
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            session.commitConfiguration()
            configured = true
        }
        if !session.isRunning { session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrameTime > 0.20, now > cooldownUntil,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = now
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 6
        request.minimumConfidence = 0.65
        request.minimumAspectRatio = 0.45
        request.maximumAspectRatio = 0.85
        request.minimumSize = 0.22
        request.quadratureTolerance = 22
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
            let rectangles = request.results ?? []
            // Prefer the inner card over a large sleeve/slab when both are visible.
            let rect = rectangles.filter { $0.boundingBox.contains(CGPoint(x: 0.5, y: 0.5)) }
                .min { abs($0.boundingBox.width / $0.boundingBox.height - 0.716) < abs($1.boundingBox.width / $1.boundingBox.height - 0.716) }
                ?? rectangles.first
            guard let rect else {
                stableFrames = 0
                previousRect = nil
                publish("Find kortets kanter i rammen")
                if captureRequested { capture(buffer: buffer, rect: nil); captureRequested = false }
                return
            }
            let box = rect.boundingBox
            let sharp = Self.sharpness(buffer, region: box)
            if let previous = previousRect,
               abs(box.midX - previous.midX) < 0.012,
               abs(box.midY - previous.midY) < 0.012,
               abs(box.width - previous.width) < 0.015,
               abs(box.height - previous.height) < 0.015, sharp > 12 {
                stableFrames += 1
            } else { stableFrames = 0 }
            previousRect = box
            publish(sharp > 12 ? "Hold stille … \(min(stableFrames, 5))/5" : "Vent på skarpt billede")
            if captureRequested || (autoCapture && stableFrames >= 5) {
                captureRequested = false
                capture(buffer: buffer, rect: rect)
            }
        } catch {
            publish("Kan ikke finde kanterne. Brug udløserknappen.")
        }
    }

    private func publish(_ text: String) {
        DispatchQueue.main.async { if self.message != text { self.message = text }; self.detectionState = text.hasPrefix("Hold stille") ? 1 : 0 }
    }

    private func capture(buffer: CVPixelBuffer, rect: VNRectangleObservation?) {
        cooldownUntil = CACurrentMediaTime() + 3600
        var image = CIImage(cvPixelBuffer: buffer)
        if let rect, !slabMode {
            let w = image.extent.width, h = image.extent.height
            let point: (CGPoint) -> CIVector = { CIVector(x: $0.x * w, y: $0.y * h) }
            image = image.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": point(rect.topLeft), "inputTopRight": point(rect.topRight),
                "inputBottomLeft": point(rect.bottomLeft), "inputBottomRight": point(rect.bottomRight)
            ])
        }
        guard let cg = ciContext.createCGImage(image, from: image.extent),
              let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.92) else {
            cooldownUntil = CACurrentMediaTime() + 1
            publish("Billedet kunne ikke gemmes. Prøv igen.")
            return
        }
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.detectionState = 2
            self.captured = data
        }
    }

    static func sharpness(_ buffer: CVPixelBuffer, region: CGRect) -> Double {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return 0 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let x0 = max(2, Int(region.minX * Double(width)))
        let x1 = min(width - 2, Int(region.maxX * Double(width)))
        let y0 = max(2, Int((1 - region.maxY) * Double(height)))
        let y1 = min(height - 2, Int((1 - region.minY) * Double(height)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum = 0.0, count = 0.0
        for y in stride(from: y0, to: y1, by: 6) {
            for x in stride(from: x0, to: x1, by: 6) {
                let p = y * row + x * 4
                let center = Int(bytes[p + 1])
                let laplacian = 4 * center - Int(bytes[p - 4 + 1]) - Int(bytes[p + 4 + 1]) - Int(bytes[p - row + 1]) - Int(bytes[p + row + 1])
                sum += Double(abs(laplacian))
                count += 1
            }
        }
        return count > 0 ? sum / count : 0
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {}
}

struct CaptureView: View {
    @Binding var batch: Bool
    let paused: Bool
    let onFinished: ([Data], Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @StateObject private var camera = CameraEngine()
    @ObservedObject private var session = BatchSession.shared
    @AppStorage("scanSlabMode") private var slabMode = false
    @State private var pages: [Data] = []
    @State private var photos: [PhotosPickerItem] = []
    @State private var askCloseup = false
    @State private var askRemove = false
    private var title: String { pages.isEmpty ? "Forside" : pages.count == 1 ? "Bagside" : "Nærbillede (valgfrit)" }
    private var frameColor: Color { camera.detectionState == 2 ? .green : camera.detectionState == 1 ? Theme.accent : .white }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(session: camera.session).ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.7), .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
                VStack(spacing: 16) {
                    Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center).padding(.top, 14)
                    Text(batch ? session.message : pages.isEmpty ? "Hold kortet stille i rammen" : pages.count == 1 ? "Vend kortet og hold det stille" : "Scan nummeret, eller gå videre")
                        .font(.headline).multilineTextAlignment(.center).lineLimit(3)
                    if slabMode { Text("Slab-tilstand · hele etiketten bevares").font(.caption) }
                    Spacer(minLength: 8)
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(frameColor, lineWidth: 3)
                        .shadow(color: frameColor.opacity(0.35), radius: 14)
                        .aspectRatio(0.716, contentMode: .fit)
                        .frame(maxHeight: geometry.size.height * 0.48)
                        .animation(reducedMotion ? nil : .spring(response: 0.35), value: camera.detectionState)
                    Text(camera.message).font(.subheadline.bold()).padding(10).background(.ultraThinMaterial, in: Capsule())
                    Spacer(minLength: 8)
                    if camera.denied {
                        Text("Giv kameraadgang i Indstillinger.").font(.headline)
                        Button("Åbn Indstillinger") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.frame(minHeight: 56)
                    }
                    if !pages.isEmpty && !batch {
                        HStack {
                            Button(pages.count == 1 ? "Kun forside" : "Gå videre") { finish() }.frame(minHeight: 56)
                            Spacer()
                            Button("Fortryd side") { askRemove = true }.frame(minHeight: 56)
                        }
                    }
                    HStack(spacing: 18) {
                        PhotosPicker(selection: $photos, maxSelectionCount: 3, matching: .images) {
                            Label("Fotos", systemImage: "photo.on.rectangle").labelStyle(.verticalScan)
                        }.frame(maxWidth: .infinity, minHeight: 56).disabled(paused)
                        Button { camera.captureNow() } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "camera.fill").font(.title).frame(width: 68, height: 68).background(Theme.accent, in: Circle()).foregroundStyle(.black)
                                Text("Tag billede").font(.caption.bold())
                            }
                        }.disabled(paused || camera.denied)
                        Button { batch.toggle() } label: {
                            Label(batch ? "Batch til" : "Batch fra", systemImage: batch ? "square.stack.3d.up.fill" : "square.stack.3d.up").labelStyle(.verticalScan)
                        }.frame(maxWidth: .infinity, minHeight: 56)
                    }.padding(16).glassPanel()
                }.padding(.horizontal, 20).padding(.bottom, 70).foregroundStyle(.white)
                if paused { Color.black.opacity(0.6).ignoresSafeArea(); ProgressView("Læser kortet …").tint(Theme.accent).foregroundStyle(.white) }
            }
        }
        .onAppear { camera.setSlab(slabMode); if !paused { camera.start() } }
        .onDisappear { camera.stop() }
        .onChange(of: slabMode) { _, value in camera.setSlab(value) }
        .onChange(of: paused) { _, value in if value { camera.stop() } else { camera.resume(); camera.start() } }
        .onChange(of: camera.captured) { _, data in
            guard let data, !paused else { return }
            pages.append(data)
            if batch {
                if pages.count == 2 { let images = pages; pages = []; onFinished(images, true) }
                camera.resume()
            } else if pages.count == 2 { askCloseup = true }
            else if pages.count >= 3 { finish() }
            else { camera.resume() }
            Task { await session.phase(title) }
        }
        .onChange(of: batch) { _, value in Task { if value { await session.start() } else { await session.stop() } } }
        .onChange(of: photos) { _, selection in Task {
            guard !selection.isEmpty else { return }
            var imported: [Data] = []
            for photo in selection {
                if let data = try? await photo.loadTransferable(type: Data.self), let normalized = ScanView.normalize(data) { imported.append(normalized) }
            }
            if !imported.isEmpty { onFinished(imported, batch) }
            photos = []
        }}
        .onChange(of: scenePhase) { _, phase in if phase == .active && !paused { camera.start() } else { camera.stop() } }
        .confirmationDialog("Vil du scanne kortnummeret tæt på?", isPresented: $askCloseup, titleVisibility: .visible) {
            Button("Gå videre med kortet") { finish() }
            Button("Scan nærbillede") { camera.resume() }
        }
        .confirmationDialog("Fjern den seneste scannede side?", isPresented: $askRemove, titleVisibility: .visible) {
            Button("Fjern side", role: .destructive) {
                let old = pages
                _ = pages.popLast()
                camera.resume()
                ActionHistory.shared.record("scannet side", undo: { pages = old }, redo: { pages = Array(old.dropLast()) })
            }
        }
    }
    private func finish() {
        guard !pages.isEmpty else { return }
        let images = pages
        pages = []
        camera.stop()
        onFinished(images, false)
    }
}
struct VerticalScanLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 7) { configuration.icon.font(.title2); configuration.title.font(.caption.bold()) }.multilineTextAlignment(.center)
    }
}
extension LabelStyle where Self == VerticalScanLabelStyle { static var verticalScan: Self { Self() } }
