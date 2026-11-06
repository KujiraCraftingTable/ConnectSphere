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
/// is ready to navigate. See `AppState.pendingDeepLink`.
enum DeepLink: Equatable {
    case community(id: String)
}

/// Navigation signal set by the in-app AI assistant when it resolves a
/// request to a screen the user should land on. Mirrors `DeepLink`/
/// `pendingDeepLink`'s exact shape. See `AppState.pendingAssistantNavigation`.
/// Each case names the deepest screen reachable via a `NavigationPath` push;
/// three guidance topics land one level deeper still, inside a `.sheet` local
/// to that screen's own `@State`. Those set `AppState.pendingAssistantSheet`
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
/// push has landed on that sheet's owning screen. Set alongside
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

    /// Localization key, callers must wrap this in `bundle.loc(...)`. This
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
    /// The account hasn't agreed to the current Terms and Privacy Policy yet.
    var needsConsent: Bool = false
    var isCheckingAuth:  Bool = true   // splash while checking Keychain
    var currentMode:  AppMode = .hobby
    var currentUser:  UserProfile? = nil
    /// Mode the user wants to switch to but hasn't set up a persona for yet. Triggers the
    /// PersonaSetupView sheet; only completing the form actually switches, canceling keeps the old mode
    var pendingPersonaMode: AppMode? = nil
    /// Tapping the "Search" tab again while already on it → SearchView resets to its default browse state
    var shouldResetSearch: Bool = false
    /// Home tab re-tapped: the feed scrolls to the top and reloads.
    var shouldResetFeed: Bool = false
    var chatUnreadCount: Int = 0
    /// Unread notifications, shared so the Notifications tab badge and the
    /// notification list can never disagree. Reading a row decrements it
    /// immediately instead of waiting for the next fetch.
    var notificationUnreadCount: Int = 0
    /// Deep link waiting to be navigated to. Survives both a cold launch (set before
    /// RootView/MainTabView exist) and a warm launch (app already running).
    /// The consuming view reads it and sets it back to `nil` so navigation doesn't repeat.
    var pendingDeepLink: DeepLink? = nil
    /// Navigation set by the AI assistant after resolving a "go to X"/"open
    /// Settings" request, sibling to `pendingDeepLink`, same consume-then-clear
    /// pattern (see `MainTabView.consumePendingAssistantNavigation`).
    var pendingAssistantNavigation: AssistantNavigationTarget? = nil
    /// A sheet the assistant wants opened once its navigation push above has
    /// landed on that sheet's owning screen (see `AssistantSheetTarget`),
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

        // Posts made, deleted or restored change the profile's count, but
        // only some of them count (this mode's own posts, never one made in a
        // community), so the number is asked of the server instead of nudged
        // by one here.
        for name in [Notification.Name.postDeleted, .postRestored, .postCreated] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshPostCount()
            }
        }
    }

    /// This persona's post count, as the server counts it.
    private func refreshPostCount() {
        guard let token = authToken else { return }
        let mode = currentMode
        Task { [weak self] in
            guard let user = try? await AuthService.shared.fetchMe(token: token, mode: mode, cacheFallback: false) else { return }
            await MainActor.run {
                guard let self, self.currentMode == mode else { return }
                self.currentUser?.postCount = user.postCount
            }
        }
    }


    // ── Auto-login from Keychain ────────────────────────────────────────────────

    func restoreSession() async {
        defer { Task { @MainActor in isCheckingAuth = false } }
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else { return }

        // Open straight from the last-known profile and check with the server
        // behind it, so a slow or busy server never holds the splash.
        if let cached = AuthService.shared.cachedMe(), cached.isSetup {
            await MainActor.run { finishLogin(token: token, user: cached, isNew: false) }
            Task { await refreshSession(token: token) }
            return
        }

        do {
            let user = try await AuthService.shared.fetchMe(token: token)
            if !user.isSetup {
                // Account exists but onboarding was never finished (app was
                // killed or lost connectivity mid-signup). This is a silent,
                // non-interactive restore, not an explicit login, so
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

    /// The server's word on a session opened from the cache: a fresh
    /// profile, or a sign-out when the token is no longer valid. The mode
    /// the person may already have switched to is kept.
    private func refreshSession(token: String) async {
        do {
            let user = try await AuthService.shared.fetchMe(token: token, cacheFallback: false)
            await MainActor.run {
                guard authToken == token else { return }
                if user.isSetup { currentUser = user.toUserProfile() } else { logout() }
            }
        } catch {
            guard (error as? URLError)?.code == .userAuthenticationRequired else { return }
            KeychainHelper.delete(forKey: KeychainHelper.tokenKey)
            await MainActor.run { if authToken == token { logout() } }
        }
    }

    // ── Login after Google Sign-In ──────────────────────────────────────────────

    /// Signed in, or (two-factor on) waiting for the emailed code.
    enum SignInOutcome: Equatable {
        case signedIn
        case needsCode(LoginChallenge)
    }

    private func handle(_ result: LoginResult) -> SignInOutcome {
        switch result {
        case .signedIn(let response):
            KeychainHelper.save(response.token, forKey: KeychainHelper.tokenKey)
            finishLogin(token: response.token, user: response.user, isNew: response.isNewUser)
            return .signedIn
        case .needsCode(let challenge):
            return .needsCode(challenge)
        }
    }

    func loginWithGoogle(idToken: String) async throws -> SignInOutcome {
        handle(try await AuthService.shared.signInWithGoogle(idToken: idToken))
    }

    /// The second step of a two-factor sign-in.
    func verifyLogin(challenge: String, code: String) async throws {
        let response = try await AuthService.shared.verifyLogin(challenge: challenge, code: code)
        _ = handle(.signedIn(response))
    }

    // ── Login / register with username (or email) + password ──────────────────

    func loginWithPassword(identifier: String, password: String) async throws -> SignInOutcome {
        handle(try await AuthService.shared.login(identifier: identifier, password: password))
    }

    /// Registering also logs the user in right away, is_new_user=true so the root view auto-navigates into onboarding.
    /// The end of a manual sign-up: the account is created, already set up.
    func registerAndSetUp(_ signup: PendingSignup, form: OnboardingForm) async throws {
        let response = try await AuthService.shared.register(signup, form: form)
        KeychainHelper.save(response.token, forKey: KeychainHelper.tokenKey)
        finishLogin(token: response.token, user: response.user, isNew: response.isNewUser)
    }

    func completeOnboarding(form: OnboardingForm) async throws {
        guard let token = authToken else { return }
        let user = try await AuthService.shared.setup(token: token, form: form)
        await MainActor.run {
            currentUser     = user.toUserProfile()
            needsOnboarding = false
            // The username is only final once onboarding is done.
            rememberAccount()
        }
    }

    private func finishLogin(token: String, user: AuthUserDTO, isNew: Bool) {
        authToken       = token
        currentUser     = user.toUserProfile()
        currentMode     = AppMode(rawValue: user.defaultMode) ?? .hobby
        isLoggedIn      = true
        needsOnboarding = isNew || !user.isSetup
        if !needsOnboarding { rememberAccount() }
    }

    /// Offers this account on the login screen next time (see SavedAccounts).
    private func rememberAccount() {
        guard let user = currentUser, !user.username.isEmpty else { return }
        SavedAccounts().remember(SavedAccount(
            id: user.id, username: user.username, displayName: user.name,
            avatarUrl: user.avatarUrl, avatarColor: user.avatarColor,
            hasPassword: user.hasPassword, lastUsed: Date()), googleHint: user.email)
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
            refreshPersona(for: mode)
        } else {
            pendingPersonaMode = mode
        }
    }

    /// PersonaSetupView successfully created a persona → update the setup flag,
    /// switch to the new mode and dismiss the sheet.
    func personaCreated(_ user: UserProfile, mode: AppMode) {
        // Keep the existing email/hasPassword. The persona response is a public profile
        if var updated = currentUser {
            updated.hobbySetup = user.hobbySetup
            updated.workSetup  = user.workSetup
            currentUser = updated
        }
        pendingPersonaMode = nil
        currentMode = mode
        persistDefaultMode(mode)
        refreshPersona(for: mode)
    }

    /// A persona was deleted (the account and the other persona stay): move
    /// to the remaining mode and load its persona.
    func personaDeleted(_ mode: AppMode, remaining: AppMode) {
        if mode == .hobby { currentUser?.hobbySetup = false } else { currentUser?.workSetup = false }
        currentMode = remaining
        refreshPersona(for: remaining)
    }

    /// The account is gone: forget it on this device and sign out.
    func accountDeleted() {
        if let id = currentUser?.id { SavedAccounts().forget(id: id) }
        logout()
    }

    /// `currentUser` is loaded for the mode the app opened in, and Edit
    /// profile, the composer, the Apply sheet… all read "me" from it, so a
    /// switch must swap in the other persona's name, bio, photos and
    /// skills / interests, or they keep showing the old one until a relaunch.
    private func refreshPersona(for mode: AppMode) {
        guard let token = authToken, let id = currentUser?.id else { return }
        Task {
            guard let user = try? await AuthService.shared.fetchMe(token: token, mode: mode),
                  // A newer switch (or a logout) wins over this answer.
                  currentMode == mode, currentUser?.id == id else { return }
            currentUser = user.toUserProfile()
        }
    }

    /// Syncs the switch to the server so it survives the next cold launch,
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

    /// Asks the server whether this account has agreed to the current Terms and
    /// Privacy Policy. Offline or on a server error the app stays open, the
    /// check runs again next launch.
    func refreshConsent() async {
        guard let token = authToken, isLoggedIn, !needsOnboarding else { return }
        guard let status = try? await AuthService.shared.consentStatus(token: token) else { return }
        needsConsent = !status.accepted
    }

    func logout() {
        KeychainHelper.delete(forKey: KeychainHelper.tokenKey)
        needsConsent     = false
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
