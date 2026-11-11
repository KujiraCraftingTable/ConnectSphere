import SwiftUI

/// A trailing toolbar button with a red count on its top-right corner,
/// Messenger-style and fully visible: the Feed's message button, a community's
/// "..." for its staff. On iOS 26 the bar
/// puts each item on a shared glass circle that clips anything sticking out
/// of it, so the item draws its own glass circle instead (shared background
/// hidden) and the badge sits on its edge.
struct BadgedToolbarItem<Content: View>: ToolbarContent {
    let button: Content
    let count: Int

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarTrailing) {
                button
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        UnreadBadge(count: count).offset(x: 6, y: -4)
                    }
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigationBarTrailing) {
                button.overlay(alignment: .topTrailing) {
                    UnreadBadge(count: count).offset(x: 8, y: -6)
                }
            }
        }
    }
}
