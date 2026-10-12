import SwiftUI

/// A pull-to-refresh indicator for scroll views that run up under the status
/// bar (the profile's cover). The system spinner sits at the very top, centred,
/// which is where the Dynamic Island is — so there it never shows. This one
/// hangs below the navigation bar instead, follows the pull, then spins while
/// the refresh runs. Pair it with `.refreshable` (which still does the work)
/// and `trackPull` on the scroll view.
struct PullRefreshIndicator: View {
    let pull: CGFloat
    let isRefreshing: Bool

    /// Pull distance (pt) at which the ring is complete.
    private static let fullPull: CGFloat = 80

    private var isShown: Bool { isRefreshing || pull > 6 }

    var body: some View {
        ZStack {
            if isRefreshing {
                ProgressView()
            } else {
                Circle()
                    .trim(from: 0, to: min(pull / Self.fullPull, 1))
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(10)
            }
        }
        .frame(width: 38, height: 38)
        .modifier(GlassCircle())
        .padding(.top, 8)
        .opacity(isShown ? 1 : 0)
        .scaleEffect(isShown ? 1 : 0.6)
        .animation(.easeOut(duration: 0.18), value: isShown)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
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
