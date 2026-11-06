import SwiftUI

/// Your comments and reactions, in both modes, newest first. Tap one to
/// open the post.
struct ActivityLogView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel = ActivityLogViewModel()
    @State private var opened: ActivityItem?

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        List {
            Section {
                Picker("", selection: $viewModel.tab) {
                    Text("Comments", bundle: bundle).tag(ActivityRepository.Tab.comments)
                    Text("Reactions", bundle: bundle).tag(ActivityRepository.Tab.reactions)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if viewModel.shown.isEmpty {
                Text(viewModel.errorMessage ?? bundle.loc(viewModel.tab == .comments
                        ? "Comments you write show here." : "Posts and comments you like show here."))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.days) { day in
                    Section(day.id.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(bundle.locale))) {
                        ForEach(day.items) { item in
                            Button { opened = item } label: { row(item) }
                                .buttonStyle(.plain)
                                .task { await viewModel.loadMore(after: item, token: token) }
                        }
                    }
                }
                if viewModel.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle(bundle.loc("Activity log"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: viewModel.tab) { await viewModel.load(token: token) }
        .refreshable { await viewModel.load(token: token) }
        .navigationDestination(item: $opened) { item in
            PostDetailView(postId: item.postId, scrollToCommentId: item.commentId)
        }
    }

    private func row(_ item: ActivityItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .comment ? "bubble.left.fill" : "hand.thumbsup.fill")
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(item.kind == .comment ? Color(hex: "#43A047") : themeManager.theme.primary, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(item.headline(loc: bundle.loc))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if let comment = item.commentExcerpt, !comment.isEmpty {
                    Text("“\(comment)”")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(2)
                }
                if !item.postExcerpt.isEmpty {
                    Text(item.postExcerpt)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: item.mode.glyph)
                        Text(bundle.loc(item.mode == .work ? "Work" : "Hobby"))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(AppColors.elevated(colorScheme), in: Capsule())
                    Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
