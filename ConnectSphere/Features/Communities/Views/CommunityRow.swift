import SwiftUI

/// One community in a list: its cover as a rounded square on the left, then
/// the name (room for long names), member count and about; Join on the right.
struct CommunityRow: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @Environment(ThemeManager.self) var themeManager
    @Environment(AppState.self) private var appState
    let community: Community
    /// Join or leave; nil hides the button.
    var onToggle: (() -> Void)?
    /// Leaving is the one destructive tap on the pill, so it asks first.
    @State private var confirmLeave = false
    @State private var adminMustHandOver = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CommunityCover(community: community)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if community.isPinned {
                        Image(systemName: "pin.fill")
                            .scaledFont(11)
                            .foregroundColor(themeManager.theme.primary)
                            .accessibilityLabel(Text("Pinned", bundle: bundle))
                    }
                    Text(community.name)
                        .scaledFont(15, .semibold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(format: bundle.loc("%lld members"), community.memberCount))
                    .scaledFont(12)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                if let about = community.description, !about.isEmpty {
                    Text(MarkdownFormatter.plain(about))
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The official account visits communities but never joins one.
            if let onToggle, !(appState.currentUser?.isOfficial ?? false) { joinButton(onToggle) }
        }
        .padding(12)
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 4, x: 0, y: 2)
    }

    private func joinButton(_ action: @escaping () -> Void) -> some View {
        Button {
            if community.role == .admin { adminMustHandOver = true }
            else if community.isMember { confirmLeave = true } else { action() }
        } label: {
            Text(community.isMember ? bundle.loc("Joined") : bundle.loc("Join"))
                .scaledFont(13, .semibold)
                .foregroundColor(community.isMember ? AppColors.textSecondary(colorScheme) : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(community.isMember ? AppColors.elevated(colorScheme) : themeManager.theme.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabledWhenRestricted(!community.isMember)
        .confirmationDialog(bundle.loc("Leave this community?"), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(bundle.loc("Leave community"), role: .destructive, action: action)
        } message: {
            Text("You'll stop seeing its posts. You can join again later.", bundle: bundle)
        }
        .alert(bundle.loc("Make someone else admin first"), isPresented: $adminMustHandOver) {
            Button(bundle.loc("OK")) {}
        } message: {
            Text("Open the community, go to Members and choose Make admin on someone. Then you can leave.", bundle: bundle)
        }
    }
}
