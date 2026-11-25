import SwiftUI

// MARK: - Draft row
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
        case .listing: return "bag.fill"
        case .legit: return "checkmark.seal.fill"
        case .text: return post.imageUrls.isEmpty ? (post.linkUrl == nil ? "text.alignleft" : "link") : "photo"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(15, .semibold)
                .foregroundColor(themeManager.theme.primary)
                .frame(width: 36, height: 36)
                .background(themeManager.theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(post.draftSnippet)
                    .scaledFont(15)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(place)
                        .scaledFont(11, .semibold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(AppColors.elevated(colorScheme), in: Capsule())
                    Text(when)
                        .scaledFont(12)
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
        if post.publishStatus == "scheduled", let at = post.publishAt {
            return String(format: bundle.loc("Goes out %@"),
                          at.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
        }
        return String(format: bundle.loc("Saved %@"), post.timestamp.timeAgoString)
    }
}

// MARK: - Draft picker
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

// MARK: - Drafts list
/// Settings → Drafts: every draft and scheduled post, in both modes and every
/// community. Tap to keep writing; swipe to delete, or, for a scheduled
/// post, to publish it now or move it back to drafts.
struct DraftsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel = DraftsViewModel()
    @State private var opening: DraftsViewModel.Opened?
    /// Sell tapped in a community draft: New listing opens once the composer closes.
    @State private var sellAfterCompose: Community?
    @State private var sellingIn: Community?
    @State private var pendingDelete: Post?
    @State private var showScheduled = false

    private var shown: [Post] { showScheduled ? viewModel.scheduled : viewModel.drafts }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $showScheduled) {
                Text(String(format: bundle.loc("Drafts (%lld)"), viewModel.drafts.count)).tag(false)
                Text(String(format: bundle.loc("Scheduled (%lld)"), viewModel.scheduled.count)).tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppSpacing.md)
            .padding(.top, AppSpacing.sm)

            if viewModel.hasLoaded && shown.isEmpty {
                if showScheduled {
                    EmptyStateView(systemImage: "clock",
                                   title: bundle.loc("Nothing scheduled"),
                                   message: bundle.loc("Tap the clock while writing a post to choose when it goes out."))
                } else {
                    EmptyStateView(systemImage: "doc.text",
                                   title: bundle.loc("No drafts"),
                                   message: bundle.loc("When you're writing a post, tap Cancel and choose Save draft to keep it here."))
                }
                Spacer()
            } else {
                List {
                    ForEach(shown) { draft in
                        Button { Task { opening = await viewModel.open(draft) } } label: { DraftRow(post: draft) }
                            .buttonStyle(.plain)
                            .listRowBackground(AppColors.surface(colorScheme))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = draft } label: {
                                    Label(bundle.loc("Delete"), systemImage: "trash")
                                }
                                if draft.publishStatus == "scheduled" {
                                    Button { Task { await viewModel.unschedule(draft) } } label: {
                                        Label(bundle.loc("Move to drafts"), systemImage: "doc.text")
                                    }
                                    .tint(.gray)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if draft.publishStatus == "scheduled" {
                                    Button { Task { await viewModel.publishNow(draft) } } label: {
                                        Label(bundle.loc("Publish now"), systemImage: "paperplane.fill")
                                    }
                                    .tint(themeManager.theme.primary)
                                }
                            }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Drafts & scheduled"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .sheet(item: $opening, onDismiss: {
            sellingIn = sellAfterCompose
            sellAfterCompose = nil
        }) { opened in
            switch opened.place {
            case .feed:
                CreatePostView(draft: opened.draft)
                    .environment(appState)
                    .environment(themeManager)
            case .community(let community):
                CreatePostView(community: community, draft: opened.draft, onSell: { sellAfterCompose = community })
                    .environment(appState)
                    .environment(themeManager)
            }
        }
        .sheet(item: $sellingIn) { community in
            CreateListingView(mode: .hobby, preselectedCommunityId: community.id) { _ in
                sellingIn = nil
            }
            .environment(appState)
            .environment(themeManager)
        }
        .alert(bundle.loc(pendingDelete?.publishStatus == "scheduled" ? "Delete this scheduled post?" : "Delete this draft?"), isPresented: Binding(
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
