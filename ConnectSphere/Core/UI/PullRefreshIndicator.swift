import SwiftUI

/// A pull-to-refresh indicator for scroll views that run up under the status
/// bar (the profile's cover). The system spinner sits at the very top, centred,
/// which is where the Dynamic Island is — so there it never shows. This one
/// hangs below the navigation bar instead and looks like the system one: its
/// spokes appear as you pull, then it spins while the refresh runs. Pair it
/// with `.refreshable` (which still does the work) and `trackPull` on the
/// scroll view.
struct PullRefreshIndicator: View {
    let pull: CGFloat
    let isRefreshing: Bool

    /// Pull distance (pt) at which every spoke is showing.
    private static let fullPull: CGFloat = 80
    private static let spokes = 8

    private var isShown: Bool { isRefreshing || pull > 6 }

    var body: some View {
        ZStack {
            if isRefreshing {
                // The same spinner the feed's and Notifications' refresh shows.
                ProgressView()
            } else {
                // While pulling, the system control reveals its spokes one by
                // one clockwise from the top; this mirrors it.
                let shown = Int((min(pull / Self.fullPull, 1) * CGFloat(Self.spokes)).rounded(.down))
                ForEach(0..<Self.spokes, id: \.self) { i in
                    Capsule()
                        .fill(.secondary)
                        .frame(width: 2.5, height: 5.5)
                        .offset(y: -7)
                        .rotationEffect(.degrees(Double(i) * 360 / Double(Self.spokes)))
                        .opacity(i < shown ? 1 : 0)
                }
            }
        }
        .frame(width: 20, height: 20)
        .padding(.top, 12)
        .opacity(isShown ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: isShown)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Reports how far the scroll view is pulled past its top edge (0 at rest).
    func trackPull(_ pull: Binding<CGFloat>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
        } action: { _, new in
            pull.wrappedValue = new
        }
    }
}
