import SwiftUI

/// iOS 26 softens content under the top bar with its own blur; pages whose
/// top stays clear (the feed, a community's cover) turn it off.
private struct NoTopScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

extension View {
    func hidesTopScrollEdgeEffect() -> some View {
        modifier(NoTopScrollEdgeEffect())
    }
}
