import XCTest

/// Home: the mode switch, the composer bar and the post list.
struct FeedScreen {
    let app: XCUIApplication

    var composerBar: XCUIElement { app.buttons[AXID.Feed.composerBar] }
    var empty: XCUIElement { app.descendants(matching: .any)[AXID.Feed.empty] }
    var loading: XCUIElement { app.descendants(matching: .any)[AXID.Common.loading] }
    var cells: XCUIElementQuery { app.descendants(matching: .any).withIDPrefix(AXID.Feed.postCell) }

    func mode(_ mode: String) -> XCUIElement { app.buttons[AXID.Feed.mode + mode] }

    /// The card showing `text` (the list is lazy: only cards on screen exist).
    func cell(containing text: String) -> XCUIElement {
        cells.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Waits for the first page: some cards, or the empty state.
    @discardableResult
    func waitUntilLoaded(timeout: TimeInterval = 20) throws -> Self {
        try composerBar.waitToAppear(timeout: timeout)
        try waitForAny([cells.firstMatch, empty], timeout: timeout)
        return self
    }

    /// Writes and publishes a text post, then returns its card (new posts go on top).
    @discardableResult
    func publish(_ text: String) throws -> XCUIElement {
        try composerBar.tapWhenReady()
        let composer = ComposerScreen(app: app)
        try composer.text.enter(text)
        try composer.post.tapWhenReady()
        // Publishing has taken over 15 s while the dev server (same DB and Ollama) was busy.
        try composer.text.waitToDisappear(timeout: 45)
        return try cell(containing: text).waitToAppear(timeout: 20)
    }
}

/// CreatePostView.
struct ComposerScreen {
    let app: XCUIApplication

    var text: XCUIElement { app.textViews[AXID.Composer.text] }
    var post: XCUIElement { app.buttons[AXID.Composer.post] }
    var cancel: XCUIElement { app.buttons[AXID.Composer.cancel] }
    var drafts: XCUIElement { app.buttons[AXID.Composer.drafts] }
}

/// PostDetailView, where a feed card's comment button leads.
struct PostDetailScreen {
    let app: XCUIApplication

    var field: XCUIElement { app.textViews[AXID.Comments.field] }
    var send: XCUIElement { app.buttons[AXID.Comments.send] }

    func row(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).withIDPrefix(AXID.Comments.row)
            .containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}

/// Waits until any one of `elements` exists.
func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) throws {
    let start = Date()
    repeat {
        if elements.contains(where: \.exists) { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    } while Date().timeIntervalSince(start) < timeout
    throw UIStepFailed(description: "none of \(elements) appeared")
}

extension XCUIElement {
    /// Waits for the selected state (likes and the mode switch use `.isSelected`).
    func waitUntilSelected(_ selected: Bool, timeout: TimeInterval = 10) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == %@", NSNumber(value: selected)), object: self)
        guard XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed else {
            throw UIStepFailed(description: "\(self) never became \(selected ? "selected" : "unselected")")
        }
    }

    /// Waits for its accessibility value (a settings switch row reads "On" / "Off").
    func waitUntilValue(_ value: String, timeout: TimeInterval = 10) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: self)
        guard XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed else {
            throw UIStepFailed(description: "\(self) never read \(value)")
        }
    }
}
