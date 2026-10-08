import XCTest
@testable import App

final class SpaceValidationTests: XCTestCase {
    func testNamesAreTrimmedAndBounded() {
        XCTAssertEqual(SpaceStore.cleanName("  Greenwich Uni  "), "Greenwich Uni")
        XCTAssertNil(SpaceStore.cleanName("   "))
        XCTAssertNil(SpaceStore.cleanName(nil))
        XCTAssertNil(SpaceStore.cleanName(String(repeating: "a", count: 31)))
        XCTAssertEqual(SpaceStore.cleanName(String(repeating: "á", count: 30))?.count, 30)
    }

    func testOnlyPaletteColoursAndKnownModes() throws {
        XCTAssertEqual(try SpacesController.validColor("teal"), "teal")
        XCTAssertThrowsError(try SpacesController.validColor("#ff0000"))
        XCTAssertThrowsError(try SpacesController.validColor("blue'); DROP TABLE users;--"))
        XCTAssertEqual(SpaceStore.modes, ["hobby", "work"])
    }
}
