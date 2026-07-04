import SwiftUI
import Combine
import Observation

enum AppMode: String {
    case friend
    case colleague
}

enum AppLanguage: String, CaseIterable {
    case vietnamese = "vi"
    case english    = "en"

    var displayName: String {
        switch self {
        case .vietnamese: return "Tiếng Việt"
        case .english:    return "English"
        }
    }

    var flag: String {
        switch self {
        case .vietnamese: return "🇻🇳"
        case .english:    return "🇺🇸"
        }
    }
}

enum AppearanceMode: String, CaseIterable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    func label(for language: AppLanguage) -> String {
        switch language {
        case .english: return label
        case .vietnamese:
            switch self {
            case .system: return "Hệ thống"
            case .light:  return "Sáng"
            case .dark:   return "Tối"
            }
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@Observable
class AppState {
    var isLoggedIn:   Bool = false
    var needsOnboarding: Bool = false
    var isCheckingAuth:  Bool = true   // splash while checking Keychain
    var currentMode:  AppMode = .friend
    var currentUser:  UserProfile? = nil
    var shouldFocusSearch: Bool = false
    var chatUnreadCount: Int = 0
    var appearanceMode: AppearanceMode = .system {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode") }
    }
    var appLanguage: AppLanguage = .english {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage") }
    }

    /// The Bundle matching the currently selected in-app language.
    /// Views read this via the `\.appBundle` EnvironmentKey.
    var bundle: Bundle {
        Bundle(path: Bundle.main.path(forResource: appLanguage.rawValue, ofType: "lproj") ?? "")
            ?? Bundle.main
    }

    /// JWT lưu trong Keychain
    private(set) var authToken: String? = nil

    init() {
        if let raw = UserDefaults.standard.string(forKey: "appearanceMode"),
           let saved = AppearanceMode(rawValue: raw) {
            appearanceMode = saved
        }
        if let raw = UserDefaults.standard.string(forKey: "appLanguage"),
           let saved = AppLanguage(rawValue: raw) {
            appLanguage = saved
        } else {
            let code = Locale.current.language.languageCode?.identifier ?? "en"
            appLanguage = AppLanguage(rawValue: code) ?? .english
        }

        NotificationCenter.default.addObserver(
            forName: .postDeleted, object: nil, queue: .main
        ) { [weak self] note in
            guard let authorId = note.userInfo?["authorId"] as? String,
                  self?.currentUser?.id == authorId else { return }
            self?.currentUser?.postCount = max((self?.currentUser?.postCount ?? 0) - 1, 0)
        }
    }


    // ── Auto-login từ Keychain ────────────────────────────────────────────────

    func restoreSession() async {
        defer { Task { @MainActor in isCheckingAuth = false } }
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else { return }

        do {
            let user = try await AuthService.shared.fetchMe(token: token)
            await MainActor.run { finishLogin(token: token, user: user, isNew: !user.isSetup) }
        } catch {
            // Token expired/invalid → clear
            KeychainHelper.delete(forKey: KeychainHelper.tokenKey)
        }
    }

    // ── Login sau Google Sign-In ──────────────────────────────────────────────

    func loginWithGoogle(idToken: String) async throws {
        let response = try await AuthService.shared.signInWithGoogle(idToken: idToken)
        KeychainHelper.save(response.token, forKey: KeychainHelper.tokenKey)
        await MainActor.run { finishLogin(token: response.token, user: response.user, isNew: response.isNewUser) }
    }

    func completeOnboarding(form: OnboardingForm) async throws {
        guard let token = authToken else { return }
        let user = try await AuthService.shared.setup(token: token, form: form)
        await MainActor.run {
            currentUser     = user.toUserProfile()
            needsOnboarding = false
        }
    }

    private func finishLogin(token: String, user: AuthUserDTO, isNew: Bool) {
        authToken       = token
        currentUser     = user.toUserProfile()
        currentMode     = AppMode(rawValue: user.defaultMode) ?? .friend
        isLoggedIn      = true
        needsOnboarding = isNew || !user.isSetup
    }

    // ── Legacy (dùng cho dev/preview) ────────────────────────────────────────

    func login(mode: AppMode) {
        currentMode = mode
        currentUser = MockData.currentUser
        isLoggedIn  = true
    }

    func switchMode(to mode: AppMode) { currentMode = mode }

    func logout() {
        KeychainHelper.delete(forKey: KeychainHelper.tokenKey)
        authToken        = nil
        currentUser      = nil
        isLoggedIn       = false
        needsOnboarding  = false
        chatUnreadCount  = 0
        WebSocketClient.shared.disconnect()
    }
}
