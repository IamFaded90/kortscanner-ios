import Foundation

enum APIError: LocalizedError {
    case http(Int)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .http(let code):
            if code == 401 || code == 403 { return "Tjek API-nøglen eller log ind igen." }
            if code == 429 { return "For mange opslag. Prøv igen om lidt." }
            return "Tjenesten svarer ikke lige nu (\(code))."
        case .message(let text): return text
        }
    }
}
enum HTTP {
    static func data(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.message("Intet svar fra tjenesten.") }
        guard (200..<300).contains(response.statusCode) else { throw APIError.http(response.statusCode) }
        return data
    }
}
struct APICard: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let number: String
    let rarity: String?
    let images: Images
    let set: CardSet
    let tcgplayer: TCGPlayer?
    let cardmarket: Cardmarket?
    struct Images: Decodable, Sendable { let small: String; let large: String? }
    struct CardSet: Decodable, Sendable { let id: String; let name: String; let ptcgoCode: String?; let printedTotal: Int?; let images: SetImages? }
    struct SetImages: Decodable, Sendable { let logo: String? }
    struct TCGPlayer: Decodable, Sendable {
        let url: String?
        let updatedAt: String?
        let prices: [String: Market]?
        struct Market: Decodable, Sendable { let market: Double? }
    }
    struct Cardmarket: Decodable, Sendable {
        let updatedAt: String?
        let prices: Prices?
        struct Prices: Decodable, Sendable {
            let trendPrice: Double?
            let reverseHoloTrend: Double?
        }
    }
    var variants: [String] {
        let list = Array(tcgplayer?.prices?.keys ?? Dictionary<String, TCGPlayer.Market>().keys).sorted()
        return list.isEmpty ? ["normal"] : list
    }
}
struct SearchResult: Sendable { var cards: [APICard]; var total: Int }

enum CardAPI {
    static func normalizedNumber(_ value: String) -> String {
        let part = value.split(separator: "/").first.map(String.init) ?? value
        if let n = Int(part) { return String(n) }
        return part
    }
    static func search(_ info: CardInfo) async throws -> SearchResult {
        if info.language == "JP" || info.language == "Japanese" || info.language == "Korean" {
            throw APIError.message("Dette katalog matcher engelske kort. Gem det japanske/koreanske kort manuelt; vi gætter ikke på en engelsk pris.")
        }
        func clean(_ value: String) -> String {
            String(value.unicodeScalars.filter { CharacterSet.alphanumerics.union(.whitespaces).contains($0) })
                .trimmingCharacters(in: .whitespaces)
        }
        var clauses: [String] = []
        let name = clean(info.name)
        let number = clean(normalizedNumber(info.number))
        if !name.isEmpty { clauses.append("name:\"\(name)\"") }
        if !number.isEmpty { clauses.append("number:\"\(number)\"") }
        guard !clauses.isEmpty else { return SearchResult(cards: [], total: 0) }
        var components = URLComponents(string: "https://api.pokemontcg.io/v2/cards")!
        components.queryItems = [URLQueryItem(name: "q", value: clauses.joined(separator: " ")), URLQueryItem(name: "pageSize", value: "30")]
        var request = URLRequest(url: components.url!)
        let key = Keychain.get("pokemonAPI")
        if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        let data = try await HTTP.data(request)
        struct Response: Decodable { let data: [APICard]; let totalCount: Int? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let ranked = response.data.sorted { score($0, info: info) > score($1, info: info) }
        return SearchResult(cards: Array(ranked.prefix(3)), total: response.totalCount ?? response.data.count)
    }
    static func score(_ card: APICard, info: CardInfo) -> Int {
        var score = card.name.caseInsensitiveCompare(info.name) == .orderedSame ? 3 : 0
        if !info.number.isEmpty && normalizedNumber(card.number) == normalizedNumber(info.number) { score += 3 }
        if let total = info.number.split(separator: "/").last, info.number.contains("/"),
           Int(total) == card.set.printedTotal { score += 2 }
        if !info.setCode.isEmpty && [card.set.id.lowercased(), card.set.ptcgoCode?.lowercased() ?? ""].contains(info.setCode.lowercased()) { score += 2 }
        return score
    }
}

struct PriceQuote: Sendable {
    var dkk: Double
    var source: String
    var sourceDate: String
    var rateDate: String
}
actor ExchangeRates {
    static let shared = ExchangeRates()
    struct Rate: Codable { let date: String; let rate: Double }
    func rate(_ currency: String) async throws -> Rate {
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let cacheKey = "exchange-\(currency)-\(today)"
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(Rate.self, from: data) { return cached }
        let data = try await HTTP.data(URLRequest(url: URL(string: "https://api.frankfurter.dev/v2/rate/\(currency.lowercased())/dkk")!))
        let rate = try JSONDecoder().decode(Rate.self, from: data)
        guard rate.rate > 0, rate.rate.isFinite else { throw APIError.message("Valutakursen mangler.") }
        UserDefaults.standard.set(try JSONEncoder().encode(rate), forKey: cacheKey)
        return rate
    }
}
enum PriceService {
    static func quotes(_ card: APICard, variant: String) async throws -> [PriceQuote] {
        var quotes: [PriceQuote] = []
        if let price = card.tcgplayer?.prices?[variant]?.market, price >= 0 {
            let rate = try await ExchangeRates.shared.rate("USD")
            quotes.append(PriceQuote(dkk: price * rate.rate, source: "TCGplayer · \(variant) · raw NM", sourceDate: card.tcgplayer?.updatedAt ?? "", rateDate: rate.date))
        }
        let isReverse = variant == "reverseHolofoil"
        let isFirstEdition = variant.lowercased().contains("1stedition")
        if !isFirstEdition, let market = card.cardmarket,
           let price = isReverse ? market.prices?.reverseHoloTrend : market.prices?.trendPrice {
            let rate = try await ExchangeRates.shared.rate("EUR")
            quotes.append(PriceQuote(dkk: price * rate.rate, source: "Cardmarket · trend · ikke standsspecifik", sourceDate: market.updatedAt ?? "", rateDate: rate.date))
        }
        return quotes
    }
    static func justTCG(productID: String) async throws -> [PriceQuote] {
        let key = Keychain.get("justTCG")
        guard !key.isEmpty, !productID.isEmpty, productID.allSatisfy(\.isNumber) else {
            throw APIError.message("Indtast JustTCG-nøgle i Indstillinger og kortets TCGplayer-produkt-id.")
        }
        var url = URLComponents(string: "https://api.justtcg.com/v1/cards")!
        url.queryItems = [URLQueryItem(name: "tcgplayerId", value: productID), URLQueryItem(name: "condition", value: "NM")]
        var request = URLRequest(url: url.url!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        struct Response: Decodable {
            let data: [Card]
            struct Card: Decodable {
                let name: String
                let variants: [Variant]
            }
            struct Variant: Decodable {
                let condition: String
                let printing: String
                let price: Double?
                let lastUpdated: Double?
                let language: String?
            }
        }
        let response = try JSONDecoder().decode(Response.self, from: await HTTP.data(request))
        let rate = try await ExchangeRates.shared.rate("USD")
        return response.data.flatMap { card in
            card.variants.compactMap { variant in
                guard ["NM","Near Mint"].contains(variant.condition), let price = variant.price else { return nil }
                let date = variant.lastUpdated.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) } ?? ""
                return PriceQuote(dkk: price * rate.rate, source: "JustTCG · \(card.name) · \(variant.printing) · \(variant.language ?? "English") · NM", sourceDate: date, rateDate: rate.date)
            }
        }
    }
}
