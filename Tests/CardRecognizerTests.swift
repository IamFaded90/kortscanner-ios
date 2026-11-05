import XCTest
@testable import Kortscanner

final class CardRecognizerTests: XCTestCase {
    func testEnglishCard() {
        let card = CardRecognizer.fallbackParse(["Pikachu", "HP 60", "025/165"])
        XCTAssertEqual(card.name, "Pikachu")
        XCTAssertEqual(card.number, "025/165")
        XCTAssertEqual(card.language, "")
    }
    func testJapaneseCard() {
        XCTAssertEqual(CardRecognizer.fallbackParse(["ピカチュウ", "HP 60", "025/165"]).language, "Japanese")
    }
    func testKoreanCard() {
        XCTAssertEqual(CardRecognizer.fallbackParse(["피카츄", "HP 60"]).language, "Korean")
    }
    func testSkipAbility() {
        XCTAssertEqual(CardRecognizer.fallbackParse(["Ability: Static", "Pikachu", "025/165"]).name, "Pikachu")
    }
    func testPromoNumber() {
        let card = CardRecognizer.fallbackParse(["SWSH101", "Charizard"])
        XCTAssertEqual(card.number, "SWSH101")
        XCTAssertEqual(card.name, "Charizard")
    }
    func testNameMayContainKeyword() {
        XCTAssertEqual(CardRecognizer.fallbackParse(["Mew VSTAR"]).name, "Mew VSTAR")
    }
}

final class CollectionRulesTests: XCTestCase {
    func testProtectedPSACards() {
        XCTAssertTrue(CardItem.isProtected(name: "Moltres", company: "PSA"))
        XCTAssertTrue(CardItem.isProtected(name: "Snorlax", company: "psa"))
        XCTAssertFalse(CardItem.isProtected(name: "Snorlax", company: "BGS"))
        XCTAssertFalse(CardItem.isProtected(name: "Pikachu", company: "PSA"))
    }
    func testLeadingZeros() {
        XCTAssertEqual(CardAPI.normalizedNumber("091/173"), "91")
        XCTAssertEqual(CardAPI.normalizedNumber("TG01/TG30"), "TG01")
    }
    func testSlabMetadata() {
        let info = CardRecognizer.fallbackParse(["PSA 10", "Moltres", "091/173", "CERT: 12345678"])
        XCTAssertEqual(info.name, "Moltres")
        XCTAssertEqual(info.gradingCompany, "PSA")
        XCTAssertEqual(info.grade, "10")
        XCTAssertEqual(info.certNumber, "12345678")
    }
}
