import SwiftUI

/// A community's card where it was shared (a feed post, a chat). Tapping
/// opens the community.
struct SharedCommunityCard: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    let community: SharedCommunityRef

    var body: some View {
        NavigationLink {
            CommunityDetailView(communityId: community.id, token: appState.authToken ?? "",
                                currentUserId: appState.currentUser?.id ?? "")
                .environment(appState).environment(themeManager)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                CommunityCover(community: placeholder, emojiSize: 36)
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 3) {
                    Text(community.name)
                        .scaledFont(15, .semibold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        Image(systemName: community.privacy == "private" ? "lock.fill" : "globe")
                        Text(community.privacy == "private" ? bundle.loc("Private") : bundle.loc("Public"))
                        Text("·")
                        Text(String(format: bundle.loc("%lld members"), community.memberCount))
                    }
                    .scaledFont(12)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppColors.elevated(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.borderSubtle(colorScheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Just what the cover needs.
    private var placeholder: Community {
        Community(id: community.id, name: community.name, description: nil, type: .fandom,
                  privacy: community.privacy == "private" ? .private : .public, iconEmoji: community.iconEmoji,
                  avatarUrl: nil, coverUrl: community.coverUrl, coverColor: community.coverColor,
                  memberCount: community.memberCount, postCount: 0, isMember: false, createdAt: Date())
    }
}

/// A community shared into a chat: loaded as the viewer, so a private one
/// they can't see shows as unavailable.
struct ChatCommunityCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    let communityId: String
    @State private var viewModel = ChatCommunityCardViewModel()

    var body: some View {
        Group {
            if let ref = viewModel.community {
                SharedCommunityCard(community: ref)
            } else if viewModel.unavailable {
                Text("This community isn't available", bundle: bundle)
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(12)
                    .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView().frame(width: 220, height: 80)
            }
        }
        .frame(maxWidth: 260)
        .task { await viewModel.load(communityId: communityId, token: appState.authToken ?? "") }
    }
}
