import SwiftUI

/// Đăng ký tài khoản bằng username + password (POST /auth/register).
/// Chỉ tạo tài khoản tối thiểu — hồ sơ (tên hiển thị, mode, sở thích, bio…)
/// do OnboardingView lo ngay sau đó, giống hệt user Google mới.
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
                            AuthTextField(
                                icon: "person.fill",
                                placeholder: bundle.loc("Username"),
                                text: Binding(
                                    get: { username },
                                    // Cùng filter với bước onboarding: chữ thường, số, gạch dưới
                                    set: { username = $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" } }
                                )
                            )
                            AuthTextField(
                                icon: "lock.fill",
                                placeholder: bundle.loc("Password (at least 8 characters)"),
                                text: $password,
                                isSecure: true
                            )
                            AuthTextField(
                                icon: "lock.fill",
                                placeholder: bundle.loc("Confirm password"),
                                text: $confirmPassword,
                                isSecure: true
                            )

                            if showError {
                                errorBanner
                            }

                            GradientButton(title: bundle.loc("Create account"), isLoading: isLoading) {
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
                    .fill(themeManager.theme.primaryGradient)
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

    // MARK: Error banner

    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(errorMessage)
                .font(.system(size: 13))
        }
        .foregroundColor(Color(hex: "#FF6B6B"))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#FF6B6B").opacity(0.12))
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
                // Thành công → finishLogin đặt needsOnboarding=true, root view tự vào onboarding
                try await appState.registerWithPassword(username: name, password: password)
            } catch {
                await MainActor.run {
                    isLoading = false
                    triggerError(registerErrorMessage(error))
                }
            }
        }
    }

    /// Map HTTP status từ server sang thông báo đã localize.
    /// Lỗi mạng (không tới được server) tách riêng để không hiểu nhầm là lỗi dữ liệu nhập.
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
