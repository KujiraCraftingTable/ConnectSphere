import SwiftUI

/// "I agree to the Terms of Service and Privacy Policy", an unticked box with
/// the two documents one tap away. Shared by onboarding and the re-accept screen.
struct PolicyAgreementRow: View {
    @Binding var isOn: Bool
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle

    private enum Doc: Identifiable { case terms, privacy; var id: Self { self } }
    @State private var shown: Doc?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { isOn.toggle() } label: {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .scaledFont(24)
                    .foregroundColor(isOn ? Color.accentColor : AppColors.textSecondary(.light))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(bundle.loc("I agree to the Terms of Service and Privacy Policy"))
            .accessibilityValue(isOn ? "✓" : "")
            .accessibilityAddTraits(.isButton)

            VStack(alignment: .leading, spacing: 4) {
                Text(bundle.loc("I am 16 or older and I agree to the"))
                    .scaledFont(14)
                    .foregroundColor(AppColors.textPrimary(.light))
                HStack(spacing: 4) {
                    link(bundle.loc("Terms of Service")) { shown = .terms }
                    Text(bundle.loc("and")).scaledFont(14).foregroundColor(AppColors.textPrimary(.light))
                    link(bundle.loc("Privacy Policy")) { shown = .privacy }
                }
            }
            Spacer(minLength: 0)
        }
        .sheet(item: $shown) { doc in
            NavigationStack {
                switch doc {
                case .terms:   StaticInfoView(titleKey: "Terms of Service", sections: StaticInfoView.termsSections)
                case .privacy: StaticInfoView(titleKey: "Privacy Policy", sections: StaticInfoView.privacySections)
                }
            }
            .environment(appState)
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).scaledFont(14, .semibold).underline()
        }
        .buttonStyle(.plain)
        .foregroundColor(Color.accentColor)
    }
}
