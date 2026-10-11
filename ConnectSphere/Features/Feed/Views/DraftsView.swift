import SwiftUI

/// One draft or scheduled post in a list: what kind of post, its first line,
/// where it'll go (Hobby / Work / a community) and when it was saved.
struct DraftRow: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager

    let post: Post

    private var icon: String {
        switch post.postType {
        case .poll: return "chart.bar.fill"
        case .event: return "calendar"
        case .job: return "briefcase.fill"
        case .text: return post.imageUrls.isEmpty ? (post.linkUrl == nil ? "text.alignleft" : "link") : "photo"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(themeManager.theme.primary)
                .frame(width: 36, height: 36)
                .background(themeManager.theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(post.draftSnippet)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(place)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(AppColors.elevated(colorScheme), in: Capsule())
                    Text(when)
                        .font(.system(size: 12))
                }
                .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var place: String {
        if let community = post.community { return "\(community.iconEmoji) \(community.name)" }
        return bundle.loc(post.mode == .work ? "Work" : "Hobby")
    }

    private var when: String {
        String(format: bundle.loc("Saved %@"), post.timestamp.timeAgoString)
    }
}

/// The composer's "Drafts" button: pick one to continue.
struct DraftPickerSheet: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let drafts: [Post]
    let onPick: (Post) -> Void

    var body: some View {
        NavigationStack {
            List(drafts) { draft in
                Button { onPick(draft); dismiss() } label: { DraftRow(post: draft) }
                    .buttonStyle(.plain)
                    .listRowBackground(AppColors.surface(colorScheme))
            }
            .listStyle(.plain)
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Drafts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Cancel")) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Settings → Drafts: every draft, in both modes and every community. Tap to
/// keep writing, swipe to delete.
struct DraftsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel = DraftsViewModel()
    @State private var opening: DraftsViewModel.Opened?
    @State private var pendingDelete: Post?

    var body: some View {
        Group {
            if viewModel.hasLoaded && viewModel.drafts.isEmpty {
                EmptyStateView(systemImage: "doc.text",
                               title: bundle.loc("No drafts"),
                               message: bundle.loc("When you're writing a post, tap Cancel and choose Save draft to keep it here."))
            } else {
                List {
                    ForEach(viewModel.drafts) { draft in
                        Button { Task { opening = await viewModel.open(draft) } } label: { DraftRow(post: draft) }
                            .buttonStyle(.plain)
                            .listRowBackground(AppColors.surface(colorScheme))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = draft } label: {
                                    Label(bundle.loc("Delete"), systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Drafts"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .sheet(item: $opening) { opened in
            switch opened.place {
            case .feed:
                CreatePostView(draft: opened.draft)
                    .environment(appState)
                    .environment(themeManager)
            case .community(let community):
                CommunityCreatePostView(community: community, draft: opened.draft, onPostCreated: { _ in })
                    .environment(appState)
                    .environment(themeManager)
            }
        }
        .alert(bundle.loc("Delete this draft?"), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { draft in
            Button(bundle.loc("Delete"), role: .destructive) { Task { await viewModel.delete(draft) } }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: { _ in
            Text("It can't be recovered.", bundle: bundle)
        }
        .alert(bundle.loc("Error"), isPresented: Binding(
            get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        } message: {
            Text(viewModel.error ?? "")
        }
    }
}
