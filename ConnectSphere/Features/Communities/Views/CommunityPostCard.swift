import SwiftUI

struct CommunityPostCard: View {
    @Environment(\.colorScheme) var colorScheme
    var post: CommunityPost
    let currentUserId: String
    let communityId: String
    let token: String
    let accentColor: Color
    let currentUserRole: MemberRole?
    let onDelete: (() -> Void)?
    let onPin: (() -> Void)?
    let onUnpin: (() -> Void)?

    @State private var showReportSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Pinned label banner
            if post.isPinned {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                    Text("Pinned")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(accentColor)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 2)
            }

            // Header: avatar + author + time + action menu
            HStack(alignment: .top, spacing: 10) {
                authorAvatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.author.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    Text(post.createdAt.timeAgoString)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
                Spacer()
                actionMenu
            }
            .padding(.horizontal, 14)
            .padding(.top, post.isPinned ? 4 : 12)

            // Community tag (shown outside community context)
            if let community = post.community {
                HStack(spacing: 4) {
                    Text(community.iconEmoji).font(.system(size: 12))
                    Text(community.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            // Post content text
            Text(post.content)
                .font(.system(size: 15))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, post.postType == .text ? 14 : 8)

            // Poll or Event inline body
            switch post.postType {
            case .poll:
                if let pollData = post.pollData {
                    PollPostCard(
                        vm: PollViewModel(postId: post.id, pollData: pollData, token: token),
                        accentColor: accentColor
                    )
                }
            case .event:
                if let eventData = post.eventData {
                    EventPostCard(
                        vm: EventViewModel(eventData: eventData, token: token),
                        accentColor: accentColor
                    )
                }
            case .text:
                EmptyView()
            }

            Divider()
                .background(AppColors.borderSubtle(colorScheme))

            // Footer: like + comment counts
            HStack(spacing: 20) {
                Label("\(post.likeCount)", systemImage: "heart")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                Label("\(post.commentCount)", systemImage: "bubble.right")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 4, x: 0, y: 2)
        .sheet(isPresented: $showReportSheet) {
            ReportSheet(
                targetType:  "post",
                targetId:    post.id,
                communityId: communityId,
                token:       token
            )
        }
    }

    // MARK: - Subviews

    private var authorAvatar: some View {
        ZStack {
            Circle().fill(Color(hex: post.author.avatarColor))
            Text(String(post.author.displayName.prefix(1)))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 36, height: 36)
    }

    @ViewBuilder
    private var actionMenu: some View {
        let isAuthor = post.author.id == currentUserId
        let isStaff  = currentUserRole == .admin || currentUserRole == .moderator

        // Always show menu — either for owner/staff actions or for report option
        Menu {
            // Pin / Unpin (admin & mod only)
            if isStaff {
                if post.isPinned {
                    Button { onUnpin?() } label: {
                        Label("Unpin post", systemImage: "pin.slash")
                    }
                } else {
                    Button { onPin?() } label: {
                        Label("Pin post", systemImage: "pin")
                    }
                }
                Divider()
            }

            // Delete (author, admin, mod)
            if let onDelete, (isAuthor || isStaff) {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete post", systemImage: "trash")
                }
                Divider()
            }

            // Report (non-authors only; reporter identity is hidden server-side)
            if !isAuthor {
                Button {
                    showReportSheet = true
                } label: {
                    Label("Report post", systemImage: "flag")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .frame(width: 32, height: 32)
        }
    }
}
