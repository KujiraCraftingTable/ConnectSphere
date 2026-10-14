import SwiftUI

/// Registers an account with @username + password and an optional email
/// (verified with a code before the account is made — POST /auth/register).
/// This only creates the bare-minimum account — the profile (display name, mode,
/// interests, bio…) is handled by OnboardingView right after, just like a new Google user.
struct RegisterView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle

    @State private var viewModel = RegisterViewModel()

    var body: some View {
        ZStack {
            AppColors.base(.light)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 48)
                        .padding(.bottom, 32)

                    GlassCard {
                        Group {
                            if viewModel.stage == .code { codeStage } else { detailsStage }
                        }
                        .animation(.default, value: viewModel.errorMessage)
                        .padding(24)
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 40)
                }
            }
        }
        .navigationTitle(bundle.loc("Create account"))
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
    }

    // MARK: Details

    private var detailsStage: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                AuthTextField(icon: "at", placeholder: bundle.loc("Username"), text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                fieldHint(viewModel.usernameHint, isError: viewModel.usernameError != nil)
            }

            VStack(alignment: .leading, spacing: 6) {
                AuthTextField(icon: "lock.fill", placeholder: bundle.loc("Password"),
                              text: $viewModel.password, isSecure: true)
                fieldHint(viewModel.passwordHint, isError: viewModel.passwordError != nil)
            }

            VStack(alignment: .leading, spacing: 6) {
                AuthTextField(icon: "lock.fill", placeholder: bundle.loc("Confirm password"),
                              text: $viewModel.confirmPassword, isSecure: true)
                if let confirmError = viewModel.confirmError {
                    fieldHint(confirmError, isError: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                AuthTextField(icon: "envelope.fill", placeholder: bundle.loc("Email (optional)"),
                              text: $viewModel.email, keyboardType: .emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                fieldHint(viewModel.emailHint, isError: viewModel.emailError != nil)
            }

            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }

            GradientButton(title: bundle.loc(viewModel.hasEmail ? "Continue" : "Create account"),
                           isLoading: viewModel.isLoading, isEnabled: viewModel.isFormValid) {
                Task { await viewModel.register(appState: appState) }
            }
        }
    }

    // MARK: Code

    /// The email's code: typing the 6th digit creates the account.
    private var codeStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(bundle.loc("Check your email"), systemImage: "envelope.badge")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(.light))
            Text(String(format: bundle.loc("Enter the 6-digit code we sent to %@. Your account is created as soon as it's right."),
                        viewModel.maskedEmail))
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(.light))
                .fixedSize(horizontal: false, vertical: true)
            AuthTextField(icon: "number", placeholder: bundle.loc("6-digit code"), text: $viewModel.code,
                          keyboardType: .numberPad)
                .textContentType(.oneTimeCode)
                .onChange(of: viewModel.code) { _, code in
                    if code.count == 6 { Task { await viewModel.submitCode(appState: appState) } }
                }
            if viewModel.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking the code…", bundle: bundle).font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(.light))
                }
            }
            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }
            HStack {
                Button(bundle.loc("Change email")) { viewModel.changeEmail() }
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(.light))
                Spacer()
                ResendButton(availableAt: viewModel.resendAt, isSending: viewModel.isLoading) {
                    Task { await viewModel.resendCode() }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(themeManager.theme.primary)
                    .frame(width: 72, height: 72)
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 30))
                    .foregroundColor(.white)
            }
            Text("Pick a username and password — you'll set up your profile next", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(.light))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: Field hint

    private func fieldHint(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(isError ? AppColors.danger(.light) : AppColors.textTertiary(.light))
            .padding(.leading, 4)
    }

    // MARK: Error banner

    private func errorBanner(_ errorMessage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(errorMessage)
                .font(.system(size: 13))
        }
        .foregroundColor(AppColors.danger(.light))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.danger(.light).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Actions
}

// MARK: - Preview

#Preview {
    NavigationStack {
        RegisterView()
            .environment(AppState())
            .environment(ThemeManager())
    }
}
