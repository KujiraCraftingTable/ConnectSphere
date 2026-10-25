import SwiftUI

/// Scrolling down a long page slides the tab bar away (and whatever the
/// screen ties to `hidden`); scrolling back up, or being near the top, brings
/// it back. Shared by the Home feed and community pages.
private struct HidesBarsOnScroll: ViewModifier {
    @Binding var hidden: Bool
    /// Distance scrolled in the current direction (+ down, − up); a short run
    /// is needed before anything moves, so finger jitter and the bounce at
    /// either end don't make the bars flicker.
    @State private var run: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { old, new in
                follow(from: old, to: new)
            }
            .toolbar(hidden ? .hidden : .visible, for: .tabBar)
    }

    private func follow(from old: CGFloat, to new: CGFloat) {
        let delta = new - old
        guard delta != 0 else { return }
        // Restart the run when the direction flips.
        run = (delta > 0) == (run > 0) ? run + delta : delta
        let hide: Bool
        if new < 40 { hide = false }          // at (or pulled past) the top
        else if run > 24 { hide = true }      // reading on, down the page
        else if run < -24 { hide = false }    // heading back up
        else { return }
        guard hide != hidden else { return }
        withAnimation(.easeInOut(duration: 0.25)) { hidden = hide }
    }
}

extension View {
    /// Put on the page's `ScrollView`; `hidden` also drives any bars of the
    /// screen's own that should go with the tab bar.
    func hidesBarsOnScroll(_ hidden: Binding<Bool>) -> some View {
        modifier(HidesBarsOnScroll(hidden: hidden))
    }
}
