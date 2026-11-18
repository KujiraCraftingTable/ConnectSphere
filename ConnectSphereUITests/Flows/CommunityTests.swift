import XCTest

/// P3: creating a community (cover photo from the picker) and joining one.
final class CommunityTests: UITestCase {
    private var community: CommunityScreen { CommunityScreen(app: app) }

    private func launchToCommunity(as account: TestServer.Account) throws {
        launch(signedInAs: account)
        try FeedScreen(app: app).waitUntilLoaded()
        try community.open()
    }

    func testCreateCommunity() async throws {
        let me = try await server.createAccount(run: run)
        try launchToCommunity(as: me)

        try app.buttons["Create community"].tapWhenReady()
        try app.buttons[AXID.Community.coverButton].tapWhenReady()
        try PhotoPicker(app: app).pickFirst()
        // The picked photo opens the cover crop screen.
        try app.navigationBars["Adjust cover"].buttons["Done"].tapWhenReady(timeout: 15)

        let name = "QA community \(run)"
        try app.textFields["Community name"].enter(name)
        try app.buttons["Create"].tapWhenReady()
        try app.navigationBars["Create community"].waitToDisappear(timeout: 30)

        try community.segment("My communities").tapWhenReady()
        try app.staticTexts[name].waitToAppear(timeout: 15)
    }

    func testJoinPublicCommunity() async throws {
        let accounts = try await server.createAccounts(run: run, count: 2)
        let (me, owner) = (accounts[0], accounts[1])
        let name = "QA join \(run)"
        let id = try await server.createCommunity(owner: owner, name: name)

        try launchToCommunity(as: me)
        try community.segment("Discover").tapWhenReady()
        // Discover lists the 20 biggest; a one-member community is only found by searching.
        try app.searchFields["Search communities"].enter(name)
        let row = community.row(id)
        try row.waitToAppear(timeout: 20)
        try row.buttons["Join"].tapWhenReady()
        try row.buttons["Joined"].waitToAppear(timeout: 15)
    }
}
