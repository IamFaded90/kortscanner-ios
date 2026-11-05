import SwiftUI
import Charts
import CoreMotion

struct BigButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(filled ? Color.black : Color.primary)
            .background(filled ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 18))
            .overlay { if !filled { RoundedRectangle(cornerRadius: 18).stroke(Theme.blue.opacity(0.65)) } }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}
struct GlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }
}
extension View { func glassPanel() -> some View { modifier(GlassPanel()) } }

struct PriceChart: View {
    let points: [PricePoint]
    var body: some View {
        if points.count > 1 {
            Chart(points.sorted { $0.date < $1.date }) { point in
                AreaMark(x: .value("Dato", point.date), yStart: .value("Nul", 0), yEnd: .value("DKK", point.amount))
                    .foregroundStyle(Theme.blue.opacity(0.15)).interpolationMethod(.stepEnd)
                LineMark(x: .value("Dato", point.date), y: .value("DKK", point.amount))
                    .foregroundStyle(Theme.blue).interpolationMethod(.stepEnd)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisValueLabel(format: .dateTime.day().month()) } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { if let amount = value.as(Double.self) { Text(dkk(amount)).font(.caption2) } }
            }}.frame(height: 120).accessibilityLabel("Prishistorik i danske kroner")
        } else {
            HStack(spacing: 12) {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(Theme.blue)
                Text(points.isEmpty ? "Ingen priser gemt endnu" : "Grafen vises efter næste prisopdatering").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }
    }
}

@MainActor
final class MotionTilt: ObservableObject {
    @Published var roll = 0.0
    @Published var pitch = 0.0
    private let manager = CMMotionManager()
    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            self?.roll = max(-0.5, min(0.5, motion.attitude.roll))
            self?.pitch = max(-0.5, min(0.5, motion.attitude.pitch))
        }
    }
    func stop() { manager.stopDeviceMotionUpdates() }
}
struct HoloCardImage: View {
    let data: Data
    @StateObject private var tilt = MotionTilt()
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @AppStorage("holoEnabled") private var enabled = true
    var body: some View {
        Group {
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
                    .overlay {
                        if enabled && !reducedMotion {
                            LinearGradient(colors: [.clear, Theme.blue.opacity(0.08), Theme.accent.opacity(0.22), .white.opacity(0.1), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .offset(x: tilt.roll * 100, y: tilt.pitch * 80)
                                .blendMode(.screen).allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            } else { Image(systemName: "photo").font(.largeTitle) }
        }
        .onAppear { if enabled && !reducedMotion { tilt.start() } }
        .onDisappear { tilt.stop() }
        .onChange(of: reducedMotion) { _, value in if value { tilt.stop() } else if enabled { tilt.start() } }
        .onChange(of: enabled) { _, value in if value && !reducedMotion { tilt.start() } else { tilt.stop() } }
    }
}
