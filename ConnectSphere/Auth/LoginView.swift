import SwiftUI
import AuthenticationServices
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
                                LabelDivider(label: bundle.loc("hoặc tiếp tục với"))
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
                ModeSelectionView()
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
            Text("Đăng nhập vào tài khoản của bạn", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(.light))
        }
    }

    // MARK: Credentials Section

    private var credentialSection: some View {
        VStack(spacing: 14) {
            AuthTextField(
                icon: "person.fill",
                placeholder: bundle.loc("Tên người dùng"),
                text: $username
            )
            AuthTextField(
                icon: "lock.fill",
                placeholder: bundle.loc("Mật khẩu"),
                text: $password,
                isSecure: true
            )

            // Forgot password
            HStack {
                Spacer()
                Button(bundle.loc("Quên mật khẩu?")) {
                    // TODO: navigate to forgot-password flow
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(themeManager.theme.accentGradient)
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

            GradientButton(title: bundle.loc("Đăng nhập"), isLoading: isLoading) {
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

            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handleAppleSignIn(result: result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Register Prompt

    private var registerPrompt: some View {
        HStack(spacing: 4) {
            Text("Chưa có tài khoản?", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(.light))
            Button(bundle.loc("Đăng ký")) {
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
            triggerError(bundle.loc("Vui lòng điền đầy đủ thông tin."))
            return
        }
        isLoading = true
        showError = false
        // Mock login — succeeds for any non-empty credentials
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            isLoading = false
            appState.login(mode: .friend)
        }
    }

    private func handleGoogleSignIn() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }

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
                triggerError(bundle.loc("Không lấy được Google token"))
                return
            }
            Task {
                do {
                    try await appState.loginWithGoogle(idToken: idToken)
                } catch {
                    await MainActor.run {
                        isLoading = false
                        triggerError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func handleAppleSignIn(result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            if let credential = auth.credential as? ASAuthorizationAppleIDCredential {
                let userID = credential.user
                print("Apple Sign-In succeeded, userID: \(userID)")
                // TODO: send to backend
            }
        case .failure(let error):
            triggerError(error.localizedDescription)
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
