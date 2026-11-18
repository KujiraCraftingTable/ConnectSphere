import XCTest

/// P3: a verified recruiter's job is listed in Work's Jobs tab, and Easy Apply
/// marks it applied.
final class JobsTests: UITestCase {
    func testApplyToJob() async throws {
        let accounts = try await server.createAccounts(run: run, count: 2)
        let (me, recruiter) = (accounts[0], accounts[1])
        try await server.makeRecruiter(recruiter)
        let title = "QA job \(run)"
        _ = try await server.createJob(as: recruiter, title: title)

        launch(signedInAs: me)
        let feed = FeedScreen(app: app)
        try feed.waitUntilLoaded()
        try feed.mode("work").tapWhenReady()
        try feed.mode("work").waitUntilSelected(true)
        try MainScreen(app: app).tab(AXID.Tab.jobs).tapWhenReady()
        try app.navigationBars["Jobs"].waitToAppear(timeout: 15)

        let card = app.staticTexts[title]
        try scrollUntilExists(card, app: app)
        try card.tapWhenReady()
        try app.navigationBars["Job"].waitToAppear(timeout: 15)
        try app.buttons["Apply"].tapWhenReady()
        try app.buttons["Send"].tapWhenReady(timeout: 15)
        try app.descendants(matching: .any)["Applied"].waitToAppear(timeout: 15)
    }
}
