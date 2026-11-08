import SwiftUI

/// The comment box: a rounded rectangle with the text on top and, inside it,
/// the attached photo and the camera button along the bottom edge (the Facebook
/// layout). The send button stays outside, to its right.
struct CommentInputBox: View {
    @Binding var text: String
    let viewModel: CommentViewModel
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    /// A photo, a line break or a long line grows the box: the camera then
    /// drops to the bottom-right corner instead of sitting beside the text.
    private var isExpanded: Bool { Self.isExpanded(text: text, hasPhoto: viewModel.attachedPhoto != nil) }

    /// Also read by the screens, which center the send button beside a single
    /// line and drop it to the bottom beside a taller box.
    static func isExpanded(text: String, hasPhoto: Bool) -> Bool {
        hasPhoto || text.contains("\n") || text.count > 28
    }

    var body: some View {
        ZStack(alignment: isExpanded ? .bottomTrailing : .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                MarkdownTextEditor(text: $text, placeholder: bundle.loc(appState.isRestricted ? "You can't comment right now" : "Write a comment..."), size: 15,
                                   minHeight: 22, maxHeight: 120)
                    .padding(.trailing, isExpanded ? 0 : 34)
                if viewModel.attachedPhoto != nil {
                    CommentPhotoPreview(viewModel: viewModel)
                }
                // Room for the camera under the text when it sits in the corner.
                if isExpanded { Color.clear.frame(height: 24) }
            }
            CommentPhotoButton(viewModel: viewModel)
                .padding(.bottom, isExpanded ? 6 : 0)
        }
        .animation(.easeOut(duration: 0.15), value: isExpanded)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(AppColors.surface(colorScheme),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
        .disabledWhenRestricted()
    }
}
