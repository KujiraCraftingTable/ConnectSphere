import SwiftUI
import Combine
import Observation

enum AppMode: String, Identifiable {
    case hobby
    case work

    var id: String { rawValue }

    /// Icon đại diện cho chế độ. Hobby = sở thích/giải trí (đối lập với "công việc"),
    /// cố ý KHÁC icon privacy "Bạn bè" (person.2.fill) để tránh nhầm lẫn.
    var glyph: String {
        switch self {
        case .hobby: return "gamecontroller.fill"
        case .work:  return "briefcase.fill"
        }
    }
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
    var currentMode:  AppMode = .hobby
    var currentUser:  UserProfile? = nil
    /// Mode user muốn chuyển sang nhưng chưa setup persona — trigger sheet
    /// PersonaSetupView; hoàn tất form mới thực sự switch, hủy thì ở lại mode cũ
    var pendingPersonaMode: AppMode? = nil
    var shouldFocusSearch: Bool = false
    /// Bấm lại tab "Tìm kiếm" khi đang ở đó → SearchView reset về trạng thái duyệt mặc định
    var shouldResetSearch: Bool = false
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
            // Chỉ xoá token khi server khẳng định 401 (hết hạn/hỏng).
            // Lỗi mạng hoặc server tạm chết → GIỮ token để lần mở sau còn
            // auto-login được, không bắt user đăng nhập lại oan.
            if (error as? URLError)?.code == .userAuthenticationRequired {
                KeychainHelper.delete(forKey: KeychainHelper.tokenKey)
            }
        }
    }

    // ── Login sau Google Sign-In ──────────────────────────────────────────────

    func loginWithGoogle(idToken: String) async throws {
        let response = try await AuthService.shared.signInWithGoogle(idToken: idToken)
        KeychainHelper.save(response.token, forKey: KeychainHelper.tokenKey)
        await MainActor.run { finishLogin(token: response.token, user: response.user, isNew: response.isNewUser) }
    }

    // ── Login / đăng ký bằng username + password ─────────────────────────────

    func loginWithPassword(username: String, password: String) async throws {
        let response = try await AuthService.shared.login(username: username, password: password)
        KeychainHelper.save(response.token, forKey: KeychainHelper.tokenKey)
        await MainActor.run { finishLogin(token: response.token, user: response.user, isNew: response.isNewUser) }
    }

    /// Đăng ký xong là đăng nhập luôn — is_new_user=true nên root view tự vào onboarding.
    func registerWithPassword(username: String, password: String) async throws {
        let response = try await AuthService.shared.register(username: username, password: password)
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
        currentMode     = AppMode(rawValue: user.defaultMode) ?? .hobby
        isLoggedIn      = true
        needsOnboarding = isNew || !user.isSetup
    }

    func switchMode(to mode: AppMode) { currentMode = mode }

    // ── Persona theo mode ─────────────────────────────────────────────────────

    /// User đã setup persona (danh tính riêng) của mode này chưa
    func isPersonaSetup(_ mode: AppMode) -> Bool {
        guard let user = currentUser else { return false }
        return mode == .hobby ? user.hobbySetup : user.workSetup
    }

    /// Mọi nơi đổi mode phải đi qua đây: persona của mode đích chưa setup →
    /// không switch, hiện form tạo persona (PersonaSetupView) trước.
    func requestModeSwitch(to mode: AppMode) {
        guard mode != currentMode else { return }
        if isPersonaSetup(mode) {
            currentMode = mode
        } else {
            pendingPersonaMode = mode
        }
    }

    /// PersonaSetupView tạo persona thành công → cập nhật cờ setup,
    /// switch sang mode mới và đóng sheet.
    func personaCreated(_ user: UserProfile, mode: AppMode) {
        // Giữ email/hasPassword hiện có — response persona là profile công khai
        if var updated = currentUser {
            updated.hobbySetup = user.hobbySetup
            updated.workSetup  = user.workSetup
            currentUser = updated
        }
        pendingPersonaMode = nil
        currentMode = mode
    }

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
