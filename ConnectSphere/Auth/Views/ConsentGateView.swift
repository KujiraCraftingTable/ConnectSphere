import SwiftUI

/// Blocks the app until the updated Terms and Privacy Policy are accepted.
/// Declining means signing out, there is no way to use the app without agreeing.
struct ConsentGateView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @State private var viewModel = ConsentGateViewModel()

    var body: some View {
        ZStack {
            AppColors.base(.light).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "doc.text.fill")
                    .scaledFont(34)
                    .foregroundColor(.accentColor)
                Text(bundle.loc("Our Terms and Privacy Policy"))
                    .scaledFont(24, .bold)
                    .foregroundColor(AppColors.textPrimary(.light))
                Text(bundle.loc("Please read them and agree to keep using ConnectSphere."))
                    .scaledFont(15)
                    .foregroundColor(AppColors.textSecondary(.light))
                PolicyAgreementRow(isOn: $viewModel.agrees)
                if let message = viewModel.errorMessage {
                    Text(message).scaledFont(13).foregroundColor(.red)
                }
                GradientButton(title: bundle.loc("Agree and continue"),
                               isLoading: viewModel.isLoading, isEnabled: viewModel.agrees) {
                    Task {
                        if await viewModel.accept(token: appState.authToken) { appState.needsConsent = false }
                    }
                }
                Button(bundle.loc("Log out")) { appState.logout() }
                    .scaledFont(14)
                    .foregroundColor(AppColors.textSecondary(.light))
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .preferredColorScheme(.light)
    }
}
