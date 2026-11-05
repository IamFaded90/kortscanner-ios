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
    static func searchQuery(_ info: CardInfo, setName: String = "") -> String {
        func clean(_ value: String) -> String {
            String(value.unicodeScalars.filter { CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "&-")).contains($0) })
                .trimmingCharacters(in: .whitespaces)
        }
        var clauses: [String] = []
        let name = clean(info.name)
        let number = clean(normalizedNumber(info.number))
        if !name.isEmpty { clauses.append("name:\"\(name)\"") }
        if !number.isEmpty { clauses.append("number:\"\(number)\"") }
        let set = clean(setName)
        if !set.isEmpty { clauses.append("set.name:\"\(set)\"") }
        else if !info.setCode.isEmpty { clauses.append("(set.id:\"\(clean(info.setCode))\" OR set.ptcgoCode:\"\(clean(info.setCode))\")") }
        if info.number.contains("/"), let total = Int(info.number.split(separator: "/").last ?? "") {
            clauses.append("set.printedTotal:\(total)")
        }
        return clauses.joined(separator: " ")
    }
    static func search(_ info: CardInfo, setName: String = "") async throws -> SearchResult {
        if info.language == "JP" || info.language == "Japanese" || info.language == "Korean" {
            throw APIError.message("Dette katalog matcher engelske kort. Gem det japanske/koreanske kort manuelt; vi gætter ikke på en engelsk pris.")
        }
        let query = searchQuery(info, setName: setName)
        guard !query.isEmpty else { return SearchResult(cards: [], total: 0) }
        var components = URLComponents(string: "https://api.pokemontcg.io/v2/cards")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "pageSize", value: "30")]
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
    typealias Operation = @Sendable () async throws -> [PriceQuote]
    static func collect(_ sources: [(String, Operation)]) async -> [PriceQuote] {
        await withTaskGroup(of: (Int, [PriceQuote]).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do { return (index, try await source.1()) }
                    catch {
                        await MainActor.run { DebugLog.shared.info("\(source.0): pris sprunget over; bruger øvrige kilder") }
                        return (index, [])
                    }
                }
            }
            var results: [(Int, [PriceQuote])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }
    static func quotes(_ card: APICard, variant: String) async throws -> [PriceQuote] {
        let identity = PriceIdentity(name: card.name, number: card.number, setName: card.set.name, language: "EN",
                                     variant: variant, productID: PriceIdentity.productID(from: card.tcgplayer?.url))
        return await allQuotes(primary: card, identity: identity)
    }
    static func allQuotes(primary: APICard?, identity: PriceIdentity) async -> [PriceQuote] {
        await collect([
            ("Pokémon TCG API · TCGplayer", {
                guard let card = primary, let price = card.tcgplayer?.prices?[identity.variant]?.market,
                      price.isFinite, price >= 0 else { return [] }
                let rate = try await ExchangeRates.shared.rate("USD")
                return ForeignPrice(amount: price, source: "TCGplayer · \(identity.variant) · raw NM", date: card.tcgplayer?.updatedAt ?? "").converted(rate: rate).map { [$0] } ?? []
            }),
            ("Pokémon TCG API · Cardmarket", {
                guard let market = primary?.cardmarket, !identity.variant.lowercased().contains("1stedition"),
                      let price = identity.variant == "reverseHolofoil" ? market.prices?.reverseHoloTrend : market.prices?.trendPrice,
                      price.isFinite, price >= 0 else { return [] }
                let rate = try await ExchangeRates.shared.rate("EUR")
                return ForeignPrice(amount: price, currency: "EUR", source: "Cardmarket · trend · ikke standsspecifik", date: market.updatedAt ?? "").converted(rate: rate).map { [$0] } ?? []
            }),
            ("JustTCG", { try await ExtraPriceSources.just(identity) }),
            ("PokemonPriceTracker", { try await ExtraPriceSources.tracker(identity) })
        ])
    }
    static func justTCG(productID: String) async throws -> [PriceQuote] {
        guard !productID.isEmpty, productID.allSatisfy(\.isNumber) else { return [] }
        return try await ExtraPriceSources.just(PriceIdentity(name: "", number: "", setName: "", language: "EN", variant: "normal", productID: productID), allVariants: true)
    }
    @MainActor
    static func savedQuotes(_ card: CardItem, productID: String = "") async -> [PriceQuote] {
        var identity = PriceIdentity(name: card.name, number: card.number, setName: card.setName, language: card.language, variant: card.variant)
        if !productID.isEmpty, productID.allSatisfy(\.isNumber) { identity.productID = productID }
        var primary: APICard?
        if identity.english {
            do {
                if !card.apiID.isEmpty {
                    var request = URLRequest(url: URL(string: "https://api.pokemontcg.io/v2/cards/" + card.apiID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!)
                    let key = Keychain.get("pokemonAPI")
                    if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
                    struct Response: Decodable { let data: APICard }
                    primary = try JSONDecoder().decode(Response.self, from: await HTTP.data(request)).data
                } else {
                    let info = CardInfo(name: card.name, number: card.number, language: card.language, setCode: card.setCode)
                    let result = try await CardAPI.search(info, setName: card.setName)
                    if result.total == 1, let match = result.cards.first, CardAPI.score(match, info: info) >= 8 {
                        primary = match
                    }
                }
            } catch { DebugLog.shared.info("Pokémon TCG API: springer over; prøver ekstra priskilder") }
        }
        if identity.productID.isEmpty { identity.productID = PriceIdentity.productID(from: primary?.tcgplayer?.url) }
        return await allQuotes(primary: primary, identity: identity)
    }
}
