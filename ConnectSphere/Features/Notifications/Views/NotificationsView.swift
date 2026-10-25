import SwiftUI

// MARK: - Navigation

/// Where a tapped notification goes. Built from the backend's `destination`
/// object rather than re-deriving it from `type`, so adding a notification type
/// doesn't require a client change to route it.
enum NotificationDestination: Identifiable, Hashable {
    case post(id: String, commentId: String?)
    case profile(userId: String)
    case conversation(ChatRoute)
    case conversationList
    case community(id: String)
    case job(id: String)
    case jobApplicants(jobId: String)

    var id: String {
        switch self {
        case .post(let id, let commentId):  return "post:\(id):\(commentId ?? "")"
        case .profile(let userId):          return "profile:\(userId)"
        case .conversation(let route):      return "chat:\(route.conversationId)"
        case .conversationList:             return "chats"
        case .community(let id):            return "community:\(id)"
        case .job(let id):                  return "job:\(id)"
        case .jobApplicants(let id):        return "applicants:\(id)"
        }
    }

    /// Resolve a notification to its destination, or nil when it doesn't
    /// navigate (mode_mismatch is answered inline; an unknown type is inert).
    static func resolve(_ notif: UserNotificationDTO) -> NotificationDestination? {
        guard let dest = notif.destination else { return nil }

        switch dest.kind {
        case "post":
            guard let postId = dest.postId else { return nil }
            return .post(id: postId, commentId: dest.commentId)

        case "profile":
            guard let userId = dest.userId else { return nil }
            return .profile(userId: userId)

        case "conversation":
            guard let conversationId = dest.conversationId,
                  let peer = chatPeer(from: notif.payload) else { return nil }
            return .conversation(ChatRoute(conversationId: conversationId, peer: peer, location: nil))

        case "conversations":
            return .conversationList

        case "communityPost":
            // The post is the more specific target when the row carries one.
            if let postId = dest.postId { return .post(id: postId, commentId: nil) }
            guard let communityId = dest.communityId else { return nil }
            return .community(id: communityId)

        case "community", "communityJoinRequests", "communityReports":
            guard let communityId = dest.communityId else { return nil }
            return .community(id: communityId)

        case "job":
            guard let jobId = dest.jobId else { return nil }
            return .job(id: jobId)

        case "jobApplicants":
            guard let jobId = dest.jobId else { return nil }
            return .jobApplicants(jobId: jobId)

        default:
            return nil
        }
    }

    /// Build the chat peer straight from the notification payload — the
    /// conversation card the backend embeds means no extra lookup is needed.
    private static func chatPeer(from payload: UserNotificationPayloadDTO) -> ChatPeer? {
        if payload.isGroup == true {
            return .group(
                name: payload.groupName ?? "",
                avatarUrl: payload.groupAvatarUrl,
                avatarColor: payload.groupAvatarColor,
                memberCount: payload.memberCount ?? 0
            )
        }
        guard let peerId = payload.peerUserId ?? payload.fromUserId else { return nil }
        return .direct(
            otherUserId: peerId,
            name: payload.peerDisplayName ?? payload.fromDisplayName ?? "",
            avatarColor: payload.peerAvatarColor ?? payload.fromAvatarColor ?? "#1877F2",
            avatarUrl: payload.peerAvatarUrl ?? payload.fromAvatarUrl
        )
    }
}

// MARK: - NotificationsView

struct NotificationsView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var viewModel = NotificationsViewModel()
    @State private var destination: NotificationDestination?

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterPicker

                List {
                    // One time-ordered list, split only by day range. (An older
                    // version split rows into hardcoded type buckets, which
                    // silently dropped any type not named in one of them.)
                    ForEach(viewModel.sections) { section in
                        Section {
                            ForEach(section.groups) { group in
                                row(for: group)
                                    .listRowBackground(
                                        group.isRead
                                            ? AppColors.surface(colorScheme)
                                            : unreadTint(for: group)
                                    )
                                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        Button {
                                            Task { await viewModel.toggleRead(group: group, token: token, appState: appState) }
                                        } label: {
                                            Label(
                                                group.isRead ? bundle.loc("Mark unread") : bundle.loc("Mark read"),
                                                systemImage: group.isRead ? "envelope.badge" : "envelope.open"
                                            )
                                        }
                                        .tint(themeManager.theme.primary)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            Task { await viewModel.delete(group: group, token: token, appState: appState) }
                                        } label: {
                                            Label(bundle.loc("Delete"), systemImage: "trash")
                                        }
                                    }
                                    .task {
                                        await viewModel.loadMoreIfNeeded(currentGroup: group, token: token)
                                    }
                            }
                        } header: {
                            Text(bundle.loc(section.bucket.titleKey))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .textCase(nil)
                        }
                    }

                    if viewModel.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView().padding(.vertical, 8)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    if viewModel.isEmpty { emptyState }
                }
                // Rounded section cards like the rest of the app, inset 8 pt
                // like the post cards; still a List so swipe actions stay native.
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, AppSpacing.sm, for: .scrollContent)
                .listSectionSpacing(AppSpacing.md)
                .refreshable { await viewModel.load(token: token, appState: appState) }
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Notifications"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Read all")) {
                        Task { await viewModel.markAllRead(token: token, appState: appState) }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(themeManager.theme.primary)
                    .disabled(viewModel.unreadCount == 0)
                }
            }
            .navigationDestination(item: $destination) { destination in
                view(for: destination)
            }
            .task {
                await viewModel.load(token: token, appState: appState)
                viewModel.startListening(token: token, appState: appState)
            }
            .onDisappear { viewModel.stopListening() }
        }
    }

    // MARK: - Pieces

    private var filterPicker: some View {
        Picker("", selection: Binding(
            get: { viewModel.filter },
            set: { newValue in
                Task { await viewModel.setFilter(newValue, token: token, appState: appState) }
            }
        )) {
            Text("All", bundle: bundle).tag(NotificationFilter.all)
            Text("Unread", bundle: bundle).tag(NotificationFilter.unread)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func row(for group: NotificationGroup) -> some View {
        if group.representative.type == "mode_mismatch" {
            ModeMismatchCard(notif: group.representative) { action in
                await viewModel.resolve(
                    notification: group.representative,
                    action: action, token: token, appState: appState
                )
            }
        } else {
            Button {
                open(group)
            } label: {
                ActorNotifRow(group: group)
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 40))
                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
            Text(
                viewModel.filter == .unread ? "Nothing unread" : "No notifications yet",
                bundle: bundle
            )
            .font(.system(size: 15))
            .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func unreadTint(for group: NotificationGroup) -> Color {
        group.representative.type == "mode_mismatch"
            ? AppColors.warning(colorScheme).opacity(0.06)
            : themeManager.theme.primary.opacity(0.06)
    }

    @ViewBuilder
    private func view(for destination: NotificationDestination) -> some View {
        switch destination {
        case .post(let id, let commentId):
            PostDetailView(postId: id, scrollToCommentId: commentId)
        case .profile(let userId):
            UserProfileView(userId: userId)
        case .conversation(let route):
            ChatView(
                conversationId: route.conversationId,
                peer: route.peer,
                otherUserLocation: route.location,
                currentUserId: appState.currentUser?.id ?? "",
                token: token
            )
        case .conversationList:
            ConversationListView()
        case .community(let id):
            CommunityDetailView(
                communityId: id,
                token: token,
                currentUserId: appState.currentUser?.id ?? ""
            )
        case .job(let id):
            JobDetailView(jobId: id) { _ in }
        case .jobApplicants(let jobId):
            ApplicantsView(jobId: jobId)
        }
    }

    /// Marks the whole group read, then navigates once.
    private func open(_ group: NotificationGroup) {
        Task { await viewModel.markRead(group: group, token: token, appState: appState) }
        if let target = NotificationDestination.resolve(group.representative) {
            destination = target
        }
    }
}

// MARK: - ActorNotifRow

/// Shared row for every "someone did something" notification, across all three
/// categories. A type without explicit wording falls back to a generic line
/// rather than disappearing from the list.
struct ActorNotifRow: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    let group: NotificationGroup

    private var notif: UserNotificationDTO { group.representative }

    private var senderName: String {
        notif.payload.fromDisplayName ?? bundle.loc("Someone")
    }

    /// "Anna", or "Anna and 2 others" once a group has several distinct actors.
    private var actorLabel: String {
        guard group.otherActorCount > 0 else { return senderName }
        return String(format: bundle.loc("%@ and %d others"), senderName, group.otherActorCount)
    }

    private var communityLabel: String {
        notif.communityName ?? notif.payload.communityName ?? bundle.loc("a community")
    }

    private var message: String {
        switch notif.type {
        // ── Connections ──────────────────────────────────────────────────
        case "connection_request":
            return String(format: bundle.loc("%@ sent you a connection request"), senderName)
        case "connection_accepted":
            return String(format: bundle.loc("%@ accepted your connection request"), senderName)
        case "birthday":
            return String(format: bundle.loc("🎂 It's %@'s birthday today!"), senderName)
        case "skill_endorsed":
            return String(format: bundle.loc("%@ endorsed your %@ skill"), senderName, notif.payload.skill ?? "")
        case "job_application":
            return String(format: bundle.loc("%@ applied to %@"), senderName, notif.payload.jobTitle ?? "")
        case "new_login":
            return String(format: bundle.loc(notif.payload.method == "google"
                    ? "New sign-in to your account with Google on %@. Not you? Change your password."
                    : "New sign-in to your account with your password on %@. Not you? Change your password."),
                          notif.payload.device ?? "")
        case "application_status":
            let job = notif.payload.jobTitle ?? ""
            switch notif.payload.status {
            case "shortlisted": return String(format: bundle.loc("You're on the shortlist for %@"), job)
            case "hired": return String(format: bundle.loc("You got the job: %@"), job)
            case "rejected": return String(format: bundle.loc("Your application for %@ wasn't selected this time"), job)
            default: return String(format: bundle.loc("Your application for %@ was updated"), job)
            }

        // ── Post activity ────────────────────────────────────────────────
        case "post_liked":
            return String(format: bundle.loc("%@ liked your post"), actorLabel)
        case "post_commented":
            if group.otherActorCount == 0, let excerpt = notif.payload.excerpt, !excerpt.isEmpty {
                return String(format: bundle.loc("%@ commented: “%@”"), senderName, excerpt)
            }
            if group.otherActorCount == 0, notif.payload.commentPhoto == true {
                return String(format: bundle.loc("%@ commented with a photo"), senderName)
            }
            return String(format: bundle.loc("%@ commented on your post"), actorLabel)
        case "comment_replied":
            if group.otherActorCount == 0, let excerpt = notif.payload.excerpt, !excerpt.isEmpty {
                return String(format: bundle.loc("%@ replied to your comment: “%@”"), senderName, excerpt)
            }
            if group.otherActorCount == 0, notif.payload.commentPhoto == true {
                return String(format: bundle.loc("%@ replied to your comment with a photo"), senderName)
            }
            return String(format: bundle.loc("%@ replied to your comment"), actorLabel)
        case "comment_liked":
            return String(format: bundle.loc("%@ liked your comment"), actorLabel)
        case "post_shared":
            return String(format: bundle.loc("%@ shared your post"), actorLabel)
        case "scheduled_post_live":
            return bundle.loc("Your scheduled post is live")
        case "post_approved":
            return bundle.loc("Your post was approved and is now live in the community")
        case "post_declined":
            if let reason = notif.payload.reason, !reason.isEmpty {
                return String(format: bundle.loc("Your post wasn't approved: %@"), reason)
            }
            return bundle.loc("Your post wasn't approved by the community's moderators")

        // ── Chat ─────────────────────────────────────────────────────────
        case "message":
            return messageText
        case "meeting_proposed":
            return String(format: bundle.loc("%@ proposed a meeting: %@"),
                          senderName, notif.payload.title ?? "")
        case "meeting_updated":
            if notif.payload.changeKind == "cancelled" {
                return String(format: bundle.loc("%@ cancelled the meeting"), senderName)
            }
            return String(format: bundle.loc("%@ rescheduled the meeting"), senderName)
        case "meeting_rsvp":
            return String(format: bundle.loc("%@ responded to your meeting"), senderName)
        case "meeting_reminder":
            return String(format: bundle.loc("Reminder: %@"), notif.payload.title ?? "")
        case "message_reaction":
            return String(format: bundle.loc("%@ reacted %@ to your message"),
                          senderName, notif.payload.emoji ?? "")
        case "group_added":
            return String(format: bundle.loc("%@ added you to a group chat"), senderName)
        case "group_removed":
            return String(format: bundle.loc("%@ removed you from a group chat"), senderName)

        // ── Community ────────────────────────────────────────────────────
        case "new_post":
            return newPostText
        case "pinned_post":
            return String(format: bundle.loc("A post was pinned in %@"), communityLabel)
        case "join_request":
            return String(format: bundle.loc("%@ wants to join %@"), senderName, communityLabel)
        case "join_approved":
            return String(format: bundle.loc("You were approved to join %@"), communityLabel)
        case "join_rejected":
            return String(format: bundle.loc("Your request to join %@ was declined"), communityLabel)
        case "role_changed":
            return String(format: bundle.loc("Your role in %@ changed"), communityLabel)
        case "new_report":
            return String(format: bundle.loc("Content in %@ needs review"), communityLabel)
        case "content_removed":
            return String(format: bundle.loc("Your post in %@ was removed by a moderator"), communityLabel)

        default:
            // Unknown type — show something rather than nothing.
            return senderName
        }
    }

    /// "Anna · 3 new messages", using the server's collapse count.
    private var messageText: String {
        let count = notif.eventCount
        if count > 1 {
            return String(format: bundle.loc("%@ · %d new messages"), chatTitle, count)
        }
        if let preview = notif.payload.preview, !preview.isEmpty {
            return "\(chatTitle): \(preview)"
        }
        return String(format: bundle.loc("%@ sent you a message"), chatTitle)
    }

    private var chatTitle: String {
        if notif.payload.isGroup == true {
            return notif.payload.groupName ?? bundle.loc("Group chat")
        }
        return notif.payload.peerDisplayName ?? senderName
    }

    /// "Linh posted in Pokémon TCG VN" — each post is its own notification.
    private var newPostText: String {
        String(format: bundle.loc("%@ posted in %@"), senderName, communityLabel)
    }

    private var badgeIcon: String {
        switch notif.type {
        case "connection_request":  return "person.badge.plus"
        case "connection_accepted": return "person.badge.shield.checkmark"
        case "birthday":            return "gift.fill"
        case "skill_endorsed":      return "hand.thumbsup.circle.fill"
        case "job_application":     return "doc.text.fill"
        case "new_login":           return "lock.shield.fill"
        case "application_status":  return "briefcase.fill"
        case "post_liked":          return "hand.thumbsup.fill"
        case "comment_liked":       return "hand.thumbsup.fill"
        case "post_commented":      return "bubble.left.fill"
        case "comment_replied":     return "arrowshape.turn.up.left.fill"
        case "post_shared":         return "arrowshape.turn.up.right.fill"
        case "scheduled_post_live": return "clock.fill"
        case "post_approved":       return "checkmark.seal.fill"
        case "post_declined":       return "xmark.octagon.fill"
        case "message":             return "message.fill"
        case "message_reaction":    return "face.smiling.fill"
        case "meeting_proposed",
             "meeting_updated",
             "meeting_rsvp",
             "meeting_reminder":    return "calendar"
        case "group_added":         return "person.3.fill"
        case "group_removed":       return "person.badge.minus"
        case "new_post":            return "doc.text.fill"
        case "pinned_post":         return "pin.fill"
        case "join_request":        return "person.badge.clock"
        case "join_approved":       return "checkmark.seal.fill"
        case "join_rejected":       return "xmark.seal.fill"
        case "role_changed":        return "shield.lefthalf.filled"
        case "new_report":          return "exclamationmark.triangle.fill"
        case "content_removed":     return "trash.fill"
        default:                    return "bell.fill"
        }
    }

    /// Avatar tile for the row. A community or group row shows its own
    /// identity rather than a person's face.
    private var avatarName: String {
        switch notif.type {
        case "message", "meeting_proposed", "meeting_updated",
             "meeting_rsvp", "meeting_reminder", "group_added", "group_removed":
            return chatTitle
        case "new_post", "pinned_post", "join_approved", "join_rejected",
             "role_changed", "new_report", "content_removed":
            return communityLabel
        default:
            return senderName
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                senderAvatar
                ZStack {
                    Circle().fill(themeManager.theme.primary).frame(width: 20, height: 20)
                    Image(systemName: badgeIcon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                }
                .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(notif.sortDate.timeAgoString)
                    .font(.system(size: 13))
                    .foregroundColor(group.isRead
                                     ? AppColors.textSecondary(colorScheme)
                                     : themeManager.theme.primary)
            }

            Spacer()

            if !group.isRead {
                Circle().fill(themeManager.theme.primary).frame(width: 10, height: 10)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var senderAvatar: some View {
        if let url = APIConfig.mediaURL(avatarUrl) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initialCircle
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
        } else {
            initialCircle
        }
    }

    private var avatarUrl: String? {
        if notif.payload.isGroup == true { return notif.payload.groupAvatarUrl }
        return notif.payload.peerAvatarUrl ?? notif.payload.fromAvatarUrl
    }

    private var avatarColor: String {
        if notif.payload.isGroup == true { return notif.payload.groupAvatarColor ?? "#1877F2" }
        return notif.payload.peerAvatarColor ?? notif.payload.fromAvatarColor ?? "#1877F2"
    }

    private var initialCircle: some View {
        ZStack {
            Circle()
                .fill(Color(hex: avatarColor))
                .frame(width: 52, height: 52)
            Text(String(avatarName.prefix(1)).uppercased())
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - ModeMismatchCard

struct ModeMismatchCard: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    let notif: UserNotificationDTO
    let onAction: (String) async -> Void

    @State private var showKeepConfirm   = false
    @State private var showSwitchConfirm = false
    @State private var isResolving = false

    private var suggestedLabel: String {
        notif.payload.suggestedMode == "hobby" ? bundle.loc("Hobby") : bundle.loc("Work")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.warning(colorScheme))
                Text("AI suggestion", bundle: bundle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.warning(colorScheme))
                Spacer()
                Text(notif.createdAt.timeAgoString)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                if !notif.isRead {
                    Circle().fill(AppColors.warning(colorScheme)).frame(width: 8, height: 8)
                }
            }

            // Reason text
            Text(notif.payload.reason ?? String(format: bundle.loc("This post may fit %@ mode better"), suggestedLabel))
                .font(.system(size: 15))
                .foregroundColor(AppColors.textPrimary(colorScheme))

            // Action buttons (hidden after resolved)
            if notif.resolvedAt == nil && !isResolving {
                HStack(spacing: 10) {
                    Button(bundle.loc("Keep")) {
                        showKeepConfirm = true
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                    )
                    .confirmationDialog(
                        bundle.loc("Keep the current mode?"),
                        isPresented: $showKeepConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(bundle.loc("Keep"), role: .destructive) {
                            Task {
                                isResolving = true
                                await onAction("keep")
                                isResolving = false
                            }
                        }
                        Button(bundle.loc("Cancel"), role: .cancel) {}
                    } message: {
                        Text("The post will stay in the current mode.", bundle: bundle)
                    }

                    Button(String(format: bundle.loc("Switch to %@"), suggestedLabel)) {
                        showSwitchConfirm = true
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(AppColors.warning(colorScheme)))
                    .confirmationDialog(
                        String(format: bundle.loc("Switch to %@ mode?"), suggestedLabel),
                        isPresented: $showSwitchConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(String(format: bundle.loc("Switch to %@"), suggestedLabel)) {
                            Task {
                                isResolving = true
                                await onAction("switch")
                                isResolving = false
                            }
                        }
                        Button(bundle.loc("Cancel"), role: .cancel) {}
                    } message: {
                        Text(String(format: bundle.loc("The post will be moved to %@ mode."), suggestedLabel))
                    }
                }
            } else if isResolving {
                ProgressView().scaleEffect(0.8)
            } else {
                Text("Resolved", bundle: bundle)
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        .padding(.vertical, 8)
    }
}
