import Foundation
import SwiftData
import Combine

struct PricePoint: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var amount: Double
    var source: String
}
struct PortfolioPoint: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var amount: Double
    var count: Int
    var missing: Int
}

extension CardItem {
    var priceHistory: [PricePoint] { (try? JSONDecoder().decode([PricePoint].self, from: historyData)) ?? [] }
    var identityKey: String {
        if needsReview { return id.uuidString }
        let identity = apiID.isEmpty ? "\(name.lowercased())|\(number.lowercased())|\(setName.lowercased())" : apiID
        return "\(identity)|\(language.uppercased())|\(variant)"
    }
    func recordPrice(_ amount: Double, source: String, sourceDate: String = "", rateDate: String = "", date: Date = Date()) throws {
        guard amount.isFinite, amount >= 0 else { throw APIError.message("Prisen skal være et gyldigt beløb i DKK.") }
        var history = priceHistory
        history.append(PricePoint(date: date, amount: amount, source: source))
        let data = try JSONEncoder().encode(history)
        historyData = data
        priceDKK = amount
        priceSource = source
        priceDate = sourceDate
        exchangeDate = rateDate
        priceRefreshPending = false
    }
}

@MainActor
final class ActionHistory: ObservableObject {
    static let shared = ActionHistory()
    struct Entry { let title: String; let undo: () -> Void; let redo: () -> Void }
    @Published private(set) var undoTitle = ""
    @Published private(set) var redoTitle = ""
    private var undos: [Entry] = []
    private var redos: [Entry] = []
    func record(_ title: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undos.append(Entry(title: title, undo: undo, redo: redo))
        if undos.count > 10 { undos.removeFirst() }
        redos = []
        update()
    }
    func undo() { guard let entry = undos.popLast() else { return }; entry.undo(); redos.append(entry); update() }
    func redo() { guard let entry = redos.popLast() else { return }; entry.redo(); undos.append(entry); update() }
    private func update() { undoTitle = undos.last?.title ?? ""; redoTitle = redos.last?.title ?? "" }
}

@MainActor
enum CollectionMaintenance {
    static var portfolio: [PortfolioPoint] {
        guard let data = UserDefaults.standard.data(forKey: "portfolioHistory") else { return [] }
        return (try? JSONDecoder().decode([PortfolioPoint].self, from: data)) ?? []
    }
    static func commit(_ context: ModelContext) throws {
        try context.save()
        let cards = try context.fetch(FetchDescriptor<CardItem>()).filter { $0.deletedAt == nil && $0.status != "Solgt" }
        var history = portfolio
        let current = PortfolioPoint(date: Date(), amount: cards.compactMap(\.priceDKK).reduce(0, +), count: cards.count, missing: cards.filter { $0.priceDKK == nil }.count)
        if let previous = history.last,
           abs(previous.amount - current.amount) < 0.001, previous.count == current.count,
           previous.missing == current.missing, Calendar.current.isDateInToday(previous.date) {
            // No additional value point for operations that only affect upload state.
        } else {
            history.append(current)
            UserDefaults.standard.set(try JSONEncoder().encode(history), forKey: "portfolioHistory")
        }
        BackupManager.shared.schedule(context)
    }
    static func saveAfterUndo(_ context: ModelContext) {
        do { try commit(context) }
        catch { context.rollback(); DebugLog.shared.error("Fortryd kunne ikke gemmes") }
    }
}

@MainActor
final class PriceRefreshService {
    static let shared = PriceRefreshService()
    private var running = false
    private var lastAttempt = Date.distantPast
    func refresh(_ context: ModelContext, force: Bool = false) async {
        guard !running, UploadQueue.shared.online, force || lastAttempt.timeIntervalSinceNow < -120 else { return }
        lastAttempt = Date()
        running = true
        defer { running = false }
        do {
            let cards = try context.fetch(FetchDescriptor<CardItem>()).filter {
                $0.deletedAt == nil && !$0.needsReview && (force || $0.priceRefreshPending)
            }
            for card in cards {
                let quotes = await PriceService.savedQuotes(card)
                let quote = quotes.first(where: { $0.source == card.priceSource }) ?? quotes.first
                do {
                    if let quote {
                        try card.recordPrice(quote.dkk, source: quote.source, sourceDate: quote.sourceDate, rateDate: quote.rateDate)
                        try CollectionMaintenance.commit(context)
                        DebugLog.shared.info("Pris opdateret i DKK med historik · \(quote.source)")
                    } else {
                        card.priceRefreshPending = true
                        try context.save()
                    }
                } catch {
                    card.priceRefreshPending = true
                    DebugLog.shared.info("Prisen kunne ikke gemmes; fortsætter med næste kort")
                }
            }
        } catch { DebugLog.shared.error("Priskø kunne ikke læses") }
    }
}
