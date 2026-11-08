import SwiftUI

/// Instagram's "Are you sure you want to post this?": when the server finds
/// rude wording in a comment it asks first, and a refused comment (threats,
/// slurs) says why. Either way the text goes back into the field to edit.
struct ConfirmBeforePosting: ViewModifier {
    @Environment(\.appBundle) private var bundle

    let viewModel: CommentViewModel
    @Binding var text: String
    /// Called when "Post anyway" went through.
    let onPosted: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(bundle.loc("Are you sure you want to post this?"),
                   isPresented: Binding(get: { viewModel.held != nil }, set: { _ in })) {
                Button(bundle.loc("Post anyway")) {
                    Task<Void, Never>(name: nil) { if await viewModel.postHeld() { onPosted() } }
                }
                Button(bundle.loc("Edit"), role: .cancel) {
                    if let held = viewModel.takeHeldText() { text = held }
                }
            } message: {
                Text("This may hurt someone. You can edit it first.", bundle: bundle)
            }
            .alert(bundle.loc("We couldn't post this"),
                   isPresented: Binding(get: { viewModel.refusal != nil }, set: { _ in })) {
                Button(bundle.loc("OK")) {
                    if let refused = viewModel.takeRefusedText() { text = refused }
                }
            } message: {
                Text(viewModel.refusal ?? "")
            }
    }
}

extension View {
    func confirmBeforePosting(_ viewModel: CommentViewModel, text: Binding<String>, onPosted: @escaping () -> Void) -> some View {
        modifier(ConfirmBeforePosting(viewModel: viewModel, text: text, onPosted: onPosted))
    }
}
