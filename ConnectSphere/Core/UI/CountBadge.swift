import SwiftUI

/// The one unread/count indicator. Palette-filled capsule, white text, clamps
/// at "99+". Replaces the red-capsule / blue-capsule / palette-dot variants
/// scattered across Feed, the message list and notifications. (The tab bar
/// keeps the system `.badge()` — same value, native affordance.)
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
