import UIKit

// MARK: - Tap to dismiss
/// App-wide: a tap anywhere outside the field being typed in hides the
/// keyboard, every screen, sheet and cover, without each one opting in.
/// One tap recognizer per window; it never cancels the tap, so the button or
/// row underneath still gets it.
enum KeyboardDismissal {
    private static let name = "KeyboardDismissal"
    private static let handler = Handler()
    /// Window-space frames where a tap keeps the keyboard up (see `keepsKeyboard()`).
    /// Only touched on the main thread, by SwiftUI layout and UIKit touch delivery.
    nonisolated(unsafe) static var keepRegions: [UUID: CGRect] = [:]

    static func install() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where !(window.gestureRecognizers ?? []).contains(where: { $0.name == name }) {
                let tap = UITapGestureRecognizer(target: handler, action: #selector(Handler.tapped(_:)))
                tap.name = name
                tap.cancelsTouchesInView = false
                // Hand the lift-off to the control at once: held back (the
                // default), a quick tap on a switch arrived late and was
                // ignored, so toggles only flipped on a long press.
                tap.delaysTouchesEnded = false
                tap.delegate = handler
                window.addGestureRecognizer(tap)
            }
        }
    }

    private final class Handler: NSObject, UIGestureRecognizerDelegate {
        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            recognizer.view?.endEditing(true)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Never on a control (a switch, slider, segmented picker): sharing
            // the touch made switches ignore taps and only flip when dragged.
            var c = touch.view
            while let cur = c {
                if cur is UIControl { return false }
                c = cur.superview
            }
            guard let window = g.view, let responder = UIResponder.currentFirst as? UIView else { return false }
            // Controls that work with the field, like a stepper's − and +.
            let point = touch.location(in: window)
            if KeyboardDismissal.keepRegions.values.contains(where: { $0.contains(point) }) { return false }
            // Tapping a field (this one or another) just moves the focus.
            var v = touch.view
            while let cur = v {
                if cur is UITextField || cur is UITextView { return false }
                v = cur.superview
            }
            // Nor a tap in the field's own bar: a chat composer's Send, a
            // password's eye button. The keyboard should stay for those.
            return !inputBar(of: responder, in: window).contains(touch.location(in: window))
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// The widest short (≤ 160 pt) container around the field, in window space.
        private func inputBar(of field: UIView, in window: UIView) -> CGRect {
            var bar = field
            while let parent = bar.superview, parent !== window, parent.bounds.height <= 160 { bar = parent }
            return bar.convert(bar.bounds, to: window)
        }
    }
}

// MARK: - First responder lookup
private extension UIResponder {
    nonisolated(unsafe) static weak var found: UIResponder?

    /// The view being typed in, if any.
    static var currentFirst: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(captureFirst), to: nil, from: nil, for: nil)
        return found
    }

    @objc func captureFirst() { UIResponder.found = self }
}

import SwiftUI

// MARK: - Keeping the keyboard
extension View {
    /// Taps on this view don't hide the keyboard, for buttons that work with
    /// the field being typed in (SwiftUI buttons aren't UIControls, so the
    /// window recognizer would otherwise treat them as "outside").
    func keepsKeyboard() -> some View { modifier(KeepsKeyboard()) }
}

private struct KeepsKeyboard: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                KeyboardDismissal.keepRegions[id] = $0
            }
            .onDisappear { KeyboardDismissal.keepRegions[id] = nil }
    }
}
