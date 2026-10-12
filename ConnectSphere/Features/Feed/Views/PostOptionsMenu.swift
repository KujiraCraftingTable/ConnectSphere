import SwiftUI

/// A post's ⋯ menu — pin/unpin (community staff), edit/delete (your own
/// post), hide/report (anyone else's) — together with the sheet, alerts and
/// dialog those open. Lives in `PostCard`'s header on the feed, and in the
/// top bar of `PostDetailView`, which shows the post without its header.
struct PostOptionsMenu: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(UndoToastPresenter.self) private var toastPresenter
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let post: Post
    /// Shared with the card the menu belongs to, so hiding from the feed
    /// collapses that card (`actions.isHidden`).
    let actions: PostActionsViewModel
    var onPin: (() -> Void)? = nil
    var onUnpin: (() -> Void)? = nil
    var onPostDeleted: (() -> Void)? = nil
    var onPostUpdated: ((Post) -> Void)? = nil
    /// Called once the post is hidden — the detail screen leaves; the feed
    /// keeps the collapsed card so Undo can bring it back in place.
    var onPostHidden: (() -> Void)? = nil
    /// In a toolbar the bar's Liquid Glass is the only background, so the
    /// glyph sits bare at the toolbar's own size.
    var inToolbar = false

    @State private var showDeleteAlert = false
    @State private var showEditSheet = false
    @State private var showReportDialog = false

    var body: some View {
        menu
            .sheet(isPresented: $showEditSheet) {
                CreatePostView(editingPost: post, onPostUpdated: { updatedPost in
                    onPostUpdated?(updatedPost)
                })
                .environment(appState)
                .environment(themeManager)
            }
            .alert(bundle.loc("Delete post?"), isPresented: $showDeleteAlert) {
                Button(bundle.loc("Delete"), role: .destructive) {
                    Task {
                        guard await actions.delete(post: post) else { return }
                        onPostDeleted?()
                        // Undo within a few seconds; after that it's in Recently Deleted for 30 days.
                        let deletedPostId = post.id
                        toastPresenter.show(message: bundle.loc("Post deleted")) {
                            Task { await actions.restore(postId: deletedPostId) }
                        }
                    }
                }
                Button(bundle.loc("Cancel"), role: .cancel) {}
            } message: {
                Text("This post won't be shown in the app. You can restore it from Recently Deleted within 30 days.", bundle: bundle)
            }
            .confirmationDialog(
                bundle.loc("Why are you reporting this content?"),
                isPresented: $showReportDialog,
                titleVisibility: .visible
            ) {
                ForEach(ReportReason.allCases, id: \.self) { reason in
                    Button(reason.displayName) {
                        Task { await actions.report(postId: post.id, reason: reason) }
                    }
                }
                Button(bundle.loc("Cancel"), role: .cancel) {}
            }
            .alert(actions.reportResultMessage ?? "", isPresented: Binding(
                get: { actions.reportResultMessage != nil },
                set: { if !$0 { actions.reportResultMessage = nil } }
            )) {
                Button(bundle.loc("Done")) {}
            }
            // Delete/hide/restore failures
            .alert(actions.actionErrorMessage ?? "", isPresented: Binding(
                get: { actions.actionErrorMessage != nil },
                set: { if !$0 { actions.actionErrorMessage = nil } }
            )) {
                Button(bundle.loc("OK")) {}
            }
    }

    private var menu: some View {
        Menu {
            if let onPin, !post.isPinned {
                Button {
                    onPin()
                } label: {
                    Label(bundle.loc("Pin post"), systemImage: "pin")
                }
            }
            if let onUnpin, post.isPinned {
                Button {
                    onUnpin()
                } label: {
                    Label(bundle.loc("Unpin post"), systemImage: "pin.slash")
                }
            }

            if post.author.id == appState.currentUser?.id {
                Button { showEditSheet = true } label: {
                    Label(bundle.loc("Edit post"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    // Delay so the menu finishes dismissing before the alert appears (SwiftUI timing bug)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showDeleteAlert = true
                    }
                } label: {
                    Label(bundle.loc("Delete post"), systemImage: "trash")
                }
            } else {
                Button {
                    // Undo un-hides in place: on the feed the post never left the list.
                    Task { await actions.hide(postId: post.id) }
                    let hiddenPostId = post.id
                    toastPresenter.show(message: bundle.loc("Post hidden")) {
                        Task { await actions.unhide(postId: hiddenPostId) }
                    }
                    onPostHidden?()
                } label: {
                    Label(bundle.loc("Hide post"), systemImage: "eye.slash")
                }
                Button(role: .destructive) {
                    showReportDialog = true
                } label: {
                    Label(bundle.loc("Report post"), systemImage: "flag")
                }
            }
        } label: {
            if inToolbar {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityLabel(Text(bundle.loc("More")))
    }
}
