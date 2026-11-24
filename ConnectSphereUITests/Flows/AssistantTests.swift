import XCTest

/// The in-app assistant, opened from the top of Settings: a safe setting it
/// changes with Undo, a "Take me there" that lands on the right sheet, and a
/// picked chat whose settings it opens.
final class AssistantTests: UITestCase {
    /// Profile → Settings → Ask the assistant.
    private func openAssistantFromSettings(as account: TestServer.Account) throws {
        launch(signedInAs: account)
        try FeedScreen(app: app).waitUntilLoaded()
        try MainScreen(app: app).tab(AXID.Tab.profile).tapWhenReady()
        try app.buttons[AXID.Profile.settingsButton].tapWhenReady(timeout: 15)
        try app.navigationBars["Settings"].waitToAppear(timeout: 15)
        try app.buttons[AXID.Assistant.settingsRow].tapWhenReady()
        try app.textFields[AXID.Assistant.input].waitToAppear()
    }

    private func ask(_ text: String) throws {
        try app.textFields[AXID.Assistant.input].enter(text)
        try app.buttons[AXID.Assistant.sendButton].tapWhenReady()
    }

    /// The switch really changes (asking again says it's already off), and
    /// Undo puts it back and says what it is now.
    func testTurnsOffMessageSoundsAndUndoes() async throws {
        let me = try await server.createAccount(run: run)
        try openAssistantFromSettings(as: me)

        try ask("turn off message sounds")
        try app.staticTexts["Message sounds are off."].waitToAppear()
        try ask("turn off message sounds")
        try app.staticTexts["That's already set."].waitToAppear()

        try app.buttons[AXID.Assistant.undo].tapWhenReady()
        try app.staticTexts["Changed back. Message sounds are on."].waitToAppear()
    }

    /// Privacy settings are explained, not changed: the button opens the
    /// Change password sheet on Privacy & Security.
    func testTakeMeThereOpensChangePassword() async throws {
        let me = try await server.createAccount(run: run)
        try openAssistantFromSettings(as: me)

        try ask("how do i change my password")
        try app.buttons[AXID.Assistant.takeMeThere].tapWhenReady()
        try app.navigationBars["Change password"].waitToAppear(timeout: 15)
    }

    /// "mute a chat" lists recent chats; picking one opens that chat's
    /// settings, all the way from Settings through Home and Messages.
    func testPickedChatOpensItsSettings() async throws {
        let me = try await server.createAccount(run: run)
        let friend = try await server.createAccount(run: run)
        try await server.connect(me, friend)
        let chat = try await server.openConversation(as: me, with: friend)
        try await server.sendMessage(as: friend, conversation: chat, content: "hi from the test")

        try openAssistantFromSettings(as: me)
        try ask("mute a chat")
        try app.buttons[AXID.Assistant.chatChoice(chat)].tapWhenReady(timeout: 15)
        try app.navigationBars["Chat settings"].waitToAppear(timeout: 20)
    }
}
