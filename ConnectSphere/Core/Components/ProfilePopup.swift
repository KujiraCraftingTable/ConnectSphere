import SwiftUI

/// A profile shown as a full-height pop-up over the current page, with a
/// close button, how every in-context profile opens (a community member,
/// a Marketplace seller), so tapping someone never leaves the page.
struct ProfilePopup<Content: View>: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(Text("Close", bundle: bundle))
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .environment(appState)
        .environment(themeManager)
    }
}

/// A tappable label (a name, a photo) that pops up someone's profile in a
/// community, in place of pushing a new page.
struct CommunityProfileLink<Label: View>: View {
    let communityId: String
    let userId: String
    @ViewBuilder let label: () -> Label

    @State private var isShowing = false

    var body: some View {
        Button { isShowing = true } label: { label() }
            .buttonStyle(.plain)
            .sheet(isPresented: $isShowing) {
                ProfilePopup { CommunityMemberProfileView(communityId: communityId, userId: userId) }
            }
    }
}
