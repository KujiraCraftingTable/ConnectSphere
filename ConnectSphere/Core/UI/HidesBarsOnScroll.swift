import SwiftUI

// MARK: - Bar hiding modifier
/// Scrolling down a long page slides the tab bar away (and whatever the
/// screen ties to `hidden`); scrolling back up, or being near the top, brings
/// it back. Shared by the Home feed and community pages.
private struct HidesBarsOnScroll: ViewModifier {
    @Binding var hidden: Bool
    /// The page never shows the tab bar (inside a community), so only the
    /// screen's own bars follow the scroll.
    var tabBarAlwaysHidden = false
    /// Distance scrolled in the current direction (+ down, − up); a short run
    /// is needed before anything moves, so finger jitter and the bounce at
    /// either end don't make the bars flicker.
    @State private var run: CGFloat = 0
    /// When the bars last moved: while they animate, the scroll view's insets
    /// change under it and those jumps aren't the reader's finger.
    @State private var lastToggle = Date.distantPast

    private struct Metrics: Equatable {
        var offset: CGFloat
        var insetTop: CGFloat
        var contentHeight: CGFloat
        var viewportHeight: CGFloat
    }

    /// A page that barely scrolls keeps its bars: hiding them only makes the
    /// viewport taller, which clamps the offset and re-triggers the toggle.
    private static let minScrollable: CGFloat = 120
    private static let settle: TimeInterval = 0.5

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Metrics.self) { geo in
                Metrics(offset: geo.contentOffset.y + geo.contentInsets.top,
                        insetTop: geo.contentInsets.top,
                        contentHeight: geo.contentSize.height,
                        viewportHeight: geo.containerSize.height)
            } action: { old, new in
                follow(from: old, to: new)
            }
            // `.automatic`, not `.visible`: a screen pushed from here (a post)
            // hides the tab bar itself, and a forced `.visible` here overrides it.
            .toolbar(hidden || tabBarAlwaysHidden ? .hidden : .automatic, for: .tabBar)
    }

    private func follow(from old: Metrics, to new: Metrics) {
        // Hiding the top bar changes the safe area, and with it the inset and
        // viewport: that moves `offset` without any scrolling. Read as a
        // scroll it flips the bars back, which flips the inset again. An
        // endless loop that pins the main thread (the community-page freeze).
        guard old.insetTop == new.insetTop, old.viewportHeight == new.viewportHeight,
              Date().timeIntervalSince(lastToggle) > Self.settle else {
            run = 0
            return
        }
        let delta = new.offset - old.offset
        guard delta != 0 else { return }
        // Restart the run when the direction flips.
        run = (delta > 0) == (run > 0) ? run + delta : delta
        let hide: Bool
        if new.contentHeight - new.viewportHeight < Self.minScrollable { hide = false }
        else if new.offset < 40 { hide = false }          // at (or pulled past) the top
        else if run > 24 { hide = true }                  // reading on, down the page
        else if run < -24 { hide = false }                // heading back up
        else { return }
        guard hide != hidden else { return }
        lastToggle = Date()
        run = 0
        withAnimation(.easeInOut(duration: 0.25)) { hidden = hide }
    }
}

// MARK: - View extension
extension View {
    /// Put on the page's `ScrollView`; `hidden` also drives any bars of the
    /// screen's own that should go with the tab bar.
    func hidesBarsOnScroll(_ hidden: Binding<Bool>, tabBarAlwaysHidden: Bool = false) -> some View {
        modifier(HidesBarsOnScroll(hidden: hidden, tabBarAlwaysHidden: tabBarAlwaysHidden))
    }
}
