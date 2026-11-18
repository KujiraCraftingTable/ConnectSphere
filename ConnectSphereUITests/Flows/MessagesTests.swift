import XCTest

/// P2: the inbox, a thread, message requests (Waiting) and archiving. The
/// other side of every chat is a second throwaway account driven by the API.
final class MessagesTests: UITestCase {
    private var inbox: InboxScreen { InboxScreen(app: app) }

    /// Me (in the app) and someone (through the API), both from this run.
    private func twoAccounts() async throws -> (me: TestServer.Account, other: TestServer.Account) {
        let accounts = try await server.createAccounts(run: run, count: 2)
        return (accounts[0], accounts[1])
    }

    /// `other` writes to `me` first, so the chat exists with a message in it.
    private func chat(from other: TestServer.Account, to me: TestServer.Account, _ text: String) async throws -> String {
        let id = try await server.openConversation(as: other, with: me)
        try await server.sendMessage(as: other, conversation: id, content: text)
        return id
    }

    private func launchToHome(as account: TestServer.Account) throws {
        launch(signedInAs: account)
        try FeedScreen(app: app).waitUntilLoaded()
    }

    func testInboxOpensFromHome() async throws {
        let me = try await server.createAccount(run: run)
        try launchToHome(as: me)
        try inbox.open()
    }

    func testReplyAppearsInThread() async throws {
        let (me, other) = try await twoAccounts()
        try await server.connect(me, other)
        let greeting = "Hi from B \(run)"
        let id = try await chat(from: other, to: me, greeting)

        try launchToHome(as: me)
        try inbox.open().row(id).tapWhenReady(timeout: 15)
        let thread = ChatScreen(app: app)
        try thread.message(greeting).waitToAppear(timeout: 15)

        let reply = "Reply \(run)"
        try thread.field.enter(reply)
        try thread.send.tapWhenReady()
        try thread.message(reply).waitToAppear(timeout: 15)
    }

    func testStrangersMessageWaits() async throws {
        let (me, other) = try await twoAccounts()
        let id = try await chat(from: other, to: me, "Hello stranger \(run)")

        try launchToHome(as: me)
        try inbox.open().waiting.tapWhenReady(timeout: 15)
        try app.navigationBars["Waiting"].waitToAppear()
        try inbox.row(id).waitToAppear(timeout: 15)
    }

    func testArchivedChatMovesToArchived() async throws {
        let (me, other) = try await twoAccounts()
        try await server.connect(me, other)
        let id = try await chat(from: other, to: me, "Archive me \(run)")

        try launchToHome(as: me)
        try inbox.open().archive(id)
        try inbox.row(id).waitToDisappear()
        try inbox.archived.tapWhenReady()
        try app.navigationBars["Archived chats"].waitToAppear()
        try inbox.row(id).waitToAppear(timeout: 15)
    }
}
