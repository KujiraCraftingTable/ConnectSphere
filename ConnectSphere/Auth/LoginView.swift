import SwiftUI
import GoogleSignIn

// MARK: - LoginView

struct LoginView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoading: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var navigateToRegister: Bool = false
    @State private var showForgotPassword: Bool = false
    @State private var logoScale: CGFloat = 0.6
    @State private var cardOffset: CGFloat = 60
    @State private var cardOpacity: Double = 0

    var body: some View {
        NavigationStack {
            ZStack {
                // ── Background ──────────────────────────────
                AppColors.base(.light)
                    .ignoresSafeArea()

                // ── Content ─────────────────────────────────
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Logo + headline
                        logoSection
                            .padding(.top, 72)
                            .padding(.bottom, 40)
                            .scaleEffect(logoScale)
                            .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1), value: logoScale)

                        // Card
                        GlassCard {
                            VStack(spacing: 20) {
                                credentialSection
                                Spacer(minLength: 4)
                                LabelDivider(label: bundle.loc("or continue with"))
                                socialSection
                                registerPrompt
                            }
                            .padding(24)
                        }
                        .padding(.horizontal, 24)
                        .offset(y: cardOffset)
                        .opacity(cardOpacity)
                        .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.25), value: cardOffset)
                        .animation(.easeOut(duration: 0.5).delay(0.25), value: cardOpacity)

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToRegister) {
                RegisterView()
            }
            .sheet(isPresented: $showForgotPassword) {
                ForgotPasswordView()
                    .environment(themeManager)
            }
            .onAppear {
                logoScale = 1.0
                cardOffset = 0
                cardOpacity = 1
            }
        }
        .preferredColorScheme(.light)
    }

    // MARK: Logo Section

    private var logoSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(themeManager.theme.primaryGradient)
                    .frame(width: 72, height: 72)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white)
            }
            Text("ConnectSphere")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(themeManager.theme.primaryGradient)
            Text("Sign in to your account", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(.light))
        }
    }

    // MARK: Credentials Section

    private var credentialSection: some View {
        VStack(spacing: 14) {
            AuthTextField(
                icon: "person.fill",
                placeholder: bundle.loc("Username"),
                text: $username
            )
            AuthTextField(
                icon: "lock.fill",
                placeholder: bundle.loc("Password"),
                text: $password,
                isSecure: true
            )

            HStack {
                Spacer()
                Button(bundle.loc("Forgot password?")) { showForgotPassword = true }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColors.textSecondary(.light))
            }

            // Error banner
            if showError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage)
                        .font(.system(size: 13))
                }
                .foregroundColor(Color(hex: "#FF6B6B"))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(hex: "#FF6B6B").opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .transition(.scale.combined(with: .opacity))
            }

            GradientButton(title: bundle.loc("Log in"), isLoading: isLoading) {
                handleLogin()
            }
        }
    }

    // MARK: Social Section

    private var socialSection: some View {
        VStack(spacing: 12) {
            // Google Sign-In button following Google brand guidelines
            Button(action: handleGoogleSignIn) {
                HStack {
                    Spacer()
                    HStack(spacing: 10) {
                        GoogleGLogo()
                            .frame(width: 20, height: 20)
                        Text("Continue with Google", bundle: bundle)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Color(hex: "#3c4043"))
                    }
                    Spacer()
                }
                .frame(height: 50)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(hex: "#dadce0"), lineWidth: 1)
                )
            }

        }
    }

    // MARK: Register Prompt

    private var registerPrompt: some View {
        HStack(spacing: 4) {
            Text("Don't have an account?", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(.light))
            Button(bundle.loc("Sign up")) {
                navigateToRegister = true
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(themeManager.theme.primaryGradient)
        }
        .padding(.top, 4)
    }

    // MARK: Handlers

    private func handleLogin() {
        guard !username.isEmpty, !password.isEmpty else {
            triggerError(bundle.loc("Please fill in all fields."))
            return
        }
        isLoading = true
        showError = false
        Task {
            do {
                try await appState.loginWithPassword(
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password
                )
            } catch {
                await MainActor.run {
                    isLoading = false
                    triggerError(loginErrorMessage(error))
                }
            }
        }
    }

    /// Maps an HTTP status from the server to a localized message.
    private func loginErrorMessage(_ error: Error) -> String {
        if let networkMessage = networkErrorMessage(error) { return networkMessage }
        switch (error as NSError).code {
        case 401: return bundle.loc("Invalid username or password")
        case 429: return bundle.loc("Too many attempts, please try again later")
        default:  return bundle.loc("Couldn't sign in, please try again")
        }
    }

    /// The request never reached the server (wrong IP/no network/server not running) → a
    /// dedicated message, to avoid showing a raw system error or a generic message that could
    /// be mistaken for a wrong password.
    private func networkErrorMessage(_ error: Error) -> String? {
        (error as NSError).domain == NSURLErrorDomain
            ? bundle.loc("Cannot reach the server, please check your connection")
            : nil
    }

    private func handleGoogleSignIn() {
        guard let windowScene = UIApplication.shared.connectedScenes
                  .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                  ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = (windowScene.windows.first(where: \.isKeyWindow) ?? windowScene.windows.first)?.rootViewController
        else {
            triggerError(bundle.loc("Couldn't sign in, please try again"))
            return
        }

        isLoading = true
        showError = false

        GIDSignIn.sharedInstance.signIn(withPresenting: rootVC) { result, error in
            if let error {
                isLoading = false
                if (error as NSError).code != GIDSignInError.canceled.rawValue {
                    triggerError(error.localizedDescription)
                }
                return
            }
            guard let idToken = result?.user.idToken?.tokenString else {
                isLoading = false
                triggerError(bundle.loc("Could not get Google token"))
                return
            }
            Task {
                do {
                    try await appState.loginWithGoogle(idToken: idToken)
                } catch {
                    await MainActor.run {
                        isLoading = false
                        // If the server returns an error (e.g. "Invalid Google token"), show it
                        // verbatim; a connection failure gets mapped to the localized network message.
                        triggerError(networkErrorMessage(error) ?? error.localizedDescription)
                    }
                }
            }
        }
    }

    private func triggerError(_ message: String) {
        errorMessage = message
        withAnimation { showError = true }
    }
}

// MARK: - Google G Logo (image asset from Assets.xcassets/GoogleLogo.imageset)

struct GoogleGLogo: View {
    var body: some View {
        Image("GoogleLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

// MARK: - Preview

#Preview {
    LoginView()
        .environment(AppState())
        .environment(ThemeManager())
}
