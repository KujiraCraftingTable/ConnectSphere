import SwiftUI

/// A form's Cancel: asks before throwing the form away, but only when there
/// is something to lose. A form nobody changed just closes. Pair it with
/// `.interactiveDismissDisabled(hasChanges)` on the sheet so a swipe down
/// can't skip the question.
struct ConfirmCancelButton: View {
    @Environment(\.appBundle) private var bundle
    /// Has anything been typed or changed since the form opened?
    let hasChanges: Bool
    let onDiscard: () -> Void
    @State private var isAsking = false

    var body: some View {
        Button(bundle.loc("Cancel")) {
            if hasChanges { isAsking = true } else { onDiscard() }
        }
            .confirmationDialog(bundle.loc("Discard changes?"), isPresented: $isAsking, titleVisibility: .visible) {
                Button(bundle.loc("Discard"), role: .destructive) { onDiscard() }
                Button(bundle.loc("Keep editing"), role: .cancel) {}
            }
    }
}
