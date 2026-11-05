import XCTest
@testable import Kortscanner

final class CollectionDataTests: XCTestCase {
    @MainActor
    func testCopiesKeepTheirOwnState() async {
        let a = CardItem(front: Data([1]), back: nil, info: CardInfo(name: "Pikachu", number: "025/165", language: "EN"))
        let b = CardItem(front: Data([2]), back: nil, info: CardInfo(name: "Pikachu", number: "025/165", language: "EN"))
        a.condition = "NM"; b.condition = "LP"; b.status = "Til salg"
        XCTAssertEqual(a.identityKey, b.identityKey)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.front, b.front)
        XCTAssertEqual(a.status, "Beholder")
    }
    @MainActor
    func testPriceHistoryDoesNotOverwritePreviousValues() async throws {
        let card = CardItem(front: Data([1]), back: nil, info: CardInfo(name: "Pikachu"))
        try card.recordPrice(100, source: "Test", date: Date(timeIntervalSince1970: 100))
        try card.recordPrice(125, source: "Test", date: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(card.priceHistory.map(\.amount), [100, 125])
        XCTAssertEqual(card.priceDKK, 125)
        XCTAssertThrowsError(try card.recordPrice(-10, source: "Test"))
        XCTAssertEqual(card.priceHistory.count, 2)
    }
    @MainActor
    func testBackupRoundTripPreservesPicturesAndHistory() async throws {
        let card = CardItem(front: Data([1, 2, 3]), back: Data([4, 5]), info: CardInfo(name: "Snorlax", number: "143", language: "EN", gradingCompany: "PSA"))
        card.closeup = Data([6])
        card.sequence = 7
        try card.recordPrice(1500, source: "Manuel")
        let archive = BackupEnvelope(cards: [BackupCard(card)], portfolio: [])
        let data = try JSONEncoder().encode(archive)
        let restored = try JSONDecoder().decode(BackupEnvelope.self, from: data)
        try restored.validate()
        let copy = restored.cards[0].create()
        XCTAssertEqual(copy.id, card.id)
        XCTAssertEqual(copy.front, card.front)
        XCTAssertEqual(copy.back, card.back)
        XCTAssertEqual(copy.closeup, card.closeup)
        XCTAssertEqual(copy.priceHistory[0].amount, 1500)
        XCTAssertTrue(copy.keepLocked)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("googleRefreshToken"))
        XCTAssertFalse(json.contains("googleClientID"))
    }
    @MainActor
    func testBackupCannotOverrideProtectedStatus() async {
        let card = CardItem(front: Data([1]), back: nil, info: CardInfo(name: "Moltres", gradingCompany: "PSA"))
        var backup = BackupCard(card)
        backup.status = "Til salg"
        backup.apply(to: card)
        XCTAssertEqual(card.status, "Beholder")
    }
}
