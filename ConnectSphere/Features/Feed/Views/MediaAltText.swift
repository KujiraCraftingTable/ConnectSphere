import SwiftUI

// MARK: - Alt text chip
/// The "ALT" chip on a picked photo/video in the composer. Filled once the
/// item has a description. Tapping opens `AltTextEditorSheet`.
struct AltTextChip: View {
    let hasText: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if hasText { Image(systemName: "checkmark").scaledFont(9, .bold) }
                Text(verbatim: "ALT").scaledFont(11, .heavy)
            }
            .foregroundColor(hasText ? .black : .white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(hasText ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.6)), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel(Text(hasText ? "Edit description" : "Add description", bundle: .app))
    }
}

// MARK: - Alt text editor
/// Describe a photo or video for people whose media hasn't loaded (or who
/// can't see it). Saved only on Done.
struct AltTextEditorSheet: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let preview: UIImage?
    let isVideo: Bool
    let initialText: String
    let onSave: (String) -> Void

    static let maxLength = 300

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                }
                TextField(bundle.loc(isVideo ? "Describe what happens in this video" : "Describe what's in this photo"),
                          text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focused)
                    .padding(12)
                    .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .onChange(of: text) { _, new in if new.count > Self.maxLength { text = String(new.prefix(Self.maxLength)) } }
                HStack {
                    Text("Shown while it loads, and read aloud by VoiceOver.", bundle: bundle)
                    Spacer()
                    Text("\(text.count)/\(Self.maxLength)")
                }
                .scaledFont(12)
                .foregroundColor(AppColors.textTertiary(colorScheme))
                Spacer()
            }
            .padding(AppSpacing.lg)
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Alt text"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(text != initialText)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ConfirmCancelButton(hasChanges: text != initialText) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Done")) {
                        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { text = initialText; focused = true }
    }
}
