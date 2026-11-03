import SwiftUI

/// A form's Cancel: always asks before throwing the form away, even when
/// nothing has been typed yet. Pair it with `.interactiveDismissDisabled()`
/// on the sheet so a swipe down can't skip the question.
struct ConfirmCancelButton: View {
    @Environment(\.appBundle) private var bundle
    let onDiscard: () -> Void
    @State private var isAsking = false

    var body: some View {
        Button(bundle.loc("Cancel")) { isAsking = true }
            .confirmationDialog(bundle.loc("Discard changes?"), isPresented: $isAsking, titleVisibility: .visible) {
                Button(bundle.loc("Discard"), role: .destructive) { onDiscard() }
                Button(bundle.loc("Keep editing"), role: .cancel) {}
            }
    }
}
