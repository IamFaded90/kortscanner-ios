import SwiftUI
import UIKit
import CoreMotion
import Combine

enum ImageRotation {
    static func clockwise(_ data: Data) -> Data? {
        guard let source = UIImage(data: data) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let width = source.size.width * source.scale
        let height = source.size.height * source.scale
        guard width > 0, height > 0 else { return nil }
        return UIGraphicsImageRenderer(size: CGSize(width: height, height: width), format: format).image { context in
            context.cgContext.translateBy(x: height, y: 0)
            context.cgContext.rotate(by: .pi / 2)
            source.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }.jpegData(compressionQuality: 0.95)
    }
}

@MainActor
final class CameraLevelMonitor: ObservableObject {
    @Published var degrees = 0.0
    @Published var available = false
    private let motion = CMMotionManager()
    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.12
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            guard let sample else { return }
            // Angle from horizontal; works with either face of the phone pointing down.
            self?.degrees = acos(min(1, max(0, abs(sample.gravity.z)))) * 180 / .pi
            self?.available = true
        }
    }
    func stop() { motion.stopDeviceMotionUpdates() }
}

struct CameraLevelView: View {
    @StateObject private var level = CameraLevelMonitor()
    var body: some View {
        VStack(spacing: 5) {
            Label(level.available ? "Vaterpas · \(Int(level.degrees.rounded()))°" : "Vaterpas ikke tilgængeligt",
                  systemImage: level.available && level.degrees <= 3 ? "checkmark.circle.fill" : "level")
                .font(.subheadline.bold())
                .foregroundStyle(level.available && level.degrees <= 3 ? Color.green : Color.white)
            Text("Læg kortet fladt. Hold telefonen parallelt over det.").font(.caption)
        }.padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
            .onAppear { level.start() }.onDisappear { level.stop() }
    }
}

struct CenteringRatios: Equatable {
    let left: Int
    let top: Int
    var horizontal: String { "\(left)/\(100 - left)" }
    var vertical: String { "\(top)/\(100 - top)" }
    static func measure(outer: CGRect, inner: CGRect) -> CenteringRatios? {
        let values = [outer.minX, outer.minY, outer.width, outer.height, inner.minX, inner.minY, inner.width, inner.height]
        guard values.allSatisfy({ $0.isFinite }), outer.width > 0, outer.height > 0,
              inner.width > 0, inner.height > 0,
              inner.minX >= outer.minX, inner.maxX <= outer.maxX,
              inner.minY >= outer.minY, inner.maxY <= outer.maxY else { return nil }
        let left = inner.minX - outer.minX, right = outer.maxX - inner.maxX
        let top = inner.minY - outer.minY, bottom = outer.maxY - inner.maxY
        guard left + right > 0.000001, top + bottom > 0.000001 else { return nil }
        return .init(left: Int((left / (left + right) * 100).rounded()),
                     top: Int((top / (top + bottom) * 100).rounded()))
    }
}

private struct CenteringSnapshot {
    var edges: [[Double]]
    var adjusted: [Bool]
}

struct CenteringView: View {
    let front: Data
    let back: Data?
    @Environment(\.dismiss) private var dismiss
    @State private var side = 0
    @State private var boundary = 0
    @State private var edges = [Array([0.0, 1.0, 0.0, 1.0, 0.05, 0.95, 0.05, 0.95]),
                                Array([0.0, 1.0, 0.0, 1.0, 0.05, 0.95, 0.05, 0.95])]
    @State private var history: [CenteringSnapshot] = []
    @State private var copied = false
    @State private var adjusted = [false, false]
    private func box(_ offset: Int) -> CGRect {
        let e = edges[side]
        return CGRect(x: e[offset], y: e[offset + 2], width: e[offset + 1] - e[offset], height: e[offset + 3] - e[offset + 2])
    }
    private var result: CenteringRatios? { CenteringRatios.measure(outer: box(0), inner: box(4)) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Mål centrering med kantlinjer").font(.title2.bold())
                    Text("Brug et skarpt, ret foto uden perspektivskævhed. Gul ramme følger selve kortet, blå ramme følger trykkets indvendige kant. Slab og sleeve skal være uden for den gule ramme.").font(.subheadline)
                    Picker("Side", selection: $side) {
                        Text("Forside").tag(0)
                        if back != nil { Text("Bagside").tag(1) }
                    }.pickerStyle(.segmented)
                    if let image = UIImage(data: side == 0 ? front : back ?? front) {
                        Image(uiImage: image).resizable().aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                            .overlay {
                                GeometryReader { geometry in
                                    ForEach(0..<2) { i in
                                        let b = box(i * 4)
                                        if b.width > 0 && b.height > 0 {
                                            Rectangle().path(in: CGRect(x: b.minX * geometry.size.width, y: b.minY * geometry.size.height, width: b.width * geometry.size.width, height: b.height * geometry.size.height))
                                                .stroke(i == 0 ? Theme.accent : Theme.blue, lineWidth: 2)
                                        }
                                    }
                                }.allowsHitTesting(false)
                            }.frame(maxHeight: 440)
                    }
                    Picker("Kantlinjer", selection: $boundary) {
                        Text("Gul · kortkant").tag(0)
                        Text("Blå · trykkant").tag(1)
                    }.pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(0..<4) { i in
                            let index = boundary * 4 + i
                            Text(["Venstre", "Højre", "Top", "Bund"][i]).font(.headline)
                            Slider(value: Binding(get: { edges[side][index] }, set: { edges[side][index] = $0; adjusted[side] = true; copied = false }),
                                   in: 0...1, step: 0.001, onEditingChanged: { editing in if editing { history.append(CenteringSnapshot(edges: edges, adjusted: adjusted)) } })
                                .accessibilityLabel(["Venstre kant", "Højre kant", "Topkant", "Bundkant"][i])
                        }
                    }.padding(18).glassPanel()
                    if adjusted[side], let result {
                        Text("Venstre/højre: \(result.horizontal)\nTop/bund: \(result.vertical)")
                            .font(.title2.bold()).multilineTextAlignment(.center).monospacedDigit()
                        Button(copied ? "Måling kopieret" : "Kopiér måling") {
                            UIPasteboard.general.string = "\(side == 0 ? "Forside" : "Bagside") · manuelt målt centrering. Venstre/højre: \(result.horizontal). Top/bund: \(result.vertical). Afhænger af foto og placerede linjer; ingen graderingskarakter."
                            copied = true
                        }.buttonStyle(BigButtonStyle())
                    } else {
                        Text(adjusted[side] ? "Trykkanten skal ligge inden for kortkanten med synlig kant på begge akser." : "Placér kantlinjerne først. Startpositionerne er kun hjælpelinjer, ikke en måling.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("Målingen beregnes fra dine linjer og gemmes ikke automatisk. På full-art-kort uden tydelig trykkant kan centrering ikke måles sikkert her. Ingen AI-karakter eller løfte om PSA-resultat.").font(.footnote).foregroundStyle(.secondary)
                    Button("Fortryd kantlinjer") { if let previous = history.popLast() { edges = previous.edges; adjusted = previous.adjusted; copied = false } }
                        .frame(minHeight: 56).disabled(history.isEmpty)
                }.padding(20)
            }.background(Theme.bg).navigationTitle("Centrering").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { dismiss() } }
        }
    }
}
