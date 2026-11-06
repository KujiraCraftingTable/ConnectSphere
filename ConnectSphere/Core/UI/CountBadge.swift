import SwiftUI

/// The one unread/count indicator. Palette-filled capsule, white text, clamps
/// at "99+". Replaces the red-capsule / blue-capsule / palette-dot variants
/// scattered across Feed, the message list and notifications. (The tab bar
/// keeps the system `.badge()`. Same value, native affordance.)
struct CountBadge: View {
    let count: Int

    @Environment(ThemeManager.self) private var theme

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .appFont(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .padding(.horizontal, count > 9 ? 5 : 0)
                .frame(minWidth: 18, minHeight: 18)
                .background(theme.theme.primary, in: Capsule())
        }
    }
}

/// The unread badge on an icon (iOS 18's stand-in for a toolbar item's
/// system badge): red with white numbers and a thin ring in the background
/// colour that keeps it apart from the icon. Like Messenger's.
struct UnreadBadge: View {
    let count: Int

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .scaledFont(11, .bold)
                .foregroundStyle(.white)
                .padding(.horizontal, count > 9 ? 4 : 0)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color.red, in: Capsule())
                .overlay(Capsule().stroke(AppColors.base(colorScheme), lineWidth: 2))
        }
    }
}
