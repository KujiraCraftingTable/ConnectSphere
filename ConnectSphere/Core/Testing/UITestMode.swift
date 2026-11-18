import SwiftUI

/// How the XCUITest suite (`ConnectSphereUITests`) runs the app. Debug builds
/// only; in Release `isActive` is always false and nothing here does anything.
///
/// The suite runs on the same simulator the developer is signed in on, so a
/// test run keeps its own Keychain service, defaults suite and in-memory
/// cache instead of wiping the real ones.
///
/// Launch arguments:
/// - `-uiTesting`: turn test mode on.
/// - `-uiTestingReset`: start signed out, with empty test storage.
/// - `-uiTestingServer <url>`: the server to talk to (the UI-test server on :3001).
/// - `-uiTestingToken <jwt>`: start signed in as that account.
enum UITestMode {
    #if DEBUG
    static let isActive = arguments.contains("-uiTesting")
    #else
    static let isActive = false
    #endif

    static var serverOverride: String? { isActive ? value(after: "-uiTestingServer") : nil }

    private static let arguments = ProcessInfo.processInfo.arguments

    private static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
        let value = arguments[i + 1]
        return value.isEmpty || value.hasPrefix("-") ? nil : value
    }

    static let keychainService = "com.connectsphere.app.uitest"
    static let defaultsSuite = "ConnectSphere.UITest"

    /// Runs once, from `ConnectSphereApp.init`, before `restoreSession()`
    /// reads the Keychain.
    static func prepare() {
        guard isActive else { return }
        if arguments.contains("-uiTestingReset") {
            KeychainHelper.delete(forKey: KeychainHelper.tokenKey)
        }
        if let token = value(after: "-uiTestingToken") {
            KeychainHelper.save(token, forKey: KeychainHelper.tokenKey)
        }
        // Waiting on an element is reliable; waiting out an animation is not.
        UIView.setAnimationsEnabled(false)
    }

    /// Test-mode defaults: a fresh suite on reset, English, no translation,
    /// so tests can find controls by their English text.
    static func makeDefaults() -> UserDefaults {
        guard isActive, let suite = UserDefaults(suiteName: defaultsSuite) else { return .standard }
        if arguments.contains("-uiTestingReset") { suite.removePersistentDomain(forName: defaultsSuite) }
        suite.set(AppLanguage.english.rawValue, forKey: "appLanguage")
        suite.set(TranslationMode.original.rawValue, forKey: TranslationMode.storageKey)
        return suite
    }
}

/// The app's `UserDefaults`. Always `.standard`, except under the UI tests,
/// which get a suite of their own (`UITestMode`) so a test run never touches
/// the developer's saved accounts, theme or settings. Use it everywhere
/// instead of `UserDefaults.standard`, and as `@AppStorage(…, store:)`.
enum AppDefaults {
    static let store: UserDefaults = UITestMode.makeDefaults()
}

extension View {
    /// `accessibilityIdentifier`, skipped when there's no id (shared
    /// components that only some screens tag).
    @ViewBuilder
    func axID(_ id: String?) -> some View {
        if let id { accessibilityIdentifier(id) } else { self }
    }
}
