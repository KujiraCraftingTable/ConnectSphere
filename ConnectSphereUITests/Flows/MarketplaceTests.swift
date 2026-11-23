import XCTest

/// P3: listing one item for sale. A photo is required, so it comes from the
/// system picker (the simulator's sample photos); run cleanup deletes the upload.
final class MarketplaceTests: UITestCase {
    func testSellOneItem() async throws {
        let me = try await server.createAccount(run: run)
        launch(signedInAs: me)
        try FeedScreen(app: app).waitUntilLoaded()
        let community = try CommunityScreen(app: app).open()
        try community.segment("Marketplace").tapWhenReady()

        try app.buttons["Sell"].tapWhenReady(timeout: 15)
        try app.navigationBars["New listing"].waitToAppear()
        try app.buttons["Add photos / videos *"].tapWhenReady()
        try PhotoPicker(app: app).pickFirst()

        let title = "QA item \(run)"
        try app.textFields["What are you selling? *"].enter(title)
        // Next waits for the photo to upload.
        try app.buttons["Next"].tapWhenReady(timeout: 30)
        try app.buttons["Publish"].tapWhenReady(timeout: 15)

        try app.navigationBars["New listing"].waitToDisappear(timeout: 30)
        try app.staticTexts[title].waitToAppear(timeout: 20)
    }

    /// Settings › Marketplace › Deal history.
    private func openDealHistory(as account: TestServer.Account) throws {
        launch(signedInAs: account)
        try FeedScreen(app: app).waitUntilLoaded()
        try MainScreen(app: app).tab(AXID.Tab.profile).tapWhenReady()
        try app.buttons[AXID.Profile.settingsButton].tapWhenReady(timeout: 15)
        try app.navigationBars["Settings"].waitToAppear(timeout: 15)
        let marketplace = app.staticTexts["Marketplace"]
        try scrollUntilExists(marketplace, app: app)
        try marketplace.tapWhenReady()
        try app.buttons[AXID.Marketplace.dealHistoryButton].tapWhenReady(timeout: 15)
        try app.navigationBars["Deal history"].waitToAppear(timeout: 15)
    }

    /// A deal row merges its texts into one label, so it's found by a part of it.
    private func deal(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// One confirmed sale shows on both sides: "Bought from" for the buyer,
    /// "Sold to" for the seller, with the item and the amount.
    func testDealHistoryShowsTheSaleOnBothSides() async throws {
        let seller = try await server.createAccount(run: run)
        let buyer = try await server.createAccount(run: run)
        let title = "QA deal \(run)"
        try await server.createDeal(seller: seller, buyer: buyer, title: title, price: 150_000, quantity: 2)

        try openDealHistory(as: buyer)
        let bought = deal(containing: "Bought from @\(seller.username)")
        try bought.waitToAppear(timeout: 15)
        XCTAssertTrue(bought.label.contains(title), bought.label)
        XCTAssertTrue(bought.label.contains("150.000 ₫ × 2"), bought.label)

        try openDealHistory(as: seller)
        try deal(containing: "Sold to @\(buyer.username)").waitToAppear(timeout: 15)
    }
}
