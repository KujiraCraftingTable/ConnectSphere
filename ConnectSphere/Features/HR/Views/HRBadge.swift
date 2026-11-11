import SwiftUI

/// "✓ HR · Company": this person is the company's verified HR (server
/// migration 126). Work mode only; callers never show it in Hobby.
struct HRBadge: View {
    @Environment(\.appBundle) private var bundle
    let company: String?
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.seal.fill")
            if compact || company == nil {
                Text("HR", bundle: bundle)
            } else {
                Text(String(format: bundle.loc("HR at %@"), company ?? ""))
                    .lineLimit(1)
            }
        }
        .scaledFont(compact ? 11 : 12, .semibold)
        .foregroundColor(Color(hex: "#0A66C2"))
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 1 : 3)
        .background(Capsule().fill(Color(hex: "#0A66C2").opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(format: bundle.loc("Verified HR at %@"), company ?? "")))
    }
}
