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

    /// Photo viewer: Comment shrinks the photo to the top third with the
    /// comments panel below; tapping the photo brings it back to full view.
    func testPhotoViewerCommentsPanel() async throws {
        let account = try await server.createAccount(run: run)
        let text = "QA photo \(run)"
        _ = try await server.createPhotoPost(as: account, content: text)
        launch(signedInAs: account)
        try feed.waitUntilLoaded()

        // The account's own profile lists its one post; its photo is the only "Photo".
        try MainScreen(app: app).tab(AXID.Tab.profile).tapWhenReady()
        let photo = app.buttons["Photo"].firstMatch
        try photo.waitToAppear(timeout: 20)
        for _ in 0..<6 where !photo.isHittable { app.swipeUp() }
        try photo.tapWhenReady()

        let panel = app.descendants(matching: .any)[AXID.Feed.viewerPanel]
        try app.buttons[AXID.Feed.viewerComment].firstMatch.tapWhenReady()
        try panel.waitToAppear(timeout: 10)
        XCTAssertTrue(app.staticTexts[text].firstMatch.waitForExistence(timeout: 5),
                      "the panel should show the caption")
        XCTAssertTrue(app.textViews[AXID.Comments.field].waitForExistence(timeout: 5),
                      "the panel should have the comment composer")

        // A tap on the shrunk photo closes the panel.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        try panel.waitToDisappear(timeout: 10)
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
