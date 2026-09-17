import SwiftUI

/// Registers an account with username + password (POST /auth/register).
/// This only creates the bare-minimum account — the profile (display name, mode,
/// interests, bio…) is handled by OnboardingView right after, just like a new Google user.
struct RegisterView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle

    @State private var username        = ""
    @State private var password        = ""
    @State private var confirmPassword = ""
    @State private var isLoading    = false
    @State private var showError    = false
    @State private var errorMessage = ""

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
                        VStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                AuthTextField(
                                    icon: "person.fill",
                                    placeholder: bundle.loc("Username"),
                                    // Only a silent lowercase normalization — everything else
                                    // (symbols, too-short) is now surfaced as a live warning
                                    // below instead of being silently stripped, so the user
                                    // can see why and fix it.
                                    text: Binding(
                                        get: { username },
                                        set: { username = $0.lowercased() }
                                    )
                                )
                                fieldHint(usernameHint, isError: usernameError != nil)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                AuthTextField(
                                    icon: "lock.fill",
                                    placeholder: bundle.loc("Password"),
                                    text: $password,
                                    isSecure: true
                                )
                                fieldHint(passwordHint, isError: passwordError != nil)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                AuthTextField(
                                    icon: "lock.fill",
                                    placeholder: bundle.loc("Confirm password"),
                                    text: $confirmPassword,
                                    isSecure: true
                                )
                                if let confirmError {
                                    fieldHint(confirmError, isError: true)
                                }
                            }

                            if showError {
                                errorBanner
                            }

                            GradientButton(title: bundle.loc("Create account"), isLoading: isLoading, isEnabled: isFormValid) {
                                handleRegister()
                            }
                        }
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

    // MARK: Field validation

    private var usernameError: String? {
        guard !username.isEmpty else { return nil }
        if username.contains(where: { !($0.isLetter || $0.isNumber || $0 == "_") }) {
            return bundle.loc("Only letters, numbers, and underscore (_) are allowed")
        }
        if username.count < 3 {
            return bundle.loc("Username must be at least 3 characters")
        }
        return nil
    }

    private var usernameHint: String {
        usernameError ?? bundle.loc("Letters, numbers, and underscore (_) only, at least 3 characters")
    }

    private var passwordError: String? {
        guard !password.isEmpty else { return nil }
        return password.count < 8 ? bundle.loc("Password must be at least 8 characters") : nil
    }

    private var passwordHint: String {
        passwordError ?? bundle.loc("At least 8 characters. Add symbols like !@#$%^&*_ for extra security.")
    }

    private var confirmError: String? {
        guard !confirmPassword.isEmpty, confirmPassword != password else { return nil }
        return bundle.loc("Passwords don't match")
    }

    private var isFormValid: Bool {
        username.count >= 3 && usernameError == nil &&
        password.count >= 8 &&
        !confirmPassword.isEmpty && confirmPassword == password
    }

    private func fieldHint(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(isError ? AppColors.danger(.light) : AppColors.textTertiary(.light))
            .padding(.leading, 4)
    }

    // MARK: Error banner

    private var errorBanner: some View {
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

    private func handleRegister() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard name.count >= 3 else {
            triggerError(bundle.loc("Username must be at least 3 characters"))
            return
        }
        guard password.count >= 8 else {
            triggerError(bundle.loc("Password must be at least 8 characters"))
            return
        }
        guard password == confirmPassword else {
            triggerError(bundle.loc("Passwords don't match"))
            return
        }

        isLoading = true
        showError = false
        Task {
            do {
                // On success → finishLogin sets needsOnboarding=true, root view auto-navigates into onboarding
                try await appState.registerWithPassword(username: name, password: password)
            } catch {
                await MainActor.run {
                    isLoading = false
                    triggerError(registerErrorMessage(error))
                }
            }
        }
    }

    /// Maps an HTTP status from the server to a localized message.
    /// Network errors (couldn't reach the server) are handled separately so they aren't
    /// mistaken for a validation error.
    private func registerErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return bundle.loc("Cannot reach the server, please check your connection")
        }
        switch nsError.code {
        case 409: return bundle.loc("Username already taken")
        case 429: return bundle.loc("Too many attempts, please try again later")
        default:  return bundle.loc("Couldn't create account, please try again")
        }
    }

    private func triggerError(_ message: String) {
        errorMessage = message
        withAnimation { showError = true }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        RegisterView()
            .environment(AppState())
            .environment(ThemeManager())
    }
}
