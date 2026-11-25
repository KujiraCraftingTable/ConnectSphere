import SwiftUI
import Observation

// MARK: - Toast item
/// One active toast. Created by `UndoToastPresenter.show(message:onUndo:)`,
/// or `show(message:)` for a plain notice with nothing to undo.
struct UndoToastItem: Identifiable {
    let id = UUID()
    let message: String
    let onUndo: (() -> Void)?
    /// Where it slides in from. Bottom by default; top for notices about a
    /// screen the user isn't looking at (e.g. "X is back in Messages").
    var edge: VerticalEdge = .bottom
}

// MARK: - Presenter
/// Presenter for a non-blocking bottom "Undo" toast, shown right after a
/// soft-delete (post/comment) so the user has a brief window to reverse it.
/// One instance is injected app-wide via `.environment` (see
/// `ConnectSphereApp`) and rendered by `MainTabView`'s overlay. Any view can
/// call `show(message:onUndo:)`. Screens presented modally (e.g. `CommentSheet`,
/// a `.sheet`) sit above that overlay, so they own a private instance instead
/// (see `CommentSheet`).
@MainActor
@Observable
final class UndoToastPresenter {
    private(set) var current: UndoToastItem?
    private var dismissTask: Task<Void, Never>?

    /// Shows a toast with `message` and an "Undo" action; replaces whatever
    /// toast is currently showing. Auto-dismisses after ~5s unless tapped.
    func show(message: String, onUndo: (() -> Void)?, edge: VerticalEdge = .bottom) {
        dismissTask?.cancel()
        let item = UndoToastItem(message: message, onUndo: onUndo, edge: edge)
        current = item
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissIfCurrent(id: item.id)
        }
    }

    /// A plain notice in the same place, without an Undo button.
    func show(message: String, edge: VerticalEdge = .bottom) {
        show(message: message, onUndo: nil, edge: edge)
    }

    /// User tapped "Undo", runs the action and dismisses immediately.
    func undo() {
        guard let item = current else { return }
        dismissTask?.cancel()
        current = nil
        item.onUndo?()
    }

    /// Dismisses early (e.g. the owning screen is going away) without running
    /// the undo action.
    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    private func dismissIfCurrent(id: UUID) {
        guard current?.id == id else { return }
        current = nil
    }
}

// MARK: - Toast view
/// Bottom banner UI for one `UndoToastItem`. Message + an "Undo" button.
struct UndoToastView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle

    let item: UndoToastItem
    var onUndo: () -> Void
    /// Room kept below the toast, e.g. for a tab bar it must not cover.
    var bottomInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            Text(item.message)
                .scaledFont(16, .medium)
                .foregroundColor(.white)
                .lineLimit(2)
            Spacer(minLength: 8)
            if item.onUndo != nil {
                Button(action: onUndo) {
                    Text("Undo", bundle: bundle)
                        .scaledFont(16, .semibold)
                        .foregroundColor(themeManager.theme.primary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minHeight: 56)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(item.edge == .bottom ? .bottom : .top, item.edge == .bottom ? 8 + bottomInset : 8)
        .transition(.move(edge: item.edge == .bottom ? .bottom : .top).combined(with: .opacity))
    }
}

// MARK: - Overlay modifier
extension View {
    /// Attaches the shared Undo-toast overlay bound to `presenter`'s current
    /// item, put this on a screen-level view (see `MainTabView`,
    /// `CommentSheet`).
    /// `bottomInset` keeps it clear of a tab bar: the floating one takes the
    /// taps where they overlap, so an Undo drawn over it can't be pressed.
    func undoToastOverlay(_ presenter: UndoToastPresenter, bottomInset: CGFloat = 0) -> some View {
        overlay(alignment: .bottom) {
            if let item = presenter.current, item.edge == .bottom {
                UndoToastView(item: item, onUndo: { presenter.undo() }, bottomInset: bottomInset)
                    .id(item.id)
            }
        }
        .overlay(alignment: .top) {
            if let item = presenter.current, item.edge == .top {
                UndoToastView(item: item, onUndo: { presenter.undo() })
                    .id(item.id)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: presenter.current?.id)
    }
}
