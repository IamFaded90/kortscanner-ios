import XCTest
@testable import Kortscanner

final class CompatibilityTests: XCTestCase {
    @MainActor
    func testCollectionAnswersWithoutIntelligenceUseActualUnsoldPrices() async throws {
        let cheap = CardItem(front: Data(), back: nil, info: CardInfo(name: "Pikachu"))
        let expensive = CardItem(front: Data(), back: nil, info: CardInfo(name: "Eevee"))
        let sold = CardItem(front: Data(), back: nil, info: CardInfo(name: "Charizard"))
        try cheap.recordPrice(100, source: "Test")
        try expensive.recordPrice(250, source: "Test")
        try sold.recordPrice(9999, source: "Test")
        sold.status = "Solgt"
        let cards = [cheap, expensive, sold]
        let answer = await CollectionAssistant.answer("Hvad er mit dyreste kort?", cards: cards, useIntelligence: false)
        XCTAssertTrue(answer.contains("Eevee"))
        XCTAssertTrue(answer.contains(dkk(250)))
        let total = await CollectionAssistant.answer("Hvad er min samling værd?", cards: cards, useIntelligence: false)
        XCTAssertTrue(total.contains(dkk(350)))
        XCTAssertFalse(total.contains(dkk(9999)))
    }

    @MainActor
    func testSalesTemplateWorksWithoutIntelligenceAndPreservesPrice() async throws {
        let card = CardItem(front: Data(), back: nil, info: CardInfo(name: "Pikachu", number: "025/165", language: "EN"))
        card.condition = "LP"
        try card.recordPrice(123.45, source: "Manuel")
        let text = try await SalesService.draft(card, useIntelligence: false)
        XCTAssertTrue(text.contains("DANSK"))
        XCTAssertTrue(text.contains("ENGLISH"))
        XCTAssertTrue(text.contains("025/165"))
        XCTAssertTrue(text.contains("LP"))
        XCTAssertTrue(text.contains(dkk(123.45)))
    }
}
