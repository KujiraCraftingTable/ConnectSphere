import SwiftUI

// MARK: - Decoration layout
/// What one comment row draws in its left gutter so a thread reads as a tree
/// (Facebook-style): a line runs down from under a parent's avatar and curves
/// into each reply's avatar, and keeps running past a reply while more of its
/// siblings follow. Each row only draws its own slice, top to bottom; because
/// the rows sit flush in the list, the slices join into continuous lines.
struct ThreadDecoration: Equatable {
    /// Thread levels whose line passes straight through this row. A
    /// sibling at that level still comes after it.
    var passingLevels: [Int] = []
    /// The parent's level when this row is a reply: the line comes down from
    /// the top of the row and curves into this row's avatar.
    var elbowFromLevel: Int? = nil
    /// This row's own level, when it has replies: a line starts under its avatar.
    var downFromLevel: Int? = nil

    static let none = ThreadDecoration()

    /// Lays out a whole thread: `replyCounts[i]` is how many third-level
    /// replies sit under the thread's i-th reply. Returned in display order. Root, then
    /// each reply followed by its own replies.
    static func layout(replyCounts: [Int]) -> (root: ThreadDecoration, replies: [(ThreadDecoration, [ThreadDecoration])]) {
        let root = ThreadDecoration(downFromLevel: replyCounts.isEmpty ? nil : 0)
        let replies = replyCounts.enumerated().map { index, subCount -> (ThreadDecoration, [ThreadDecoration]) in
            let moreReplies = index < replyCounts.count - 1
            let reply = ThreadDecoration(passingLevels: moreReplies ? [0] : [],
                                         elbowFromLevel: 0,
                                         downFromLevel: subCount > 0 ? 1 : nil)
            let subs = (0..<subCount).map { j in
                ThreadDecoration(passingLevels: (moreReplies ? [0] : []) + (j < subCount - 1 ? [1] : []),
                                 elbowFromLevel: 1)
            }
            return (reply, subs)
        }
        return (root, replies)
    }
}

// MARK: - Lines shape
/// Draws a `ThreadDecoration` for a row whose content starts at the thread's
/// left edge (indent included), using `CommentRow`'s avatar geometry.
struct ThreadLinesShape: Shape {
    let decoration: ThreadDecoration
    /// This row's own level (0 = top-level comment).
    let level: Int

    static let indentStep: CGFloat = 44
    private let radius: CGFloat = 12

    private func centerX(_ level: Int) -> CGFloat {
        CGFloat(level) * Self.indentStep + CommentRow.horizontalInset + CommentRow.avatarSize / 2
    }
    private var avatarCenterY: CGFloat { CommentRow.verticalInset + CommentRow.avatarSize / 2 }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for passing in decoration.passingLevels {
            path.move(to: CGPoint(x: centerX(passing), y: 0))
            path.addLine(to: CGPoint(x: centerX(passing), y: rect.height))
        }
        if let parent = decoration.elbowFromLevel {
            let x = centerX(parent)
            let avatarLeft = centerX(level) - CommentRow.avatarSize / 2 - 3
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: avatarCenterY - radius))
            path.addQuadCurve(to: CGPoint(x: x + radius, y: avatarCenterY),
                              control: CGPoint(x: x, y: avatarCenterY))
            path.addLine(to: CGPoint(x: avatarLeft, y: avatarCenterY))
        }
        if let own = decoration.downFromLevel {
            path.move(to: CGPoint(x: centerX(own), y: CommentRow.verticalInset + CommentRow.avatarSize + 3))
            path.addLine(to: CGPoint(x: centerX(own), y: rect.height))
        }
        return path
    }
}

// MARK: - View modifier
extension View {
    /// Thread connector lines behind a comment row (the bubble and avatar draw on top).
    func threadLines(_ decoration: ThreadDecoration, level: Int, color: Color) -> some View {
        background(alignment: .topLeading) {
            ThreadLinesShape(decoration: decoration, level: level)
                // Square ends: rows meet edge to edge, and two rounded caps
                // overlapping at every row boundary showed as a notch.
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .round))
                .accessibilityHidden(true)
        }
    }
}
