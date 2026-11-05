import Foundation
import Combine
import AppIntents
import SwiftData

@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var tab = UserDefaults.standard.integer(forKey: "screenshotTab")
    @Published var showChat = false
    func requestScan() { tab = 0 }
}

struct CollectionValueIntent: AppIntent {
    static var title: LocalizedStringResource = "Hvad er min samling værd?"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        AppRouter.shared.tab = 1
        let container = try ModelContainer(for: CardItem.self)
        let cards = try container.mainContext.fetch(FetchDescriptor<CardItem>()).filter { $0.deletedAt == nil && $0.status != "Solgt" }
        let amount = dkk(cards.compactMap(\.priceDKK).reduce(0, +))
        let missing = cards.filter { $0.priceDKK == nil }.count
        return .result(dialog: "Din samling er registreret til \(amount). \(missing) kort mangler en pris.")
    }
}
struct KortscannerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScanCardIntent(), phrases: ["Scan et kort i \(.applicationName)"], shortTitle: "Scan et kort", systemImageName: "viewfinder")
        AppShortcut(intent: CollectionValueIntent(), phrases: ["Hvad er min samling værd i \(.applicationName)"], shortTitle: "Samlingens værdi", systemImageName: "rectangle.stack")
    }
}
