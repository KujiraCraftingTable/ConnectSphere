import Foundation
import Testing
@testable import ConnectSphere

/// The login screen's "Continue as" list.
struct SavedAccountsTests {
    private func store() -> SavedAccounts {
        let defaults = UserDefaults(suiteName: "SavedAccountsTests-\(UUID().uuidString)")!
        return SavedAccounts(defaults: defaults)
    }
    private func account(_ id: String, _ username: String, at seconds: TimeInterval) -> SavedAccount {
        SavedAccount(id: id, username: username, displayName: username.capitalized, avatarUrl: nil,
                     avatarColor: "#123456", hasPassword: true, lastUsed: Date(timeIntervalSince1970: seconds))
    }

    @Test func newestFirst() {
        let s = store()
        s.remember(account("1", "ann", at: 100))
        s.remember(account("2", "bob", at: 200))
        #expect(s.all().map(\.username) == ["bob", "ann"])
    }

    @Test func sameAccountIsReplacedEvenIfRenamed() {
        let s = store()
        s.remember(account("1", "ann", at: 100))
        s.remember(account("1", "ann_new", at: 300))
        #expect(s.all().map(\.username) == ["ann_new"])
    }

    @Test func keepsAtMostFive() {
        let s = store()
        for i in 1...7 { s.remember(account("\(i)", "u\(i)", at: TimeInterval(i))) }
        #expect(s.all().map(\.username) == ["u7", "u6", "u5", "u4", "u3"])
    }

    @Test func forgetRemovesOnlyThatOne() {
        let s = store()
        s.remember(account("1", "ann", at: 100))
        s.remember(account("2", "bob", at: 200))
        s.forget(id: "2")
        #expect(s.all().map(\.username) == ["ann"])
    }
}
