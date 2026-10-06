import Foundation
import Testing
@testable import ConnectSphere

@MainActor
struct StoryViewerViewModelTests {
    /// `viewed: true` so navigation never fires a mark-viewed request.
    private func stories(_ count: Int) throws -> [StoryDTO] {
        let items = (0..<count).map { i in
            """
            {"id":"s\(i)","author_id":"a","image_url":"https://x/\(i).jpg",
             "created_at":"2026-10-07T00:00:00Z","expires_at":"2026-10-08T00:00:00Z","viewed":true,
             "author":{"id":"a","username":"a","display_name":"A","avatar_color":"#000000"}}
            """
        }
        return try JSONDecoder.makeISO8601().decode([StoryDTO].self, from: Data("[\(items.joined(separator: ","))]".utf8))
    }

    @Test func timerAdvancesThenMovesOnAndFinallyCloses() throws {
        let vm = StoryViewerViewModel(stories: try stories(2))
        #expect(!vm.advance(by: StoryViewerViewModel.secondsPerStory / 2))
        #expect(vm.currentIndex == 0)
        #expect(!vm.advance(by: StoryViewerViewModel.secondsPerStory / 2))   // story 1 done → story 2
        #expect(vm.currentIndex == 1)
        #expect(vm.progress == 0)
        #expect(vm.advance(by: StoryViewerViewModel.secondsPerStory))       // last one done → close
    }

    @Test func previousRestartsAStoryUnderWayOtherwiseStepsBack() throws {
        let vm = StoryViewerViewModel(stories: try stories(2))
        _ = vm.next()
        _ = vm.advance(by: 2)            // 40 % through story 2
        vm.previous()
        #expect(vm.currentIndex == 1)
        #expect(vm.progress == 0)
        vm.previous()
        #expect(vm.currentIndex == 0)
    }

    @Test func segmentProgressFillsPastStories() throws {
        let vm = StoryViewerViewModel(stories: try stories(3))
        _ = vm.next()
        _ = vm.advance(by: 1)
        #expect(vm.segmentProgress(0) == 1)
        #expect(vm.segmentProgress(1) > 0 && vm.segmentProgress(1) < 1)
        #expect(vm.segmentProgress(2) == 0)
    }

    @Test func ownStoryIsDecidedByTheSignedInUser() throws {
        let mine = StoryViewerViewModel(stories: try stories(1))
        mine.start(authorId: "a", currentUserId: "a")
        #expect(mine.isOwn)
        let theirs = StoryViewerViewModel(stories: try stories(1))
        theirs.start(authorId: "a", currentUserId: "b")
        #expect(!theirs.isOwn)
    }
}
