import SwiftUI

/// "..." › Manage your content.
struct ManageCommunityContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager

    @State private var viewModel: ManageCommunityContentViewModel
    @State private var detailRoute: PostRoute?

    private let communityId: String

    init(communityId: String) {
        self.communityId = communityId
        _viewModel = State(initialValue: ManageCommunityContentViewModel(communityId: communityId))
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.sm) {
                Picker("", selection: $viewModel.kind) {
                    Text(String(format: bundle.loc("Posts (%lld)"), viewModel.count(of: .all))).tag(MyCommunityContent.Kind.posts)
                    Text(String(format: bundle.loc("Comments (%lld)"), viewModel.counts.comments)).tag(MyCommunityContent.Kind.comments)
                }
                .pickerStyle(.segmented)

                if viewModel.kind == .posts { statusChips }

                if viewModel.kind == .posts {
                    if viewModel.posts.isEmpty && !viewModel.isLoading { empty }
                    ForEach(viewModel.posts) { post in
                        VStack(alignment: .leading, spacing: 6) {
                            statusBadge(post)
                            PostCard(post: post,
                                     onPostDeleted: { viewModel.removePost(id: post.id) },
                                     onOpenDetail: { focus in detailRoute = PostRoute(postId: post.id, focusComposer: focus) },
                                 insideCommunityId: communityId)
                                .cardStyle()
                        }
                        .task { if post.id == viewModel.posts.last?.id { await viewModel.loadMore(token: token) } }
                    }
                } else {
                    if viewModel.comments.isEmpty && !viewModel.isLoading { empty }
                    ForEach(viewModel.comments) { comment in
                        Button { detailRoute = PostRoute(postId: comment.postId, focusComposer: false) } label: {
                            commentRow(comment)
                        }
                        .buttonStyle(.plain)
                        .task { if comment.id == viewModel.comments.last?.id { await viewModel.loadMore(token: token) } }
                    }
                }
                if viewModel.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
            }
            .padding(AppSpacing.sm)
        }
        .appBackground()
        .navigationTitle(bundle.loc("Manage your content"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker(bundle.loc("Sort"), selection: $viewModel.newestFirst) {
                        Text("Newest first", bundle: bundle).tag(true)
                        Text("Oldest first", bundle: bundle).tag(false)
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel(Text("Sort", bundle: bundle))
            }
        }
        .task { await viewModel.reload(token: token) }
        .onChange(of: viewModel.kind) { _, _ in Task { await viewModel.reload(token: token) } }
        .onChange(of: viewModel.status) { _, _ in Task { await viewModel.reload(token: token) } }
        .onChange(of: viewModel.newestFirst) { _, _ in Task { await viewModel.reload(token: token) } }
        .navigationDestination(isPresented: Binding(get: { detailRoute != nil }, set: { if !$0 { detailRoute = nil } })) {
            if let route = detailRoute { PostDetailView(postId: route.postId, focusComposer: route.focusComposer) }
        }
        .alert(bundle.loc("Error"), isPresented: Binding(get: { viewModel.errorMessage != nil },
                                                          set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(bundle.loc("OK")) {}
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    /// All / Published / Pending / Declined, each with its count. Pending is
    /// always there, even in a community that doesn't hold posts.
    private var statusChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MyCommunityContent.Status.allCases, id: \.self) { status in
                    let selected = viewModel.status == status
                    Button { viewModel.status = status } label: {
                        Text("\(bundle.loc(label(status))) \(viewModel.count(of: status))")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(selected ? .white : AppColors.textPrimary(colorScheme))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(selected ? themeManager.theme.primary : AppColors.elevated(colorScheme), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func label(_ status: MyCommunityContent.Status) -> String {
        switch status {
        case .all: "All"
        case .published: "Published"
        case .pending: "Pending"
        case .declined: "Declined"
        }
    }

    @ViewBuilder
    private func statusBadge(_ post: Post) -> some View {
        switch post.publishStatus {
        case "pending":
            Label(bundle.loc("Waiting for approval"), systemImage: "hourglass")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.orange)
        case "declined":
            VStack(alignment: .leading, spacing: 2) {
                Label(bundle.loc("Declined"), systemImage: "xmark.octagon")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(AppColors.danger(colorScheme))
                if let reason = post.declineReason {
                    Text(String(format: bundle.loc("Reason: %@"), reason))
                        .font(.system(size: 12)).foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
        default:
            Label(bundle.loc("Published"), systemImage: "checkmark.circle")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.green)
        }
    }

    private func commentRow(_ comment: MyCommunityContent.Comment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(comment.content)
                .font(.system(size: 15))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text(String(format: bundle.loc("On: %@"), comment.postExcerpt.isEmpty ? bundle.loc("a post") : comment.postExcerpt))
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .lineLimit(1)
            Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var empty: some View {
        Text(viewModel.kind == .posts ? bundle.loc("Nothing here yet") : bundle.loc("You haven't commented here yet"))
            .font(.system(size: 14))
            .foregroundColor(AppColors.textTertiary(colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }
}
