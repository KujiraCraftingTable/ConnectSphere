import SwiftUI

/// Thin forwarder to `Avatar` kept so the ~30 `AvatarView(user:size:)` call
/// sites don't all have to change at once.
struct AvatarView: View {
    let user: UserProfile
    let size: CGFloat

    var body: some View {
        Avatar(name: user.name, colorHex: user.avatarColor,
               imageURL: user.avatarUrl, diameter: size)
    }
}
