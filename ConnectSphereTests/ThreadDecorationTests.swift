import Testing
@testable import ConnectSphere

struct ThreadDecorationTests {
    @Test func lonelyCommentDrawsNothing() {
        let layout = ThreadDecoration.layout(replyCounts: [])
        #expect(layout.root == .none)
        #expect(layout.replies.isEmpty)
    }

    /// root → [reply A (2 sub-replies), reply B (none)]
    @Test func twoRepliesFirstWithChildren() {
        let layout = ThreadDecoration.layout(replyCounts: [2, 0])
        #expect(layout.root.downFromLevel == 0)

        let (a, aSubs) = layout.replies[0]
        #expect(a.elbowFromLevel == 0)
        #expect(a.passingLevels == [0])          // B still follows
        #expect(a.downFromLevel == 1)            // A has replies
        // A's replies: the root's line keeps going for B; A's own line until its last reply.
        #expect(aSubs[0].passingLevels == [0, 1] && aSubs[0].elbowFromLevel == 1)
        #expect(aSubs[1].passingLevels == [0] && aSubs[1].elbowFromLevel == 1)

        let (b, bSubs) = layout.replies[1]
        #expect(b.passingLevels.isEmpty)         // last reply: the line ends in its elbow
        #expect(b.downFromLevel == nil && bSubs.isEmpty)
    }

    @Test func lastReplyChildrenDoNotCarryTheRootLine() {
        let layout = ThreadDecoration.layout(replyCounts: [0, 1])
        #expect(layout.replies[1].1[0].passingLevels.isEmpty)
    }
}
