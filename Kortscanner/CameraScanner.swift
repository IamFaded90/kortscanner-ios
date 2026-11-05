import SwiftUI
import AVFoundation
import Vision
import CoreImage
import Combine

final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    @Published var message = "Læg ét kort i rammen"
    @Published var denied = false
    @Published var available = true
    @Published var captured: Data?
    var autoCapture = true
    private let queue = DispatchQueue(label: "kortscanner.camera")
    private let ciContext = CIContext()
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
        DispatchQueue.main.async { self.captured = nil }
        queue.async { [weak self] in
            self?.stableFrames = 0
            self?.previousRect = nil
            self?.captureRequested = false
            self?.cooldownUntil = CACurrentMediaTime() + 2
        }
    }
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
        DispatchQueue.main.async { if self.message != text { self.message = text } }
    }

    private func capture(buffer: CVPixelBuffer, rect: VNRectangleObservation?) {
        cooldownUntil = CACurrentMediaTime() + 3600
        var image = CIImage(cvPixelBuffer: buffer)
        if let rect {
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
    let onFinished: ([Data]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraEngine()
    @State private var pages: [Data] = []
    @State private var preview: UIImage?
    @State private var automatic = true

    private var title: String { pages.isEmpty ? "Scan forsiden" : pages.count == 1 ? "Vend kortet — scan bagsiden" : "Nærbillede af kortnummer" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Button("Annuller") { dismiss() }
                    Spacer()
                    Toggle("Auto", isOn: $automatic).fixedSize().onChange(of: automatic) { _, value in camera.setAuto(value) }
                }
                Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                Spacer()
                RoundedRectangle(cornerRadius: 20).stroke(Theme.accent, lineWidth: 3)
                    .aspectRatio(0.716, contentMode: .fit).frame(maxWidth: 300)
                    .overlay(alignment: .bottom) { Text(camera.message).font(.callout.bold()).padding(10).background(.ultraThinMaterial, in: Capsule()).offset(y: 50) }
                Spacer()
                if camera.denied {
                    Text("Giv adgang til kameraet i Indstillinger.")
                    Button("Åbn Indstillinger") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.buttonStyle(.borderedProminent)
                }
                if !camera.available { Text("Kameraet er ikke tilgængeligt.") }
                HStack(spacing: 24) {
                    if !pages.isEmpty {
                        Button(pages.count == 1 ? "Kun forside" : "Spring nærbillede over") { finish() }
                    }
                    Button { camera.captureNow() } label: {
                        Image(systemName: "camera.fill").font(.largeTitle).padding(20).background(.white, in: Circle()).foregroundStyle(.black)
                    }.accessibilityLabel("Tag billede")
                }
            }.padding(24).foregroundStyle(.white)
            if let preview {
                Color.black.opacity(0.85).ignoresSafeArea()
                VStack(spacing: 20) {
                    Text("Er billedet skarpt?").font(.title2.bold())
                    Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 450)
                    HStack {
                        Button("Tag om") { self.preview = nil; camera.resume() }.buttonStyle(.bordered)
                        Button("Brug billede") {
                            if let data = camera.captured { pages.append(data) }
                            self.preview = nil
                            if pages.count >= 3 { finish() }
                            else { camera.resume() }
                        }.buttonStyle(.borderedProminent)
                    }
                }.padding().foregroundStyle(.white)
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.captured) { _, data in
            if let data { preview = UIImage(data: data) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() }
            else { camera.stop() }
        }
    }
    private func finish() { camera.stop(); onFinished(pages); dismiss() }
}
