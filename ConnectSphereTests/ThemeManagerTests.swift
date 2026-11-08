import XCTest
@testable import ConnectSphere

/// The colour theme belongs to the account, not the device.
final class ThemeManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ThemeManagerTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testSwitchingAccountsSwitchesTheColour() {
        let theme = ThemeManager(defaults: defaults)
        theme.apply(AccountTheme(userID: "a", hobby: "blue", work: "navy"))
        XCTAssertEqual(theme.paletteId(for: .hobby), "blue")
        theme.apply(AccountTheme(userID: "b", hobby: "candy", work: "forest"))
        XCTAssertEqual(theme.paletteId(for: .hobby), "candy")
        XCTAssertEqual(theme.paletteId(for: .work), "forest")
        theme.apply(AccountTheme(userID: "a", hobby: "blue", work: "navy"))
        XCTAssertEqual(theme.paletteId(for: .hobby), "blue")
    }

    func testLaunchShowsTheLastAccountsCachedColour() {
        let first = ThemeManager(defaults: defaults)
        first.apply(AccountTheme(userID: "b", hobby: "candy", work: "slate"))
        let relaunch = ThemeManager(defaults: defaults)
        XCTAssertEqual(relaunch.paletteId(for: .hobby), "candy")
        XCTAssertEqual(relaunch.paletteId(for: .work), "slate")
    }

    func testUnknownServerValueUsesCacheThenDefault() {
        let theme = ThemeManager(defaults: defaults)
        theme.apply(AccountTheme(userID: "a", hobby: nil, work: "navy-ish"))
        XCTAssertEqual(theme.paletteId(for: .hobby), ThemeManager.defaultPaletteId)
        XCTAssertEqual(theme.paletteId(for: .work), ThemeManager.defaultPaletteId)

        theme.selectPalette(id: "rose", for: .hobby)
        theme.apply(AccountTheme(userID: "a", hobby: nil, work: nil))   // cached launch
        XCTAssertEqual(theme.paletteId(for: .hobby), "rose")
    }

    func testAPickStaysWithItsAccount() {
        let theme = ThemeManager(defaults: defaults)
        theme.apply(AccountTheme(userID: "a", hobby: nil, work: nil))
        theme.selectPalette(id: "tropical", for: .hobby)
        theme.apply(AccountTheme(userID: "b", hobby: nil, work: nil))
        XCTAssertEqual(theme.paletteId(for: .hobby), ThemeManager.defaultPaletteId)
    }

    func testAModeOnlyTakesItsOwnPalettes() {
        let theme = ThemeManager(defaults: defaults)
        theme.selectPalette(id: "navy", for: .hobby)
        XCTAssertEqual(theme.paletteId(for: .hobby), ThemeManager.defaultPaletteId)
    }
}
