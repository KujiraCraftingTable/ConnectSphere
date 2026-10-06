import SwiftUI
import Combine
import Observation

enum AppMode: String, Identifiable {
    case hobby
    case work

    var id: String { rawValue }

    /// Icon representing the mode. Hobby = leisure/interests (as opposed to "work"),
    /// deliberately DIFFERENT from the "Friends" privacy icon (person.2.fill) to avoid confusion.
    var glyph: String {
        switch self {
        case .hobby: return "gamecontroller.fill"
        case .work:  return "briefcase.fill"
        }
    }
}

/// A deep link that opens the app from outside (e.g. tapping a shared community link in
/// Notes/Messages). Set in `onOpenURL`, consumed (and cleared) once the destination screen
/// is ready to navigate — see `AppState.pendingDeepLink`.
enum DeepLink: Equatable {
    case community(id: String)
}

/// Navigation signal set by the in-app AI assistant when it resolves a
/// request to a screen the user should land on. Mirrors `DeepLink`/
/// `pendingDeepLink`'s exact shape — see `AppState.pendingAssistantNavigation`.
/// Each case names the deepest screen reachable via a `NavigationPath` push;
/// three guidance topics land one level deeper still, inside a `.sheet` local
/// to that screen's own `@State` — those set `AppState.pendingAssistantSheet`
/// as a second signal (see below) after the push lands.
enum AssistantNavigationTarget: Equatable {
    case tab(Int)
    case settings
    case privacySecurity
    case blockedUsers
    case notificationSettings
    /// Settings → Privacy & Security, then opens the Change Password sheet.
    case changePassword
    /// Settings → Privacy & Security, then opens the Delete Account sheet.
    case deleteAccount
    /// Profile tab, then opens the Edit Profile sheet.
    case editProfile
}

/// A `.sheet` the assistant wants opened once its `AssistantNavigationTarget`
/// push has landed on that sheet's owning screen — set alongside
/// `pendingAssistantNavigation` for the three destinations that are local
/// `@State` sheets, not `NavigationPath` pushes. Consumed and cleared by the
/// owning view (`PrivacySecurityView`/`ProfileView`) the same way
/// `pendingDeepLink`/`pendingAssistantNavigation` are consumed elsewhere.
enum AssistantSheetTarget: Equatable {
    case changePassword
    case deleteAccount
    case editProfile
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

    /// Localization key — callers must wrap this in `bundle.loc(...)`. This
    /// used to be a bespoke `label(for: AppLanguage)` bilingual switch that
    /// bypassed `.strings` entirely; every call site always passed the
    /// *current* language anyway, so it added a second localization mechanism
    /// for no benefit over the normal one.
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
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
    /// Mode the user wants to switch to but hasn't set up a persona for yet — triggers the
    /// PersonaSetupView sheet; only completing the form actually switches, canceling keeps the old mode
    var pendingPersonaMode: AppMode? = nil
    /// Tapping the "Search" tab again while already on it → SearchView resets to its default browse state
    var shouldResetSearch: Bool = false
    var chatUnreadCount: Int = 0
    /// Unread notifications, shared so the Notifications tab badge and the
    /// notification list can never disagree — reading a row decrements it
    /// immediately instead of waiting for the next fetch.
    var notificationUnreadCount: Int = 0
    /// Deep link waiting to be navigated to — survives both a cold launch (set before
    /// RootView/MainTabView exist) and a warm launch (app already running).
    /// The consuming view reads it and sets it back to `nil` so navigation doesn't repeat.
    var pendingDeepLink: DeepLink? = nil
    /// Navigation set by the AI assistant after resolving a "go to X"/"open
    /// Settings" request — sibling to `pendingDeepLink`, same consume-then-clear
    /// pattern (see `MainTabView.consumePendingAssistantNavigation`).
    var pendingAssistantNavigation: AssistantNavigationTarget? = nil
    /// A sheet the assistant wants opened once its navigation push above has
    /// landed on that sheet's owning screen (see `AssistantSheetTarget`) —
    /// consumed by `PrivacySecurityView`/`ProfileView`, same consume-then-clear
    /// pattern as `pendingDeepLink`.
    var pendingAssistantSheet: AssistantSheetTarget? = nil
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

    /// JWT stored in the Keychain
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
            // Read `postCount` into a local BEFORE assigning — reading and
            // writing `currentUser?.postCount` in the same statement triggers
            // a Swift exclusivity-access crash (overlapping getter/setter
            // access on the @Observable `currentUser` property). Same fix as
            // `ProfileViewModel.removePost`.
            guard let authorId = note.userInfo?["authorId"] as? String,
                  self?.currentUser?.id == authorId,
                  let currentCount = self?.currentUser?.postCount else { return }
            self?.currentUser?.postCount = max(currentCount - 1, 0)
        }

        // Symmetric with the `.postDeleted` observer above — without this,
        // restoring a post (via the Undo toast or Recently Deleted) leaves
        // `currentUser.postCount` permanently one too low, since delete
        // decrements it but nothing was bringing it back up.
        NotificationCenter.default.addObserver(
            forName: .postRestored, object: nil, queue: .main
        ) { [weak self] note in
            guard let post = note.userInfo?["post"] as? Post,
                  self?.currentUser?.id == post.author.id,
                  let currentCount = self?.currentUser?.postCount else { return }
            self?.currentUser?.postCount = currentCount + 1
        }

        // A new post was created — the backend only bumps `users.post_count`
        // for Feed posts (never community posts), so mirror that exactly
        // here: no extra check needed beyond author-id, `.postCreated` is
        // only ever broadcast from Feed's composer.
        NotificationCenter.default.addObserver(
            forName: .postCreated, object: nil, queue: .main
        ) { [weak self] note in
            guard let post = note.userInfo?["post"] as? Post,
                  self?.currentUser?.id == post.author.id,
                  let currentCount = self?.currentUser?.postCount else { return }
            self?.currentUser?.postCount = currentCount + 1
        }
    }


    // ── Auto-login from Keychain ────────────────────────────────────────────────

    func restoreSession() async {
        defer { Task { @MainActor in isCheckingAuth = false } }
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else { return }

        do {
            let user = try await AuthService.shared.fetchMe(token: token)
            if !user.isSetup {
                // Account exists but onboarding was never finished (app was
                // killed or lost connectivity mid-signup). This is a silent,
                // non-interactive restore — not an explicit login — so
                // require a fresh login instead of dropping the user
                // straight back into OnboardingView with a token they
                // never re-entered this launch.
                await MainActor.run { logout() }
                return
            }
            await MainActor.run { finishLogin(token: token, user: user, isNew: false) }
        } catch {
            // Only delete the token when the server explicitly confirms 401 (expired/invalid).
            // A network error or a temporarily-down server → KEEP the token so auto-login
            // still works next launch, instead of forcing the user to log in again for no reason.
            if (error as? URLError)?.code == .userAuthenticationRequired {
                KeychainHelper.delete(forKey: KeychainHelper.tokenKey)
            }
        }
    }

    // ── Login after Google Sign-In ──────────────────────────────────────────────

    func loginWithGoogle(idToken: String) async throws {
        let response = try await AuthService.shared.signInWithGoogle(idToken: idToken)
        KeychainHelper.save(response.token, forKey: KeychainHelper.tokenKey)
        await MainActor.run { finishLogin(token: response.token, user: response.user, isNew: response.isNewUser) }
    }

    // ── Login / register with username + password ─────────────────────────────

    func loginWithPassword(username: String, password: String) async throws {
        let response = try await AuthService.shared.login(username: username, password: password)
        KeychainHelper.save(response.token, forKey: KeychainHelper.tokenKey)
        await MainActor.run { finishLogin(token: response.token, user: response.user, isNew: response.isNewUser) }
    }

    /// Registering also logs the user in right away — is_new_user=true so the root view auto-navigates into onboarding.
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

    // ── Persona per mode ─────────────────────────────────────────────────────

    /// Whether the user has set up a persona (distinct identity) for this mode
    func isPersonaSetup(_ mode: AppMode) -> Bool {
        guard let user = currentUser else { return false }
        return mode == .hobby ? user.hobbySetup : user.workSetup
    }

    /// Every mode change must go through here: if the target mode's persona isn't set up yet →
    /// don't switch, show the persona creation form (PersonaSetupView) first.
    func requestModeSwitch(to mode: AppMode) {
        guard mode != currentMode else { return }
        if isPersonaSetup(mode) {
            currentMode = mode
            persistDefaultMode(mode)
        } else {
            pendingPersonaMode = mode
        }
    }

    /// PersonaSetupView successfully created a persona → update the setup flag,
    /// switch to the new mode and dismiss the sheet.
    func personaCreated(_ user: UserProfile, mode: AppMode) {
        // Keep the existing email/hasPassword — the persona response is a public profile
        if var updated = currentUser {
            updated.hobbySetup = user.hobbySetup
            updated.workSetup  = user.workSetup
            currentUser = updated
        }
        pendingPersonaMode = nil
        currentMode = mode
        persistDefaultMode(mode)
    }

    /// Syncs the switch to the server so it survives the next cold launch —
    /// `restoreSession()` re-derives `currentMode` from the account's
    /// `default_mode` on every launch, so without this a switch reverted
    /// silently. Fire-and-forget: the mode is already switched locally, this
    /// is a background sync, not something the UI should wait on or that
    /// should be able to undo the switch on failure.
    private func persistDefaultMode(_ mode: AppMode) {
        Task<Void, Never>(name: nil) {
            try? await ProfileRepository().updateDefaultMode(mode)
        }
    }

    func logout() {
        KeychainHelper.delete(forKey: KeychainHelper.tokenKey)
        authToken        = nil
        currentUser      = nil
        isLoggedIn       = false
        needsOnboarding  = false
        chatUnreadCount  = 0
        notificationUnreadCount = 0
        WebSocketClient.shared.disconnect()
        // Drop the offline cache so the next account never sees the previous
        // one's feed / chats / notifications.
        CacheStore.shared.wipe()
    }
}
