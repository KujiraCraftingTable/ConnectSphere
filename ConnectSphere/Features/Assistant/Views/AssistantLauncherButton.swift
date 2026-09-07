import SwiftUI

/// Floating round button — visible app-wide, bottom-trailing — that opens the
/// in-app AI assistant chat. Mirrors `CommunityDetailView.createPostFAB`'s
/// exact visual recipe (54×54 circle, theme accent background, drop shadow)
/// for visual consistency, but mounted globally from `MainTabView` instead of
/// a single pushed screen. Uses "sparkles" rather than a chat-bubble glyph so
/// it doesn't collide conceptually with the existing Messages icon in Home.
struct AssistantLauncherButton: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 54, height: 54)
                .background(themeManager.theme.primary)
                .clipShape(Circle())
                .shadow(color: themeManager.theme.primary.opacity(0.5), radius: 8, x: 0, y: 4)
        }
        .accessibilityLabel(Text("AI Assistant", bundle: bundle))
    }
}
