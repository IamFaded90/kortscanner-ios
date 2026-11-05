import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct BackupCard: Codable, Sendable {
    var id: UUID
    var createdAt: Date
    var name: String
    var number: String
    var language: String
    var setName: String
    var setCode: String
    var rarity: String
    var condition: String
    var status: String
    var gradingCompany: String
    var grade: String
    var certNumber: String
    var priceDKK: Double?
    var priceSource: String
    var priceDate: String
    var exchangeDate: String
    var apiID: String
    var variant: String
    var sequence: Int
    var deletedAt: Date?
    var needsReview: Bool
    var priceRefreshPending: Bool
    var historyData: Data
    var front: Data
    var back: Data?
    var closeup: Data?

    @MainActor init(_ card: CardItem) {
        id = card.id; createdAt = card.createdAt; name = card.name; number = card.number
        language = card.language; setName = card.setName; setCode = card.setCode; rarity = card.rarity
        condition = card.condition; status = card.status; gradingCompany = card.gradingCompany
        grade = card.grade; certNumber = card.certNumber; priceDKK = card.priceDKK
        priceSource = card.priceSource; priceDate = card.priceDate; exchangeDate = card.exchangeDate
        apiID = card.apiID; variant = card.variant; sequence = card.sequence; deletedAt = card.deletedAt
        needsReview = card.needsReview; priceRefreshPending = card.priceRefreshPending
        historyData = card.historyData; front = card.front; back = card.back; closeup = card.closeup
    }
    @MainActor func apply(to card: CardItem) {
        card.id = id; card.createdAt = createdAt; card.name = name; card.number = number
        card.language = language; card.setName = setName; card.setCode = setCode; card.rarity = rarity
        card.condition = condition; card.status = status; card.gradingCompany = gradingCompany
        card.grade = grade; card.certNumber = certNumber; card.priceDKK = priceDKK
        card.priceSource = priceSource; card.priceDate = priceDate; card.exchangeDate = exchangeDate
        card.apiID = apiID; card.variant = variant; card.sequence = sequence; card.deletedAt = deletedAt
        card.needsReview = needsReview; card.priceRefreshPending = priceRefreshPending
        card.historyData = historyData; card.front = front; card.back = back; card.closeup = closeup
        if card.keepLocked { card.status = "Beholder" }
    }
    @MainActor func create() -> CardItem {
        let card = CardItem(front: front, back: back, info: CardInfo())
        apply(to: card)
        return card
    }
}
struct BackupEnvelope: Codable, Sendable {
    var version: Int = 1
    var date = Date()
    var cards: [BackupCard]
    var portfolio: [PortfolioPoint]
    func validate() throws {
        guard version == 1, cards.count <= 10000, Set(cards.map(\.id)).count == cards.count,
              cards.allSatisfy({ card in
                  !card.front.isEmpty && card.front.count < 25_000_000 &&
                  (card.back?.count ?? 0) < 25_000_000 && (card.closeup?.count ?? 0) < 25_000_000 &&
                  card.name.count < 1000 && (card.priceDKK == nil || (card.priceDKK!.isFinite && card.priceDKK! >= 0))
              }) else { throw APIError.message("Filen er ikke en gyldig Kortscanner-backup.") }
    }
}

@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()
    @Published var message = ""
    @Published private(set) var externalFolderChosen = UserDefaults.standard.data(forKey: "backupFolderBookmark") != nil
    @Published private(set) var lastBackup: Date? = UserDefaults.standard.object(forKey: "lastBackupDate") as? Date
    private var pending: Task<Void, Never>?
    func chooseFolder(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: "backupFolderBookmark")
        externalFolderChosen = true
        message = "Backupmappe valgt."
    }
    func envelope(_ context: ModelContext) throws -> BackupEnvelope {
        let cards = try context.fetch(FetchDescriptor<CardItem>())
        return BackupEnvelope(cards: cards.map(BackupCard.init), portfolio: CollectionMaintenance.portfolio)
    }
    func schedule(_ context: ModelContext) {
        pending?.cancel()
        pending = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation(); try write(context) }
            catch is CancellationError {}
            catch { message = "Backup kunne ikke gemmes. Vælg mappen igen."; DebugLog.shared.error("Automatisk backup fejlede") }
        }
    }
    private func folder() throws -> URL {
        if let bookmark = UserDefaults.standard.data(forKey: "backupFolderBookmark") {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { try chooseFolder(url) }
            return url
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    func write(_ context: ModelContext, safetyCopy: Bool = false) throws {
        let archive = try envelope(context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        let directory = try folder()
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let current = directory.appendingPathComponent(safetyCopy ? "Kortscanner-før-gendannelse-\(stamp).json" : "Kortscanner-seneste.json")
        try data.write(to: current, options: .atomic)
        if !safetyCopy {
            let daily = directory.appendingPathComponent("Kortscanner-\(stamp.prefix(10)).json")
            if !FileManager.default.fileExists(atPath: daily.path) { try data.write(to: daily, options: .atomic) }
            lastBackup = Date()
            UserDefaults.standard.set(lastBackup, forKey: "lastBackupDate")
            message = externalFolderChosen ? "Backup gemt i din valgte mappe i Filer." : "Lokal kopi gemt. Vælg en ekstern mappe, før appen slettes."
        }
        DebugLog.shared.info("Backup gemt uden loginoplysninger")
    }
    func read(_ url: URL) throws -> BackupEnvelope {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 500_000_000 else { throw APIError.message("Backupfilen er større end 500 MB.") }
        let archive = try JSONDecoder().decode(BackupEnvelope.self, from: Data(contentsOf: url))
        try archive.validate()
        return archive
    }
    func restore(_ archive: BackupEnvelope, context: ModelContext) throws {
        try archive.validate()
        try write(context, safetyCopy: true)
        let before = try envelope(context)
        try apply(archive, context: context)
        ActionHistory.shared.record("gendannelse", undo: {
            do { try self.apply(before, context: context, hideOthers: true) } catch { self.message = "Gendannelsen kunne ikke fortrydes." }
        }, redo: {
            do { try self.apply(archive, context: context) } catch { self.message = "Gendannelsen kunne ikke gentages." }
        })
        message = "\(archive.cards.filter { $0.deletedAt == nil }.count) kort gendannet. Eksisterende ekstra kort er bevaret."
    }
    private func apply(_ archive: BackupEnvelope, context: ModelContext, hideOthers: Bool = false) throws {
        let existing = try context.fetch(FetchDescriptor<CardItem>())
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for copy in archive.cards {
            if let card = byID[copy.id] { copy.apply(to: card) }
            else { context.insert(copy.create()) }
        }
        if hideOthers {
            let ids = Set(archive.cards.map(\.id))
            for card in existing where !ids.contains(card.id) { card.deletedAt = Date() }
        }
        UserDefaults.standard.set(try JSONEncoder().encode(archive.portfolio), forKey: "portfolioHistory")
        let largest = max(UserDefaults.standard.integer(forKey: "lastCardSequence"), archive.cards.map(\.sequence).max() ?? 0)
        UserDefaults.standard.set(largest, forKey: "lastCardSequence")
        try CollectionMaintenance.commit(context)
    }
}

struct BackupFolderPicker: UIViewControllerRepresentable {
    let selected: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL) -> Void
        init(_ selected: @escaping (URL) -> Void) { self.selected = selected }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { selected(url) }
        }
    }
}
