import XCTest

/// P3: two-factor off and on, and deleting the account. All need a verified
/// email; the emailed codes come from the test server.
final class SettingsTests: UITestCase {
    /// Settings rows are NavigationLinks whose label merges icon and text, so
    /// they're tapped by their text.
    private func launchToManageAccount(as account: TestServer.Account) throws {
        launch(signedInAs: account)
        try FeedScreen(app: app).waitUntilLoaded()
        try MainScreen(app: app).tab(AXID.Tab.profile).tapWhenReady()
        try app.buttons[AXID.Profile.settingsButton].tapWhenReady(timeout: 15)
        let manage = app.staticTexts["Manage account"]
        try app.navigationBars["Settings"].waitToAppear(timeout: 15)
        try scrollUntilExists(manage, app: app)
        try manage.tapWhenReady()
        try app.navigationBars["Manage account"].waitToAppear()
    }

    /// "Send a code to <masked email>", then the code from the test server.
    private func confirmWithEmailedCode(_ account: TestServer.Account) async throws {
        try app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send a code to")).firstMatch
            .tapWhenReady(timeout: 15)
        let field = app.textFields[AXID.Common.codeField]
        try field.waitToAppear(timeout: 15)
        let code = try await server.lastCode(for: try XCTUnwrap(account.email))
        try field.enter(code)
        try app.buttons[AXID.Common.codeConfirm].tapWhenReady()
    }

    private func setTwoFactor(_ on: Bool, _ account: TestServer.Account) async throws {
        let toggle = app.switches[AXID.Settings.twoFactorToggle]
        try toggle.tapWhenReady()
        try app.navigationBars["Two-factor authentication"].waitToAppear()
        try await confirmWithEmailedCode(account)
        try app.navigationBars["Two-factor authentication"].waitToDisappear(timeout: 15)
        try toggle.waitUntilValue(on ? "On" : "Off")
    }

    private func openPrivacy(as account: TestServer.Account) throws -> XCUIElement {
        try launchToManageAccount(as: account)
        let privacy = app.staticTexts["Privacy & Security"]
        try scrollUntilExists(privacy, app: app)
        try privacy.tapWhenReady()
        let toggle = app.switches[AXID.Settings.twoFactorToggle]
        try scrollUntilExists(toggle, app: app)
        return toggle
    }

    // Off and on are separate accounts: a second code within a minute is refused (429).
    func testTurnTwoFactorOff() async throws {
        let me = try await server.createAccount(run: run, kind: .twoFactor)
        try openPrivacy(as: me).waitUntilValue("On")
        try await setTwoFactor(false, me)
    }

    func testTurnTwoFactorOn() async throws {
        let me = try await server.createAccount(run: run, kind: .verifiedEmail)
        try openPrivacy(as: me).waitUntilValue("Off")
        try await setTwoFactor(true, me)
    }

    func testDeleteAccount() async throws {
        let me = try await server.createAccount(run: run, kind: .verifiedEmail)
        try launchToManageAccount(as: me)
        let row = app.staticTexts["Delete account"]
        try scrollUntilExists(row, app: app)
        try row.tapWhenReady()

        try await confirmWithEmailedCode(me)
        // The last check is a system alert, found by its English text.
        try app.alerts["Delete your account?"].buttons["Delete"].tapWhenReady()
        try LoginScreen(app: app).identifier.waitToAppear(timeout: 20)
    }
}
