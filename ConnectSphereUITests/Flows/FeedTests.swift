import XCTest

/// P1: the Home feed and posting. Every test acts only on posts its own
/// throwaway account makes, never on real users' posts in the feed.
final class FeedTests: UITestCase {
    private var feed: FeedScreen { FeedScreen(app: app) }

    private func launchSignedIn() async throws {
        let account = try await server.createAccount(run: run)
        launch(signedInAs: account)
        try feed.waitUntilLoaded()
    }

    func testFeedLoads() async throws {
        try await launchSignedIn()
        try feed.loading.waitToDisappear(timeout: 20)
    }

    func testModeSwitchShowsWorkFeed() async throws {
        try await launchSignedIn()
        try feed.mode("work").tapWhenReady()
        try feed.mode("work").waitUntilSelected(true)
        try feed.waitUntilLoaded()
        XCTAssertEqual(feed.composerBar.label, "Share a professional update...")

        try feed.mode("hobby").tapWhenReady()
        try feed.mode("hobby").waitUntilSelected(true)
        XCTAssertEqual(feed.composerBar.label, "What's on your mind?")
    }

    func testNewPostIsOnTop() async throws {
        try await launchSignedIn()
        let text = "QA post \(run)"
        try feed.publish(text)
        XCTAssertEqual(feed.cells.firstMatch.identifier, feed.cell(containing: text).identifier,
                       "the new post should be the first card")
    }

    func testLikeToggles() async throws {
        try await launchSignedIn()
        let like = try feed.publish("QA like \(run)").buttons[AXID.Feed.like]
        try like.tapWhenReady()
        try like.waitUntilSelected(true)
        try like.tapWhenReady()
        try like.waitUntilSelected(false)
    }

    func testCommentAppears() async throws {
        try await launchSignedIn()
        let card = try feed.publish("QA comment target \(run)")
        try card.buttons[AXID.Feed.comment].tapWhenReady()

        let detail = PostDetailScreen(app: app)
        let comment = "QA comment \(run)"
        try detail.field.enter(comment)
        try detail.send.tapWhenReady()
        try detail.row(containing: comment).waitToAppear(timeout: 15)
    }

    func testCancelSavesDraft() async throws {
        try await launchSignedIn()
        try feed.composerBar.tapWhenReady()
        let composer = ComposerScreen(app: app)
        try composer.text.enter("QA draft \(run)")
        try composer.cancel.tapWhenReady()
        // The leave dialog: found by its English text.
        try app.buttons["Save draft"].tapWhenReady()
        try composer.text.waitToDisappear(timeout: 15)

        try feed.composerBar.tapWhenReady()
        try composer.drafts.waitToAppear(timeout: 15)
        XCTAssertEqual(composer.drafts.label, "Drafts (1)")
    }
}
