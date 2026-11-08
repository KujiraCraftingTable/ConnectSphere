import SwiftUI

/// The real stories row: your own story + stories from connections (24h).
/// Tapping a bubble opens StoryViewerView; the + button posts a new story.
struct StoriesRow: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var viewModel = StoriesViewModel()
    @State private var selectedGroup: StoryGroup?
    @State private var showComposer = false

    private var myGroup: StoryGroup? { viewModel.myGroup(currentUserId: appState.currentUser?.id) }
    private var otherGroups: [StoryGroup] { viewModel.otherGroups(currentUserId: appState.currentUser?.id) }
    private var myProfile: UserProfile? { viewModel.myProfile }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                myStoryBubble
                ForEach(otherGroups) { group in
                    Button {
                        selectedGroup = group
                    } label: {
                        storyBubble(group)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .task { await load() }
        .onChange(of: appState.currentMode) { _, _ in
            // Stories are mode-scoped like posts. Reload for the newly
            // selected mode. (Previously this row was only ever shown in
            // Hobby mode, so switching modes tore the whole view down and
            // recreated it; now that it's shown in both, an explicit reload
            // is needed instead.)
            Task { await load() }
        }
        .fullScreenCover(item: $selectedGroup) { group in
            StoryViewerView(group: group) {
                // Reload to update the seen-state ring after closing the viewer
                Task { await load() }
            }
        }
        .fullScreenCover(isPresented: $showComposer) {
            StoryComposerView(mode: appState.currentMode.rawValue) {
                Task { await load() }
            }
        }
    }

    // MARK: - Bubbles

    /// "Your story" bubble: tapping the avatar opens your own story if you
    /// have one, or the composer (same as the "+" badge) if you don't. A
    /// bare avatar with a "+" next to it reads as "tap me to add a story"
    /// just as much as the badge itself does.
    private var myStoryBubble: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    if let mine = myGroup { selectedGroup = mine } else if !appState.isRestricted { showComposer = true }
                } label: {
                    ZStack {
                        // A ring only when there's an actual story to show,
                        // no story at all should look like no story at all,
                        // not a dim/neutral placeholder ring (that previously
                        // used AppColors.borderDefault, a near-transparent
                        // 0.09-0.10 opacity hairline. Barely visible against
                        // a light background, which is exactly what read as
                        // "faded" rather than as an intentional neutral state).
                        if myGroup?.hasUnseen == true {
                            Circle()
                                .stroke(themeManager.theme.primary, lineWidth: 2.5)
                                .frame(width: 68, height: 68)
                        } else if myGroup != nil {
                            Circle()
                                .stroke(AppColors.borderDefault(colorScheme), lineWidth: 2.5)
                                .frame(width: 68, height: 68)
                        }
                        // `myProfile` is a fresh, mode-scoped fetch (see load()),
                        // `appState.currentUser` is a single unscoped cache that
                        // never changes on mode switch, so it's only a same-frame
                        // fallback before the first load() resolves.
                        if let me = myProfile ?? appState.currentUser {
                            AvatarView(user: me, size: 60)
                        }
                    }
                    .frame(width: 68, height: 68)
                }
                .buttonStyle(.plain)
                // NOT `.disabled(myGroup == nil)`: SwiftUI dims a disabled
                // Button's own content by default (even with .plain style),
                // which is what was actually reading as a "faded" avatar
                // with no story, not the ring (already ruled that out).
                // The tap action now always does something meaningful
                // (open the story, or open the composer), so there's
                // nothing to disable in the first place.

                Button {
                    showComposer = true
                } label: {
                    ZStack {
                        Circle().fill(themeManager.theme.primary).frame(width: 22, height: 22)
                        Image(systemName: "plus")
                            .scaledFont(12, .bold)
                            .foregroundColor(.white)
                    }
                }
                .accessibilityLabel(Bundle.app.loc("Add to your story"))
                .disabledWhenRestricted()
                .offset(x: 2, y: 2)
            }
            Text("Your story", bundle: bundle)
                .scaledFont(11, .medium)
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(1)
        }
        .frame(width: 70)
    }

    private func storyBubble(_ group: StoryGroup) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(
                        group.hasUnseen
                            ? themeManager.theme.primary
                            : AppColors.borderDefault(colorScheme),
                        lineWidth: 2.5
                    )
                    .frame(width: 68, height: 68)
                AvatarView(user: group.author, size: 60)
            }
            Text(group.author.name.components(separatedBy: " ").first ?? "")
                .scaledFont(11, .medium)
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(1)
        }
        .frame(width: 70)
    }

    private func load() async {
        await viewModel.load(mode: appState.currentMode, currentUserId: appState.currentUser?.id)
    }
}
