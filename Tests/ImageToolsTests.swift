import XCTest
import UIKit
@testable import Kortscanner

final class ImageToolsTests: XCTestCase {
    func testCenteringUsesOpposingBorderWidths() {
        let result = CenteringRatios.measure(outer: CGRect(x: 10, y: 20, width: 100, height: 200),
                                            inner: CGRect(x: 22, y: 28, width: 80, height: 180))
        XCTAssertEqual(result?.horizontal, "60/40")
        XCTAssertEqual(result?.vertical, "40/60")
    }
    func testCenteringRejectsMissingAndOutsideBorders() {
        let outer = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertNil(CenteringRatios.measure(outer: outer, inner: outer))
        XCTAssertNil(CenteringRatios.measure(outer: outer, inner: CGRect(x: -0.1, y: 0.1, width: 0.9, height: 0.8)))
    }
    @MainActor
    func testRotationSwapsPixelDimensionsAndFourTurnsRestoreShape() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 30, width: 40, height: 30))
        }
        var data = try XCTUnwrap(image.pngData())
        data = try XCTUnwrap(ImageRotation.clockwise(data))
        let rotated = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(rotated.width, 60)
        XCTAssertEqual(rotated.height, 40)
        for _ in 0..<3 { data = try XCTUnwrap(ImageRotation.clockwise(data)) }
        let restored = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(restored.width, 40)
        XCTAssertEqual(restored.height, 60)
    }
    func testACEGradingLabel() {
        let info = CardRecognizer.fallbackParse(["ACE GRADING", "Pikachu", "025/165", "GRADE 9", "CERT: 12345678"])
        XCTAssertEqual(info.gradingCompany, "ACE")
        XCTAssertEqual(info.name, "Pikachu")
        XCTAssertEqual(info.grade, "9")
        XCTAssertEqual(info.certNumber, "12345678")
    }
    func testSetAndPrintedTotalAreUsedForSearch() {
        let query = CardAPI.searchQuery(CardInfo(number: "025/165"), setName: "Pokémon 151")
        XCTAssertTrue(query.contains("set.name:\"Pokémon 151\""))
        XCTAssertTrue(query.contains("number:\"25\""))
        XCTAssertTrue(query.contains("set.printedTotal:165"))
    }
    func testGoogleConfigurationErrorsHaveActionableMessages() {
        XCTAssertTrue(GoogleDiagnostics.message(status: 400, code: "invalid_client").contains("iOS"))
        XCTAssertTrue(GoogleDiagnostics.message(status: 403, code: "SERVICE_DISABLED").contains("Aktivér"))
        XCTAssertTrue(GoogleDiagnostics.message(status: 403, code: "access_denied").contains("testbruger"))
    }
}
