import Foundation
import SwiftData
import Network
import Combine

@MainActor
final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()
    @Published private(set) var running = false
    @Published private(set) var online = true
    @Published private(set) var message = ""
    private var context: ModelContext?
    private var monitor: NWPathMonitor?
    func bind(_ context: ModelContext) {
        self.context = context
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in
                UploadQueue.shared.online = path.status == .satisfied
                if path.status == .satisfied {
                    await UploadQueue.shared.process()
                    if let context = UploadQueue.shared.context { await PriceRefreshService.shared.refresh(context) }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "kortscanner.network"))
        self.monitor = monitor
    }
    func process(force: Bool = false) async {
        guard !running, let context else { return }
        running = true
        defer { running = false }
        do {
            let cards = try context.fetch(FetchDescriptor<CardItem>(sortBy: [SortDescriptor(\CardItem.createdAt)]))
                .filter { $0.deletedAt == nil }
            let google = GooglePhotosService.shared
            let autoGoogle = UserDefaults.standard.object(forKey: "autoGoogleUpload") as? Bool ?? true
            let localPhotos = UserDefaults.standard.object(forKey: "saveLocalPhotos") as? Bool ?? true
            for card in cards {
                if localPhotos && !card.photoSaved {
                    do {
                        try await PhotoLibraryService.save([card.front, card.back, card.closeup].compactMap { $0 })
                        card.photoSaved = true
                        try context.save()
                        DebugLog.shared.info("Scanninger gemt i lokalt fotoalbum")
                    } catch {
                        message = error.localizedDescription
                        DebugLog.shared.error("Lokalt fotoalbum: gemning fejlede")
                    }
                }
                guard !card.needsReview, google.signedIn, autoGoogle,
                      force || card.nextUploadAt == nil || card.nextUploadAt! <= Date() else { continue }
                if card.googleAccount != google.accountID {
                    card.googleAccount = google.accountID
                    card.uploadedFront = false; card.uploadedBack = false; card.uploadedID = false
                    card.uploadAttempts = 0
                    try context.save()
                }
                guard card.pendingUpload else { continue }
                do {
                    // Send in order; commit each successful stage for retries after relaunch.
                    let account = google.accountID
                    let metadata: [String: Any] = [
                        "navn": card.name, "nummer": card.number, "sæt": card.setName,
                        "sprog": card.language, "prisDKK": card.priceDKK.map { $0 as Any } ?? NSNull(),
                        "status": card.keepLocked ? "Beholder" : card.status
                    ]
                    let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
                    let description = String(data: data, encoding: .utf8) ?? "{}"
                    for side in 0..<3 {
                        guard google.signedIn, account == google.accountID, card.deletedAt == nil else { throw CancellationError() }
                        let image: Data?
                        let suffix: String
                        switch side {
                        case 0: image = card.uploadedFront ? nil : card.front; suffix = "forside"
                        case 1: image = card.uploadedBack ? nil : card.back; suffix = "bagside"
                        default: image = card.uploadedID ? nil : card.closeup; suffix = "id"
                        }
                        guard let image else { continue }
                        try await google.upload(image, name: "KORT-\(card.sequence)-\(suffix).jpg", description: description)
                        switch side { case 0: card.uploadedFront = true; case 1: card.uploadedBack = true; default: card.uploadedID = true }
                        try context.save()
                    }
                    card.uploadError = ""; card.nextUploadAt = nil; card.uploadAttempts = 0
                    try context.save()
                    message = "Billederne er gemt i Google Fotos."
                    DebugLog.shared.info("Kort uploadet til Google Fotos")
                } catch {
                    if case APIError.http(404) = error {
                        google.resetAlbum()
                        card.uploadedFront = false; card.uploadedBack = false; card.uploadedID = false
                    }
                    card.uploadAttempts += 1
                    card.nextUploadAt = Date().addingTimeInterval(min(3600, 30 * pow(2, Double(min(card.uploadAttempts, 7)))))
                    card.uploadError = error is CancellationError ? "Upload sat på pause." : error.localizedDescription
                    do { try context.save() } catch { DebugLog.shared.error("Uploadkø kunne ikke gemmes") }
                    message = "Upload venter. Prøver igen, mens appen er åben."
                    DebugLog.shared.error("Google-upload fejlede; billedet er i kø")
                    // Respect rate limits; stop this pass instead of uploading the next card.
                    break
                }
            }
        } catch { message = "Køen kunne ikke læses."; DebugLog.shared.error("Uploadkø: SwiftData-fejl") }
    }
}
