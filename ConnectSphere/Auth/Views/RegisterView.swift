import SwiftUI

/// Registers an account with @username + password and an optional email
/// (verified with a code before the account is made, POST /auth/register).
/// This only creates the bare-minimum account. The profile (display name, mode,
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
        // Onboarding comes next; the account is created when it finishes.
        // Closing it (to change the username) returns here, all still typed.
        .fullScreenCover(item: $viewModel.pending) { signup in
            OnboardingView(pending: signup)
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
                    .task(id: viewModel.username) { await viewModel.checkUsername() }
                usernameStatusLine
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

            GradientButton(title: bundle.loc("Continue"),
                           isLoading: viewModel.isLoading, isEnabled: viewModel.isFormValid) {
                Task { await viewModel.register() }
            }
        }
    }

    /// Live: the format rule, then whether the server says it's free.
    @ViewBuilder
    private var usernameStatusLine: some View {
        if let problem = viewModel.usernameError {
            fieldHint(problem, isError: true)
        } else {
            switch viewModel.usernameStatus {
            case .taken:     fieldHint(bundle.loc("Username already taken"), isError: true)
            case .available: Label(bundle.loc("Username available"), systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12)).foregroundColor(.green).padding(.leading, 4)
            case .checking:  fieldHint(bundle.loc("Checking…"), isError: false)
            case .failed:    fieldHint(bundle.loc("Couldn't check the username, try again"), isError: true)
            case .idle:      fieldHint(viewModel.usernameHint, isError: false)
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
            Text(String(format: bundle.loc("Enter the 6-digit code we sent to %@. Then you'll set up your profile."),
                        viewModel.maskedEmail))
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(.light))
                .fixedSize(horizontal: false, vertical: true)
            // No Confirm: the code is checked as soon as all six digits are in.
            CodeEntry(code: $viewModel.code, resendAt: viewModel.resendAt, isSending: viewModel.isLoading,
                      onResend: { Task { await viewModel.resendCode() } })
                .onChange(of: viewModel.code) { _, code in
                    if code.count == 6 { Task { await viewModel.submitCode() } }
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
            Button(bundle.loc("Change email")) { viewModel.changeEmail() }
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(.light))
                .frame(maxWidth: .infinity)
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
            Text("Pick a username and password, you'll set up your profile next", bundle: bundle)
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
