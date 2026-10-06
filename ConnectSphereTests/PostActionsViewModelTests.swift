import Testing
@testable import ConnectSphere

/// The network-free parts of a post card's actions (the request paths are
/// covered by the app smoke tests against the real server).
@MainActor
struct PostActionsViewModelTests {
    private var post: Post { MockData.friendPosts[0] }

    @Test func seededFromThePost() {
        let vm = PostActionsViewModel(post: post)
        #expect(vm.isLiked == post.isLiked)
        #expect(vm.isSaved == post.isSaved)
        #expect(vm.likeCount == post.likeCount)
        #expect(vm.commentCount == post.commentCount)
        #expect(vm.shareCount == post.shareCount)
        #expect(!vm.isHidden)
    }

    @Test func commentCountNeverGoesNegativeAndFollowsTheParent() {
        let vm = PostActionsViewModel(post: post)
        vm.syncCommentCount(2)
        vm.adjustCommentCount(by: -5)      // a delete cascading replies
        #expect(vm.commentCount == 0)
        vm.adjustCommentCount(by: 1)       // undo
        #expect(vm.commentCount == 1)
        vm.syncCommentCount(7)             // fresh post from the parent wins
        #expect(vm.commentCount == 7)
    }

    @Test func sharingBumpsTheShareCount() {
        let vm = PostActionsViewModel(post: post)
        let before = vm.shareCount
        vm.didShare()
        #expect(vm.shareCount == before + 1)
    }
}
