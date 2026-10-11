import Foundation
import Testing
@testable import ConnectSphere

@MainActor
struct MutedWordsTests {
    private func word(expiresIn seconds: TimeInterval?, now: Date) -> MutedWord {
        MutedWord(id: "w", word: "spoiler", expiresAt: seconds.map { now.addingTimeInterval($0) }, createdAt: now)
    }

    @Test func remainingTimeRoundsUp() {
        let now = Date()
        #expect(word(expiresIn: nil, now: now).remaining(at: now) == .forever)
        #expect(word(expiresIn: 7 * 86_400, now: now).remaining(at: now) == .days(7))
        #expect(word(expiresIn: 86_400 + 60, now: now).remaining(at: now) == .days(2))
        #expect(word(expiresIn: 5 * 3_600 - 10, now: now).remaining(at: now) == .hours(5))
        #expect(word(expiresIn: 600, now: now).remaining(at: now) == .underAnHour)
        #expect(word(expiresIn: -60, now: now).remaining(at: now) == .underAnHour)
    }

    @Test func inputIsCleanedLikeTheServer() {
        #expect(MutedWordsViewModel.cleaned("  #Spoiler ") == "Spoiler")
        #expect(MutedWordsViewModel.cleaned("game   of thrones") == "game of thrones")
        #expect(MutedWordsViewModel.cleaned("!!!") == nil)
        #expect(MutedWordsViewModel.cleaned("   ") == nil)
        #expect(MutedWordsViewModel.cleaned(String(repeating: "a", count: 51)) == nil)
        #expect(MutedWordsViewModel.cleaned("chết") == "chết")
    }

    @Test func mutedCommentsStartCollapsedUntilShown() throws {
        let json = """
            [{"id":"c1","content":"spoiler!","created_at":"2026-10-12T09:00:00.000Z","muted":true,
              "author":{"id":"u1","display_name":"A","avatar_color":"#111111"}},
             {"id":"c2","content":"hi","created_at":"2026-10-12T09:01:00.000Z",
              "author":{"id":"u2","display_name":"B","avatar_color":"#222222"}}]
            """
        let comments = try JSONDecoder.makeISO8601().decode([CommentDTO].self, from: Data(json.utf8))
        #expect(comments.map(\.muted) == [true, false])     // absent flag = not muted
        let vm = CommentViewModel()
        #expect(vm.isCollapsed(comments[0]) && !vm.isCollapsed(comments[1]))
        vm.reveal("c1")
        #expect(!vm.isCollapsed(comments[0]))
    }

    @Test func durationsMatchTheServerKeys() {
        #expect(MuteDuration.allCases.map(\.rawValue) == ["24h", "7d", "30d", "forever"])
    }
}
