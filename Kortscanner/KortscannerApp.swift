import SwiftUI
import SwiftData

@main
struct KortscannerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DebugLog.shared.startSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
                .onChange(of: scenePhase) { _, phase in
                    DebugLog.shared.info("Lifecycle: \(String(describing: phase))")
                }
        }
        .modelContainer(for: CardItem.self)
    }
}

enum Theme {
    static let accent = Color(red: 1, green: 203.0 / 255, blue: 5.0 / 255)
    static let blue = Color(red: 61.0 / 255, green: 125.0 / 255, blue: 202.0 / 255)
    static let bg = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.025, green: 0.045, blue: 0.09, alpha: 1) : UIColor(red: 0.95, green: 0.97, blue: 1, alpha: 1) })
    static func status(_ value: String) -> Color { value == "Beholder" ? .green : value == "Til salg" ? .orange : .gray }
}

@Model
final class CardItem {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var name: String = ""
    var number: String = ""
    var language: String = ""
    var setName: String = ""
    var setLogoURL: String = ""
    var setCode: String = ""
    var rarity: String = ""
    var gradingCompany: String = ""
    var grade: String = ""
    var certNumber: String = ""
    var condition: String = "NM"
    var status: String = "Beholder"
    var priceDKK: Double?
    var priceSource: String = ""
    var priceDate: String = ""
    var exchangeDate: String = ""
    var apiID: String = ""
    var variant: String = ""
    var sequence: Int = 0
    var needsReview: Bool = false
    var priceRefreshPending: Bool = false
    @Attribute(.externalStorage) var historyData: Data = Data()
    var deletedAt: Date?
    var photoSaved: Bool = false
    var uploadError: String = ""
    var nextUploadAt: Date?
    var uploadAttempts: Int = 0
    var uploadedID: Bool = false
    var googleAccount: String = ""
    @Attribute(.externalStorage) var closeup: Data?
    var uploadedFront: Bool = false
    var uploadedBack: Bool = false
    @Attribute(.externalStorage) var front: Data
    @Attribute(.externalStorage) var back: Data?

    init(front: Data, back: Data?, info: CardInfo) {
        self.front = front
        self.back = back
        self.name = info.name
        self.number = info.number
        self.language = info.language
        self.setCode = info.setCode
        self.rarity = info.rarity
        self.gradingCompany = info.gradingCompany
        self.grade = info.grade
        self.certNumber = info.certNumber
    }
}

extension CardItem {
    var keepLocked: Bool { Self.isProtected(name: name, company: gradingCompany) }
    static func isProtected(name: String, company: String) -> Bool {
        let n = name.lowercased()
        return company.uppercased() == "PSA" && (n.contains("moltres") || n.contains("snorlax") || n.contains("カビゴン") || n.contains("ファイヤー"))
    }
    var pendingUpload: Bool { !uploadedFront || (back != nil && !uploadedBack) || (closeup != nil && !uploadedID) }
    var metadata: [String: Any] {
        ["id": id.uuidString, "løbenummer": sequence, "navn": name, "nummer": number,
         "sæt": setName, "sætkode": setCode, "sprog": language, "stand": condition,
         "prisDKK": priceDKK.map { $0 as Any } ?? NSNull(),
         "status": keepLocked ? "Beholder" : status, "graderingsfirma": gradingCompany,
         "karakter": grade, "certifikat": certNumber, "priskilde": priceSource,
         "prisDato": priceDate, "kursDato": exchangeDate,
         "dato": ISO8601DateFormatter().string(from: createdAt)]
    }
}

func dkk(_ amount: Double?) -> String {
    guard let amount else { return "Pris mangler" }
    return amount.formatted(.currency(code: "DKK").locale(Locale(identifier: "da_DK")))
}
