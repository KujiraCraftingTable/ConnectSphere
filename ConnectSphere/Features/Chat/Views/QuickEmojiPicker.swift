import SwiftUI
import UIKit

/// Rules for the per-conversation quick-emoji send (see `quickEmojiStorageKey`).
enum QuickEmoji {
    static let defaultValue = ReactionEmoji.thumbsUp.rawValue

    /// The last whole emoji in `text`, or nil if the last character isn't one.
    /// Checked per `Character` (grapheme cluster), so skin tones, flags and
    /// ZWJ sequences like 👩‍💻 arrive intact rather than as stray scalars.
    static func emoji(in text: String) -> String? {
        guard let last = text.last, isEmoji(last) else { return nil }
        return String(last)
    }

    /// Plain `isEmoji` isn't enough: digits, `#`, `*` and symbols like © carry
    /// it too (they can *become* emoji with a variation selector) but render
    /// as text alone. So require emoji presentation, or a multi-scalar
    /// sequence, ❤️ is U+2764 + VS16, 1️⃣ is a keycap sequence.
    static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && character.unicodeScalars.count > 1)
    }
}

/// Picks the quick emoji from the full system emoji keyboard. Every emoji
/// Apple ships, with its own search, skin tones and recents.
struct QuickEmojiPickerSheet: View {
    @Binding var emoji: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    /// Bumped to bring the emoji keyboard back if the user dismissed it.
    @State private var focusRequest = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Button { focusRequest += 1 } label: {
                    Text(emoji)
                        .scaledFont(72)
                        .frame(width: 112, height: 112)
                        .background(AppColors.elevated(colorScheme), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Current quick emoji", bundle: bundle))

                Text("Pick any emoji from the keyboard", bundle: bundle)
                    .scaledFont(14)
                    .foregroundColor(AppColors.textSecondary(colorScheme))

                // Hosts the keyboard only; it never shows text of its own.
                EmojiKeyboardField(focusRequest: focusRequest, onPick: pick)
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Quick emoji"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
            }
        }
    }

    private func pick(_ value: String) {
        emoji = value
        dismiss()
    }
}

/// A text field that asks for the emoji keyboard and reports each whole emoji
/// typed into it. Anything that isn't an emoji (a letter from switching
/// keyboards, a pasted word) is dropped rather than becoming the quick send.
private struct EmojiKeyboardField: UIViewRepresentable {
    let focusRequest: Int
    let onPick: (String) -> Void

    func makeUIView(context: Context) -> EmojiKeyboardTextField {
        let field = EmojiKeyboardTextField()
        field.tintColor = .clear
        field.textColor = .clear
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)),
                        for: .editingChanged)
        // Next runloop: the field must be in a window before it can take focus.
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: EmojiKeyboardTextField, context: Context) {
        context.coordinator.onPick = onPick
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, focusRequest: focusRequest) }

    final class Coordinator: NSObject {
        var onPick: (String) -> Void
        var lastFocusRequest: Int

        init(onPick: @escaping (String) -> Void, focusRequest: Int) {
            self.onPick = onPick
            self.lastFocusRequest = focusRequest
        }

        @objc func textChanged(_ field: UITextField) {
            let text = field.text ?? ""
            field.text = ""
            if let emoji = QuickEmoji.emoji(in: text) { onPick(emoji) }
        }
    }
}

final class EmojiKeyboardTextField: UITextField {
    /// Opens on the emoji keyboard. Falls back to the default keyboard when
    /// the user has removed the emoji keyboard in Settings.
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }

    /// iOS remembers the last keyboard per context identifier and would
    /// otherwise reopen on whichever keyboard was used last, ignoring
    /// `textInputMode` above.
    override var textInputContextIdentifier: String? { "" }
}
