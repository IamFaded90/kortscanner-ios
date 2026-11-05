import XCTest
@testable import Kortscanner

final class ExtraPriceTests: XCTestCase {
    private var identity: PriceIdentity {
        PriceIdentity(name: "Pikachu", number: "025/165", setName: "151", language: "EN", variant: "normal", productID: "123")
    }
    func testJustFiltersConditionPrintingLanguageAndExpiredPrices() throws {
        let json = """
        {"data":[{"name":"Pikachu","tcgplayerId":"123","variants":[
          {"condition":"Near Mint","printing":"Normal","price":10,"priceStatus":"current","language":"English"},
          {"condition":"Lightly Played","printing":"Normal","price":7},
          {"condition":"Near Mint","printing":"Reverse Holofoil","price":20},
          {"condition":"Near Mint","printing":"Normal","price":null,"priceStatus":"expired"},
          {"condition":"Near Mint","printing":"Normal","price":15,"language":"Japanese"}
        ]}]}
        """
        let result = try ExtraPriceSources.parseJust(Data(json.utf8), identity: identity)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.amount, 10)
        XCTAssertTrue(result.first?.source.hasPrefix("JustTCG") == true)
    }
    func testTrackerDecodesSingleObjectAndUsesNMVariantNotHeadline() throws {
        let json = """
        {"data":{"tcgPlayerId":"123","name":"Pikachu","prices":{"market":999,"lastUpdated":"2026-11-05"},
        "variants":{"Normal":{"marketPrice":12,"conditionUsed":"Near Mint"},
                    "Reverse Holofoil":{"marketPrice":22,"conditionUsed":"Near Mint"}}}}
        """
        let result = try ExtraPriceSources.parseTracker(Data(json.utf8), identity: identity)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.amount, 12)
        XCTAssertEqual(result.first?.date, "2026-11-05")
    }
    func testTrackerSkipsNonNMAndMismatchedProducts() throws {
        let json = """
        {"data":[{"tcgPlayerId":"123","name":"Pikachu","variants":{"Normal":{"marketPrice":8,"conditionUsed":"Lightly Played"}}},
                 {"tcgPlayerId":"456","name":"Pikachu","variants":{"Normal":{"marketPrice":100,"conditionUsed":"Near Mint"}}}]}
        """
        XCTAssertTrue(try ExtraPriceSources.parseTracker(Data(json.utf8), identity: identity).isEmpty)
        XCTAssertTrue(try ExtraPriceSources.parseTracker(Data("{\"data\":null}".utf8), identity: identity).isEmpty)
    }
    func testSearchMatchRequiresNameNumberAndSet() {
        var target = identity
        target.productID = ""
        XCTAssertTrue(target.matches(name: "PIKACHU", number: "25", set: "151"))
        XCTAssertFalse(target.matches(name: "Pikachu", number: "25", set: "Base Set"))
        XCTAssertFalse(target.matches(name: "Pikachu ex", number: "25", set: "151"))
        XCTAssertFalse(target.matches(name: "Pikachu", number: "26", set: "151"))
        XCTAssertTrue(target.matches(name: "Pikachu", number: "25", set: "SV: Scarlet & Violet 151"))
        XCTAssertNotEqual(PriceIdentity.setKey("Evolutions"), PriceIdentity.setKey("Prismatic Evolutions"))
    }
    func testConversionUsesRealRateAndRejectsInvalidPrices() {
        let rate = ExchangeRates.Rate(date: "2026-11-05", rate: 6.5)
        let quote = ForeignPrice(amount: 10, source: "JustTCG · raw NM", date: "2026-11-04").converted(rate: rate)
        XCTAssertEqual(quote?.dkk, 65)
        XCTAssertEqual(quote?.rateDate, "2026-11-05")
        XCTAssertEqual(quote?.sourceDate, "2026-11-04")
        XCTAssertNil(ForeignPrice(amount: -1, source: "Test", date: "").converted(rate: rate))
        XCTAssertNil(ForeignPrice(amount: .infinity, source: "Test", date: "").converted(rate: rate))
    }
    func testFailedProviderDoesNotBlockOtherSources() async {
        let result = await PriceService.collect([
            ("Manglende", { [] }),
            ("Afvist", { throw APIError.http(429) }),
            ("Fungerer", { [PriceQuote(dkk: 65, source: "PokemonPriceTracker", sourceDate: "", rateDate: "")] })
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.dkk, 65)
        XCTAssertEqual(result.first?.source, "PokemonPriceTracker")
    }
    func testRateLimitIsPausedAndAnotherProviderStillRuns() async throws {
        let counter = RequestCounter()
        let gate = PriceProviderRequests(loader: { request in
            await counter.increment()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After":"60"])!)
        })
        let request = URLRequest(url: URL(string: "https://example.invalid/price")!)
        _ = try await gate.data(provider: "JustTCG", request: request)
        _ = try await gate.data(provider: "JustTCG", request: request)
        let first = await counter.value
        XCTAssertEqual(first, 1)
        _ = try await gate.data(provider: "PokemonPriceTracker", request: request)
        let second = await counter.value
        XCTAssertEqual(second, 2)
    }
    func testProductIDIsTakenOnlyFromTCGplayerProductURL() {
        XCTAssertEqual(PriceIdentity.productID(from: "https://www.tcgplayer.com/product/123/card"), "123")
        XCTAssertEqual(PriceIdentity.productID(from: "https://other.example/product/123/card"), "")
    }
}
private actor RequestCounter {
    var value = 0
    func increment() { value += 1 }
}
