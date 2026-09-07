import Foundation
import Observation

/// Backs `AssistantChatView`: runs `AssistantMatcher` on each user message,
/// then either executes the resolved intent directly against `AppState`
/// (theme/language/mode/navigation/settings) or appends a guidance reply.
/// Logging out is the one exception to "just do it" — it appends a message
/// with inline Yes/No buttons instead of auto-executing (see `confirmLogout`).
///
/// Takes `AppState` as an init dependency (mirrors how other feature views —
/// e.g. `CommunityDetailViewModel` — take their concrete dependencies via
/// init rather than the ViewModel reading `@Environment` itself, since plain
/// `@Observable` classes aren't SwiftUI views and can't use `@Environment`).
/// `AssistantChatView` reads `AppState`/`ThemeManager` via `@Environment` and
/// passes them down at construction time.
@MainActor
@Observable
final class AssistantViewModel {
    var messages: [AssistantMessage] = []

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Localized bundle for the app's *current* language — read fresh each
    /// time so a language switch mid-conversation is reflected immediately.
    private var bundle: Foundation.Bundle { appState.bundle }

    // MARK: - Send

    /// Runs the matcher on `text`, appends the user's message, then handles
    /// the resolved intent.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        appendUserMessage(trimmed)

        let match = AssistantMatcher.match(trimmed)

        // The phrase matched, but it reads as incidental to a longer sentence.
        // Ask rather than silently act — the cost of guessing wrong here is
        // changing a setting the user never asked to change.
        guard match.isConfident else {
            askToConfirm(match.intent)
            return
        }

        execute(match.intent)
    }

    /// Runs a resolved intent. Split out from `send` so a confirmed
    /// low-confidence match can reuse exactly the same execution path.
    private func execute(_ intent: AssistantIntent) {
        switch intent {
        case .setTheme(let mode):        handleSetTheme(mode)
        case .setLanguage(let language): handleSetLanguage(language)
        case .switchMode(let mode):      handleSwitchMode(mode)
        case .navigateTab(let index):    handleNavigateTab(index)
        case .openSettings:              handleOpenSettings()
        case .logout:                    handleLogoutRequest()
        case .howTo(let topic):          handleGuidance(topic)
        case .unknown:                   handleUnknown()
        }
    }

    /// Clears the conversation. Reachable from the sheet's Clear button —
    /// needed now that history survives dismissal.
    func clearConversation() {
        messages.removeAll()
    }

    // MARK: - Logout confirmation (view calls these from the Yes/No buttons)

    /// User tapped "Yes" on a logout-confirm bubble — only now does the
    /// actual logout happen.
    func confirmLogout(messageId: String) {
        clearAction(for: messageId)
        appState.logout()
        appendAssistantMessage(bundle.loc("You've been logged out."))
    }

    /// User tapped "Cancel" on a logout-confirm bubble.
    func cancelLogout(messageId: String) {
        clearAction(for: messageId)
        appendAssistantMessage(bundle.loc("Okay, staying logged in."))
    }

    // MARK: - Low-confidence confirmation

    /// User confirmed a match the matcher wasn't sure about — run it now.
    func confirmIntent(_ intent: AssistantIntent, messageId: String) {
        clearAction(for: messageId)
        execute(intent)
    }

    /// User rejected a low-confidence match.
    func cancelIntent(messageId: String) {
        clearAction(for: messageId)
        appendAssistantMessage(bundle.loc("Okay, I won't change anything."))
    }

    /// Asks before acting on a phrase that looked incidental rather than
    /// commanded. `.logout` already has its own confirmation bubble, so it
    /// routes straight there instead of asking twice.
    private func askToConfirm(_ intent: AssistantIntent) {
        guard intent != .logout else {
            handleLogoutRequest()
            return
        }
        guard let description = confirmationDescription(intent) else {
            handleUnknown()
            return
        }
        appendAssistantMessage(
            String(format: bundle.loc("Did you want me to %@?"), description),
            action: .confirmIntent(intent)
        )
    }

    /// Human-readable description of what an intent would do, for the
    /// confirmation prompt. Nil for intents that never need confirming.
    private func confirmationDescription(_ intent: AssistantIntent) -> String? {
        switch intent {
        case .setTheme(let mode):
            return String(format: bundle.loc("switch the theme to %@"), bundle.loc(mode.label))
        case .setLanguage(let language):
            return String(format: bundle.loc("switch the language to %@"), language.displayName)
        case .switchMode(let mode):
            return String(format: bundle.loc("switch to %@"), modeLabel(mode))
        case .navigateTab(let index):
            return String(format: bundle.loc("open %@"), tabName(index))
        case .openSettings:
            return bundle.loc("open Settings")
        case .logout, .howTo, .unknown:
            return nil
        }
    }

    // MARK: - Executable handlers

    private func handleSetTheme(_ mode: AppearanceMode) {
        appState.appearanceMode = mode
        let name = bundle.loc(mode.label)
        appendAssistantMessage(String(format: bundle.loc("Done — theme switched to %@."), name))
    }

    private func handleSetLanguage(_ language: AppLanguage) {
        appState.appLanguage = language
        // Read the reply in the *new* language — bundle is computed live from appState.appLanguage.
        appendAssistantMessage(String(format: bundle.loc("Done — language switched to %@."), language.displayName))
    }

    /// Mode switching has a wrinkle: `AppState.requestModeSwitch(to:)` pops a
    /// persona-setup sheet instead of switching when the target persona
    /// isn't set up yet — and this view is itself presented as a sheet, so
    /// triggering a second sheet on top of it here would conflict. Instead,
    /// when the persona isn't set up, this stays a graceful guidance-style
    /// reply pointing at Settings (where tapping the mode pill properly
    /// triggers persona setup once this sheet is dismissed via "Take me there").
    private func handleSwitchMode(_ mode: AppMode) {
        guard mode != appState.currentMode else {
            appendAssistantMessage(String(format: bundle.loc("You're already in %@."), modeLabel(mode)))
            return
        }
        if appState.isPersonaSetup(mode) {
            appState.requestModeSwitch(to: mode)
            appendAssistantMessage(String(format: bundle.loc("Done — switched to %@."), modeLabel(mode)))
        } else {
            let text = String(format: bundle.loc("You haven't set up your %@ yet — open Settings and tap that mode to create it first."), modeLabel(mode))
            appendAssistantMessage(text, action: .navigate(.settings))
        }
    }

    private func handleNavigateTab(_ index: Int) {
        appendAssistantMessage(String(format: bundle.loc("Taking you to %@."), tabName(index)), action: .navigate(.tab(index)))
        appState.pendingAssistantNavigation = .tab(index)
    }

    private func handleOpenSettings() {
        appendAssistantMessage(bundle.loc("Taking you to Settings."), action: .navigate(.settings))
        appState.pendingAssistantNavigation = .settings
    }

    private func handleLogoutRequest() {
        appendAssistantMessage(bundle.loc("Are you sure you want to log out?"), action: .confirmLogout)
    }

    // MARK: - Guidance handler

    private func handleGuidance(_ topic: AssistantGuidanceTopic) {
        appendAssistantMessage(bundle.loc(topic.messageKey), action: .navigate(topic.navigationTarget))
    }

    // MARK: - Fallback

    private func handleUnknown() {
        // Reuses the same localized labels shown as suggestion chips in the
        // empty state, so the example phrasing is in the user's current
        // language rather than always English.
        let examples = [
            "\"\(bundle.loc("Switch to dark mode"))\"",
            "\"\(bundle.loc("Go to settings"))\"",
            "\"\(bundle.loc("How do I change my password?"))\""
        ].joined(separator: ", ")
        let text = String(
            format: bundle.loc("I didn't quite catch that. Try asking about theme, language, mode, or where to find something — for example: %@."),
            examples
        )
        appendAssistantMessage(text)
    }

    // MARK: - Helpers

    private func modeLabel(_ mode: AppMode) -> String {
        switch mode {
        case .hobby: return bundle.loc("Hobby Mode")
        case .work:  return bundle.loc("Work Mode")
        }
    }

    private func tabName(_ index: Int) -> String {
        switch index {
        case 0:  return bundle.loc("Home")
        case 1:  return bundle.loc("Search")
        case 2:  return bundle.loc("Community")
        case 3:  return bundle.loc("Notifications")
        case 4:  return bundle.loc("Profile")
        default: return bundle.loc("Settings")
        }
    }

    private func appendUserMessage(_ text: String) {
        messages.append(AssistantMessage(text: text, isFromUser: true))
    }

    private func appendAssistantMessage(_ text: String, action: AssistantMessageAction? = nil) {
        messages.append(AssistantMessage(text: text, isFromUser: false, action: action))
    }

    /// Clears a message's inline action after it's been acted on (prevents
    /// re-tapping a stale logout confirmation).
    private func clearAction(for messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[index].action = nil
    }
}
