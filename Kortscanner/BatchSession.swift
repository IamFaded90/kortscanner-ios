import Foundation
import SwiftData
import ActivityKit
import Combine

@MainActor
final class BatchSession: ObservableObject {
    static let shared = BatchSession()
    @Published private(set) var count = 0
    @Published private(set) var message = ""
    private var context: ModelContext?
    private var working = false
    private var active = false
    private var activity: Activity<ScanActivityAttributes>?
    func bind(_ context: ModelContext) { self.context = context; Task { await recognizePending() } }
    func start() async {
        active = true
        count = 0
        message = "Scan forside, vend kortet, og scan bagside."
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(attributes: ScanActivityAttributes(), content: ActivityContent(state: state("Forside", latest: ""), staleDate: Date().addingTimeInterval(120)), pushType: nil)
            } catch { DebugLog.shared.info("Live Activity er ikke tilgængelig på denne installation") }
        }
    }
    func stop() async {
        active = false
        if let activity { await activity.end(ActivityContent(state: state("Batch afsluttet", latest: ""), staleDate: nil), dismissalPolicy: .default) }
        activity = nil
        if let context { do { try CollectionMaintenance.commit(context) } catch { DebugLog.shared.error("Batch kunne ikke sikkerhedskopieres") } }
    }
    private func state(_ phase: String, latest: String) -> ScanActivityAttributes.ContentState {
        let cards = (try? context?.fetch(FetchDescriptor<CardItem>())) ?? []
        return .init(count: count, phase: phase, totalDKK: cards.filter { $0.deletedAt == nil && $0.status != "Solgt" }.compactMap(\.priceDKK).reduce(0, +), latestName: latest)
    }
    func phase(_ phase: String) async {
        if let activity { await activity.update(ActivityContent(state: state(phase, latest: ""), staleDate: Date().addingTimeInterval(120))) }
    }
    func capture(_ pages: [Data]) {
        guard let context, let front = pages.first else { return }
        let card = CardItem(front: front, back: pages.count > 1 ? pages[1] : nil, info: CardInfo(name: "Kort kræver kontrol"))
        card.closeup = pages.count > 2 ? pages[2] : nil
        card.needsReview = true
        card.sequence = UserDefaults.standard.integer(forKey: "lastCardSequence") + 1
        context.insert(card)
        do {
            try CollectionMaintenance.commit(context)
            UserDefaults.standard.set(card.sequence, forKey: "lastCardSequence")
            count += 1
            message = "\(count) kort gemt. Kontrollér dem bagefter i Samling."
            ActionHistory.shared.record("batch-kort", undo: { card.deletedAt = Date(); CollectionMaintenance.saveAfterUndo(context) }, redo: { card.deletedAt = nil; CollectionMaintenance.saveAfterUndo(context) })
            Task { await recognizePending(); await UploadQueue.shared.process() }
        } catch { context.rollback(); message = "Kortet kunne ikke gemmes. Stop og prøv igen."; DebugLog.shared.error("Batch: gemning fejlede") }
    }
    func recognizePending() async {
        guard !working, let context else { return }
        working = true
        defer { working = false }
        do {
            while let card = try context.fetch(FetchDescriptor<CardItem>()).first(where: { $0.deletedAt == nil && $0.needsReview && $0.name == "Kort kræver kontrol" }) {
                let upright = await CardRecognizer.upright(card.front)
                let info = await CardRecognizer.recognize(upright)
                guard card.deletedAt == nil, card.needsReview, card.name == "Kort kræver kontrol" else { continue }
                card.front = upright
                card.name = info.name.isEmpty ? "Ukendt kort" : info.name
                card.number = info.number
                card.language = info.language == "Japanese" ? "JP" : info.language == "English" ? "EN" : info.language
                card.setCode = info.setCode
                card.rarity = info.rarity
                card.gradingCompany = info.gradingCompany; card.grade = info.grade; card.certNumber = info.certNumber
                try CollectionMaintenance.commit(context)
                if let activity { await activity.update(ActivityContent(state: state("Næste kort", latest: card.name), staleDate: Date().addingTimeInterval(120))) }
            }
        } catch { DebugLog.shared.error("Batch-genkendelse kunne ikke gemmes") }
    }
}
