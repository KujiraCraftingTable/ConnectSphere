import SwiftUI

extension View {
    /// Attaches every active floating chat bubble from `presenter`, stacked
    /// above the tab bar in a cascading offset so newer bubbles don't
    /// perfectly overlap older ones — put this on a screen-level view (see
    /// `MainTabView`), the same way `.undoToastOverlay(_:)` is.
    func floatingChatOverlay(_ presenter: FloatingChatPresenter) -> some View {
        overlay(alignment: .bottomTrailing) {
            ZStack(alignment: .bottomTrailing) {
                ForEach(Array(presenter.bubbles.enumerated()), id: \.element.id) { index, bubble in
                    FloatingChatBubbleView(bubble: bubble, presenter: presenter)
                        .offset(x: -CGFloat(index) * 16, y: -CGFloat(index) * 16 - 90)
                        .zIndex(Double(index))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.trailing, 16)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: presenter.bubbles.map(\.id))
        }
    }
}
