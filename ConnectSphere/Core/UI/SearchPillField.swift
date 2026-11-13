import SwiftUI

/// The app's search box: a grey pill with an icon, 15 pt text and a clear
/// button. Shared by the Search tab and Community so both look the same.
struct SearchPillField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    @Binding var text: String
    let placeholder: String
    var icon = "magnifyingglass"
    /// Defaults to the secondary text colour.
    var iconColor: Color?
    /// A coloured ring, e.g. while AI search is on.
    var outline: Color = .clear
    var focus: FocusState<Bool>.Binding?
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(15, .medium)
                .foregroundColor(iconColor ?? AppColors.textSecondary(colorScheme))
            TextField("", text: $text, prompt: Text(placeholder))
                .scaledFont(15)
                .modifier(OptionalFocus(binding: focus))
                .submitLabel(.search)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear", bundle: bundle))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppColors.base(colorScheme), in: Capsule())
        .overlay(Capsule().stroke(outline, lineWidth: 1.5))
    }
}
