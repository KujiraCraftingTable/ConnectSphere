import XCTest

/// ConversationListView, with its Waiting and Archived lists.
struct InboxScreen {
    let app: XCUIApplication

    var waiting: XCUIElement { app.descendants(matching: .any)[AXID.Chat.waiting] }
    var archived: XCUIElement { app.descendants(matching: .any)[AXID.Chat.archived] }

    /// A chat's row in whichever list is showing.
    func row(_ conversationID: String) -> XCUIElement {
        app.descendants(matching: .any)[AXID.Chat.row + conversationID]
    }

    /// From Home's Messages button.
    @discardableResult
    func open() throws -> Self {
        try app.buttons[AXID.Chat.inboxButton].tapWhenReady()
        try app.navigationBars["Messages"].waitToAppear(timeout: 15)
        return self
    }

    /// Swipe, the "More" menu, Archive.
    func archive(_ conversationID: String) throws {
        try row(conversationID).waitToAppear(timeout: 15).swipeLeft()
        try app.buttons.matching(NSPredicate(format: "label == %@", "More")).hittable(scrolling: false).tap()
        try app.buttons["Archive"].tapWhenReady()
    }
}

/// ChatView.
struct ChatScreen {
    let app: XCUIApplication

    var field: XCUIElement { app.descendants(matching: .any)[AXID.Chat.messageField] }
    var send: XCUIElement { app.buttons[AXID.Chat.send] }

    func message(_ text: String) -> XCUIElement { app.staticTexts[text] }
}
