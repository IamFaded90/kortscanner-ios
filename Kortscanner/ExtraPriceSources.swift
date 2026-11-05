import Foundation
import CryptoKit

struct PriceIdentity: Sendable {
    var name: String
    var number: String
    var setName: String
    var language: String
    var variant: String
    var productID = ""
    static func productID(from value: String?) -> String {
        guard let value, let url = URL(string: value),
              let host = url.host?.lowercased(), host == "tcgplayer.com" || host.hasSuffix(".tcgplayer.com") else { return "" }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "product"), parts.indices.contains(index + 1),
              !parts[index + 1].isEmpty, parts[index + 1].allSatisfy(\.isNumber) else { return "" }
        return parts[index + 1]
    }
    static func canonical(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func setKey(_ text: String) -> String {
        var key = canonical(text)
        key = key.replacingOccurrences(of: "^(?:swsh|sv|sm|xy)[0-9]*(?=[a-z])", with: "", options: .regularExpression)
        if ["scarletviolet151", "151"].contains(key) { return "151" }
        if ["base", "baseset"].contains(key) { return "base" }
        return key
    }
    var english: Bool { ["EN", "ENGLISH"].contains(language.uppercased()) }
    var japanese: Bool { ["JP", "JAPANESE"].contains(language.uppercased()) }
    func matches(name: String, number: String?, set: String?) -> Bool {
        guard !self.name.isEmpty, !self.number.isEmpty, !setName.isEmpty,
              let number, let set else { return false }
        return Self.canonical(name) == Self.canonical(self.name)
            && CardAPI.normalizedNumber(number).uppercased() == CardAPI.normalizedNumber(self.number).uppercased()
            && Self.setKey(set) == Self.setKey(setName)
    }
    static func printing(_ raw: String) -> String {
        switch canonical(raw) {
        case "normal", "unlimited": return "normal"
        case "holofoil", "holo", "foil", "unlimitedholofoil": return "holofoil"
        case "reverseholofoil", "reverseholo", "reversefoil": return "reverseHolofoil"
        case "1steditionholofoil", "firsteditionholofoil", "1steditionfoil": return "1stEditionHolofoil"
        case "1steditionnormal", "1stedition", "firstedition": return "1stEditionNormal"
        default: return ""
        }
    }
    static func nearMint(_ condition: String) -> Bool { ["nm", "nearmint"].contains(canonical(condition)) }
}

struct ForeignPrice: Sendable {
    var amount: Double
    var currency = "USD"
    var source: String
    var date: String
    func converted(rate: ExchangeRates.Rate) -> PriceQuote? {
        let amountDKK = amount * rate.rate
        guard amount.isFinite, amount >= 0, rate.rate.isFinite, rate.rate > 0, amountDKK.isFinite else { return nil }
        return PriceQuote(dkk: amountDKK, source: source, sourceDate: date, rateDate: rate.date)
    }
}

actor PriceProviderRequests {
    static let shared = PriceProviderRequests()
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let loader: Loader
    init(loader: @escaping Loader = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.message("Intet prissvar") }
        return (data, response)
    }) { self.loader = loader }
    private var cooldowns: [String: Date] = [:]
    private var cache: [String: (Date, Data)] = [:]
    func reset() { cooldowns = [:]; cache = [:] }
    func data(provider: String, request: URLRequest) async throws -> Data? {
        // Cache identities contain only a one-way digest, never the credential itself.
        let fingerprint = SHA256.hash(data: Data((request.value(forHTTPHeaderField: "Authorization") ?? request.value(forHTTPHeaderField: "x-api-key") ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
        let providerKey = provider + fingerprint
        let cacheKey = providerKey + (request.url?.absoluteString ?? "")
        if let cached = cache[cacheKey], cached.0 > Date() { return cached.1 }
        if let until = cooldowns[providerKey], until > Date() { return nil }
        var request = request
        request.timeoutInterval = 15
        do {
            let (data, response) = try await loader(request)
            guard (200..<300).contains(response.statusCode) else {
                let delay: Double
                if response.statusCode == 429 { delay = min(86400, max(60, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 900)) }
                else if [401, 403, 402].contains(response.statusCode) { delay = 3600 }
                else { delay = 60 }
                cooldowns[providerKey] = Date().addingTimeInterval(delay)
                await MainActor.run { DebugLog.shared.info("\(provider): sprunget over · HTTP \(response.statusCode)") }
                return nil
            }
            cache[cacheKey] = (Date().addingTimeInterval(3600), data)
            return data
        } catch {
            cooldowns[providerKey] = Date().addingTimeInterval(60)
            await MainActor.run { DebugLog.shared.info("\(provider): sprunget over · forbindelsen fejlede") }
            return nil
        }
    }
}

enum ExtraPriceSources {
    struct JustResponse: Decodable {
        let data: [Card]
        struct Card: Decodable {
            let name: String
            let number: String?
            let set_name: String?
            let tcgplayerId: String?
            let variants: [Variant]
        }
        struct Variant: Decodable {
            let condition: String
            let printing: String
            let price: Double?
            let lastUpdated: Double?
            let language: String?
            let priceStatus: String?
        }
    }
    struct TrackerCard: Decodable {
        let tcgPlayerId: String
        let name: String
        let cardNumber: String?
        let setName: String?
        let variants: [String: Variant]?
        let prices: Prices?
        struct Variant: Decodable {
            let printing: String?
            let marketPrice: Double?
            let conditionUsed: String?
        }
        struct Prices: Decodable { let lastUpdated: String? }
    }
    struct TrackerResponse: Decodable {
        let cards: [TrackerCard]
        enum CodingKeys: String, CodingKey { case data }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let cards = try? container.decode([TrackerCard].self, forKey: .data) { self.cards = cards }
            else if let card = try? container.decode(TrackerCard.self, forKey: .data) { self.cards = [card] }
            else if try container.decodeNil(forKey: .data) { cards = [] }
            else { throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "Ukendt prisformat") }
        }
    }
    static func parseJust(_ data: Data, identity: PriceIdentity, allVariants: Bool = false) throws -> [ForeignPrice] {
        let cards = try JSONDecoder().decode(JustResponse.self, from: data).data
        let matches = cards.filter {
            identity.productID.isEmpty ? identity.matches(name: $0.name, number: $0.number, set: $0.set_name) : $0.tcgplayerId == identity.productID
        }
        guard matches.count == 1, let card = matches.first else { return [] }
        return card.variants.compactMap { variant in
            guard PriceIdentity.nearMint(variant.condition), variant.priceStatus == nil || variant.priceStatus == "current",
                  let price = variant.price, price.isFinite, price >= 0 else { return nil }
            let language = variant.language ?? "English"
            guard (identity.english && language.caseInsensitiveCompare("English") == .orderedSame)
                    || (identity.japanese && language.caseInsensitiveCompare("Japanese") == .orderedSame) else { return nil }
            let printing = PriceIdentity.printing(variant.printing)
            guard !printing.isEmpty, allVariants || printing == identity.variant else { return nil }
            let date = variant.lastUpdated.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            return ForeignPrice(amount: price, source: "JustTCG · \(variant.printing) · raw NM", date: date)
        }
    }
    static func parseTracker(_ data: Data, identity: PriceIdentity) throws -> [ForeignPrice] {
        let cards = try JSONDecoder().decode(TrackerResponse.self, from: data).cards
        let matches = cards.filter {
            identity.productID.isEmpty ? identity.matches(name: $0.name, number: $0.cardNumber, set: $0.setName) : $0.tcgPlayerId == identity.productID
        }
        guard matches.count == 1, let card = matches.first else { return [] }
        return (card.variants ?? [:]).compactMap { key, value in
            guard PriceIdentity.printing(value.printing ?? key) == identity.variant,
                  let condition = value.conditionUsed, PriceIdentity.nearMint(condition),
                  let price = value.marketPrice, price.isFinite, price >= 0 else { return nil }
            return ForeignPrice(amount: price, source: "PokemonPriceTracker · \(value.printing ?? key) · raw NM", date: card.prices?.lastUpdated ?? "")
        }
    }
    static func just(_ identity: PriceIdentity, allVariants: Bool = false) async throws -> [PriceQuote] {
        let key = Keychain.get("justTCG")
        guard !key.isEmpty, identity.english || identity.japanese else { return [] }
        var url = URLComponents(string: "https://api.justtcg.com/v1/cards")!
        if !identity.productID.isEmpty { url.queryItems = [URLQueryItem(name: "tcgplayerId", value: identity.productID)] }
        else {
            guard !identity.name.isEmpty, !identity.number.isEmpty, !identity.setName.isEmpty else { return [] }
            url.queryItems = [URLQueryItem(name: "q", value: identity.name), URLQueryItem(name: "number", value: CardAPI.normalizedNumber(identity.number)), URLQueryItem(name: "game", value: "pokemon"), URLQueryItem(name: "limit", value: "10")]
        }
        url.queryItems! += [URLQueryItem(name: "condition", value: "NM"), URLQueryItem(name: "language", value: identity.japanese ? "Japanese" : "English"), URLQueryItem(name: "include_price_history", value: "false")]
        var request = URLRequest(url: url.url!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        guard let data = try await PriceProviderRequests.shared.data(provider: "JustTCG", request: request) else { return [] }
        let prices = try parseJust(data, identity: identity, allVariants: allVariants)
        guard !prices.isEmpty else { return [] }
        let rate = try await ExchangeRates.shared.rate("USD")
        return prices.compactMap { $0.converted(rate: rate) }
    }
    static func tracker(_ identity: PriceIdentity) async throws -> [PriceQuote] {
        let key = Keychain.get("pokemonPriceTracker")
        guard !key.isEmpty, identity.english || identity.japanese else { return [] }
        var url = URLComponents(string: "https://www.pokemonpricetracker.com/api/v2/cards")!
        if !identity.productID.isEmpty { url.queryItems = [URLQueryItem(name: "tcgPlayerId", value: identity.productID), URLQueryItem(name: "limit", value: "1")] }
        else {
            guard !identity.name.isEmpty, !identity.number.isEmpty, !identity.setName.isEmpty else { return [] }
            url.queryItems = [URLQueryItem(name: "search", value: identity.name + " " + identity.number), URLQueryItem(name: "set", value: identity.setName), URLQueryItem(name: "limit", value: "3")]
        }
        url.queryItems! += [URLQueryItem(name: "language", value: identity.japanese ? "japanese" : "english"), URLQueryItem(name: "includeHistory", value: "false"), URLQueryItem(name: "includeEbay", value: "false")]
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        guard let data = try await PriceProviderRequests.shared.data(provider: "PokemonPriceTracker", request: request) else { return [] }
        let prices = try parseTracker(data, identity: identity)
        guard !prices.isEmpty else { return [] }
        let rate = try await ExchangeRates.shared.rate("USD")
        return prices.compactMap { $0.converted(rate: rate) }
    }
}
