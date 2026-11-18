import XCTest

/// P2: reporting a post. The post belongs to a second throwaway account; the
/// report's moderation case goes with the run (`DELETE /api/test/runs`).
final class ReportTests: UITestCase {
    func testReportPost() async throws {
        let accounts = try await server.createAccounts(run: run, count: 2)
        let (me, author) = (accounts[0], accounts[1])
        try await server.connect(me, author)
        let postID = try await server.createPost(as: author, content: "QA report target \(run)")

        launch(signedInAs: me)
        try FeedScreen(app: app).waitUntilLoaded()
        // Connections: the author's post is on top there, not lost in For you.
        try app.buttons[AXID.Feed.scope + "connections"].tapWhenReady()
        let card = app.descendants(matching: .any)[AXID.Feed.postCell + postID]
        try card.waitToAppear(timeout: 20)

        try card.buttons[AXID.Feed.more].tapWhenReady()
        // The menu and the sheet are found by their English text.
        try app.buttons["Report post"].tapWhenReady()
        try app.buttons["Spam"].tapWhenReady()
        try app.textViews[AXID.Report.details].enter("QA report \(run)")
        try app.buttons["Submit report"].tapWhenReady()

        let thanks = app.staticTexts["Thanks for letting us know"]
        try thanks.waitToAppear(timeout: 15)
        try app.buttons["Done"].tapWhenReady()
        try thanks.waitToDisappear()
    }
}
