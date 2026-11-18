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
}
