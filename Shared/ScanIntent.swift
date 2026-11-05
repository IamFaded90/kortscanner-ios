import Foundation
import AppIntents

enum ScanDestination: String, AppEnum {
    case camera
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Kortscanner")
    static var caseDisplayRepresentations: [ScanDestination: DisplayRepresentation] = [.camera: DisplayRepresentation(title: "Kamera")]
}

struct ScanCardIntent: OpenIntent {
    static var title: LocalizedStringResource = "Scan et kort"
    static var description = IntentDescription("Åbner Kortscanner-kameraet direkte.")
    static var openAppWhenRun = true
    @Parameter(title: "Åbn", default: .camera) var target: ScanDestination
    @MainActor func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Notification.Name("KortscannerScanRequested"), object: nil)
        return .result()
    }
}
