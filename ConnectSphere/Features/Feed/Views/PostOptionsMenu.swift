import SwiftUI

/// A post's ⋯ menu, pin/unpin (community staff), edit/delete (your own
/// post), hide/report (anyone else's). Together with the sheet, alerts and
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
    /// Called once the post is hidden. The detail screen leaves; the feed
    /// keeps the collapsed card so Undo can bring it back in place.
    var onPostHidden: (() -> Void)? = nil
    /// In a toolbar the bar's Liquid Glass is the only background, so the
    /// glyph sits bare at the toolbar's own size.
    var inToolbar = false

    @State private var showDeleteAlert = false
    @State private var showEditSheet = false
    @State private var showEditListing = false
    @State private var showReport = false
    /// The official account warns or bans instead of reporting.
    @State private var showModerate = false
    @State private var showEditHistory = false

    var body: some View {
        menu
            .sheet(isPresented: $showEditSheet) {
                CreatePostView(editingPost: post, onPostUpdated: { updatedPost in
                    onPostUpdated?(updatedPost)
                })
                .environment(appState)
                .environment(themeManager)
            }
            .sheet(isPresented: $showEditListing) {
                // A listing post is bound to one item: its edits go through the listing.
                if let listing = post.listingData {
                    EditListingSheet(listing: listing, mode: post.mode, description: post.content) { fields in
                        let viewModel = ListingViewModel(post: post)
                        guard await viewModel.save(fields, token: appState.authToken ?? "") else { return false }
                        onPostUpdated?(viewModel.post)
                        return true
                    }
                    .environment(appState)
                    .environment(themeManager)
                }
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
            .sheet(isPresented: $showEditHistory) {
                EditHistoryView(subject: .post(id: post.id))
                    .environment(themeManager)
            }
            .sheet(isPresented: $showModerate) {
                AdminBanSheet(target: ModerationTarget(type: "post", id: post.id, userId: post.author.id,
                                                       userName: post.author.name, mode: post.mode.rawValue))
                    .environment(themeManager)
            }
            .sheet(isPresented: $showReport) {
                // Reporting doesn't hide the post: it stays where it is until a
                // moderator decides (the reporter can still Hide it themselves).
                ReportSheet(subject: .content(.post, id: post.id),
                            blockUser: (post.author.id, post.author.name))
                .environment(themeManager)
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

            // Anyone who can see an edited post can see what it said before.
            if post.editedAt != nil {
                Button { showEditHistory = true } label: {
                    Label(bundle.loc("View edit history"), systemImage: "clock.arrow.circlepath")
                }
            }

            if post.author.id == appState.currentUser?.id {
                if post.postType == .listing {
                    Button { showEditListing = true } label: {
                        Label(bundle.loc("Edit listing"), systemImage: "pencil")
                    }
                } else {
                    Button { showEditSheet = true } label: {
                        Label(bundle.loc("Edit post"), systemImage: "pencil")
                    }
                }
                Button(role: .destructive) {
                    // Delay so the menu finishes dismissing before the alert appears (SwiftUI timing bug)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showDeleteAlert = true
                    }
                } label: {
                    Label(bundle.loc("Delete post"), systemImage: "trash")
                }
            } else if appState.currentUser?.isOfficial ?? false {
                // The admin doesn't tune its feed or report: it warns or bans.
                if !post.author.isOfficial {
                    Button(role: .destructive) { showModerate = true } label: {
                        Label(bundle.loc("Warn or ban"), systemImage: "hand.raised.slash")
                    }
                }
            } else {
                // Teach the For you feed: more or less like this (and from this person).
                Button {
                    Task { await actions.showMoreLikeThis(postId: post.id) }
                    let id = post.id
                    toastPresenter.show(message: bundle.loc("You'll see more posts like this")) {
                        Task { await actions.undoFeedback(postId: id) }
                    }
                } label: {
                    Label(bundle.loc("Show more like this"), systemImage: "hand.thumbsup")
                }
                Button {
                    Task { await actions.notInterested(postId: post.id) }
                    onPostHidden?()
                } label: {
                    Label(bundle.loc("Not interested"), systemImage: "hand.thumbsdown")
                }
                Button {
                    // The feed keeps a "Hidden, Undo" card where the post was.
                    Task { await actions.hide(postId: post.id) }
                    onPostHidden?()
                } label: {
                    Label(bundle.loc("Hide post"), systemImage: "eye.slash")
                }
                if !post.author.isOfficial {
                    Button { showReport = true } label: {
                        Label(bundle.loc("Report post"), systemImage: "flag")
                    }
                }
            }
        } label: {
            if inToolbar {
                Image(systemName: "ellipsis")
                    .scaledFont(15, .medium)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            } else {
                Image(systemName: "ellipsis")
                    .scaledFont(18)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityLabel(Text(bundle.loc("More")))
    }
}
