import SwiftUI
import Observation

/// One active toast. Created by `UndoToastPresenter.show(message:onUndo:)`,
/// or `show(message:)` for a plain notice with nothing to undo.
struct UndoToastItem: Identifiable {
    let id = UUID()
    let message: String
    let onUndo: (() -> Void)?
}

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
    func show(message: String, onUndo: (() -> Void)?) {
        dismissTask?.cancel()
        let item = UndoToastItem(message: message, onUndo: onUndo)
        current = item
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissIfCurrent(id: item.id)
        }
    }

    /// A plain notice in the same place, without an Undo button.
    func show(message: String) {
        show(message: message, onUndo: nil)
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

/// Bottom banner UI for one `UndoToastItem`. Message + an "Undo" button.
struct UndoToastView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle

    let item: UndoToastItem
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(item.message)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .lineLimit(2)
            Spacer(minLength: 8)
            if item.onUndo != nil {
                Button(action: onUndo) {
                    Text("Undo", bundle: bundle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(themeManager.theme.primary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// Attaches the shared Undo-toast overlay bound to `presenter`'s current
    /// item, put this on a screen-level view (see `MainTabView`,
    /// `CommentSheet`).
    func undoToastOverlay(_ presenter: UndoToastPresenter) -> some View {
        overlay(alignment: .bottom) {
            if let item = presenter.current {
                UndoToastView(item: item, onUndo: { presenter.undo() })
                    .id(item.id)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: presenter.current?.id)
    }
}
