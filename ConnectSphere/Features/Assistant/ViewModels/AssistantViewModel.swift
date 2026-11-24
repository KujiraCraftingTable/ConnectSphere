import Foundation
import Observation

/// Backs `AssistantChatView`: runs `AssistantMatcher` on each user message,
/// then either executes the resolved intent directly against `AppState`
/// (theme/language/mode/navigation/settings) or appends a guidance reply.
/// Logging out is the one exception to "just do it", it appends a message
/// with inline Yes/No buttons instead of auto-executing (see `confirmLogout`).
///
/// Takes `AppState` as an init dependency (mirrors how other feature views,
/// e.g. `CommunityDetailViewModel`, take their concrete dependencies via
/// init rather than the ViewModel reading `@Environment` itself, since plain
/// `@Observable` classes aren't SwiftUI views and can't use `@Environment`).
/// `AssistantChatView` reads `AppState`/`ThemeManager` via `@Environment` and
/// passes them down at construction time.
@MainActor
@Observable
final class AssistantViewModel {
    var messages: [AssistantMessage] = []

    private let appState: AppState
    private let themeManager: ThemeManager
    /// Saves a theme colour to the account, the same way the picker does.
    private let themePicker = ThemePickerViewModel()
    private var defaults: UserDefaults { AppDefaults.store }
    private let messageRepository = MessageRepository()
    /// How many recent chats to offer.
    private let chatChoiceLimit = 5
    /// What was last typed, for suggesting near topics when nothing matched.
    private var lastInput = ""

    init(appState: AppState, themeManager: ThemeManager) {
        self.appState = appState
        self.themeManager = themeManager
    }

    /// Localized bundle for the app's *current* language. Read fresh each
    /// time so a language switch mid-conversation is reflected immediately.
    private var bundle: Foundation.Bundle { appState.bundle }

    // MARK: - Send

    /// Runs the matcher on `text`, appends the user's message, then handles
    /// the resolved intent.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        appendUserMessage(trimmed)
        lastInput = trimmed

        // Commands with a value ("search radius 10 km") come first; the
        // phrase matcher only knows fixed phrases.
        if let intent = AssistantSettingParser.parse(trimmed) {
            execute(intent)
            return
        }

        let match = AssistantMatcher.match(trimmed)

        // The phrase matched, but it reads as incidental to a longer sentence.
        // Ask rather than silently act. The cost of guessing wrong here is
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
        case .changeSetting(let change): handleChange(change)
        case .howTo(let topic):          handleGuidance(topic)
        case .unknown:                   handleUnknown()
        }
    }

    /// Clears the conversation. Reachable from the sheet's Clear button,
    /// needed now that history survives dismissal.
    func clearConversation() {
        messages.removeAll()
    }

    // MARK: - Logout confirmation (view calls these from the Yes/No buttons)

    /// User tapped "Yes" on a logout-confirm bubble. Only now does the
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

    /// User confirmed a match the matcher wasn't sure about. Run it now.
    func confirmIntent(_ intent: AssistantIntent, messageId: String) {
        clearAction(for: messageId)
        execute(intent)
    }

    /// User tapped one of the topics suggested after an unmatched message.
    func showTopic(_ topic: AssistantGuidanceTopic, messageId: String) {
        clearAction(for: messageId)
        appendUserMessage(bundle.loc(topic.titleKey))
        handleGuidance(topic)
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
        case .changeSetting:
            return bundle.loc("change that setting")
        case .logout, .howTo, .unknown:
            return nil
        }
    }

    // MARK: - Executable handlers

    private func handleSetTheme(_ mode: AppearanceMode) {
        let previous = appState.appearanceMode
        appState.appearanceMode = mode
        let name = bundle.loc(mode.label)
        appendAssistantMessage(String(format: bundle.loc("Done. Theme switched to %@."), name),
                               action: previous == mode ? nil : .undo(.setTheme(previous)))
    }

    private func handleSetLanguage(_ language: AppLanguage) {
        appState.appLanguage = language
        // Read the reply in the *new* language. Bundle is computed live from appState.appLanguage.
        appendAssistantMessage(String(format: bundle.loc("Done. Language switched to %@."), language.displayName))
    }

    /// Mode switching has a wrinkle: `AppState.requestModeSwitch(to:)` pops a
    /// persona-setup sheet instead of switching when the target persona
    /// isn't set up yet, and this view is itself presented as a sheet, so
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
            appendAssistantMessage(String(format: bundle.loc("Done. Switched to %@."), modeLabel(mode)))
        } else {
            let text = String(format: bundle.loc("You haven't set up your %@ yet. Open Settings and tap that mode to create it first."), modeLabel(mode))
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

    // MARK: - Safe settings

    /// Applies a change and offers Undo, unless nothing changed.
    private func handleChange(_ change: AssistantSettingChange) {
        if case .themeColor(let id) = change, !ThemeManager.isKnown(id, mode: appState.currentMode) {
            let names = (appState.currentMode == .hobby ? ThemePalette.socialPalettes : ThemePalette.workPalettes)
                .map(\.name).joined(separator: ", ")
            appendAssistantMessage(String(format: bundle.loc("That colour isn't available in this mode. Try one of: %@."), names))
            return
        }
        let previous = current(of: change)
        guard previous != change else {
            appendAssistantMessage(bundle.loc("That's already set."))
            return
        }
        apply(change)
        appendAssistantMessage(reply(for: change), action: .undo(.changeSetting(previous)))
    }

    /// User tapped Undo: put the old value back and say what it is now, so
    /// the reply makes sense wherever it lands in the conversation.
    func undo(_ intent: AssistantIntent, messageId: String) {
        clearAction(for: messageId)
        let now: String
        switch intent {
        case .setTheme(let mode):
            appState.appearanceMode = mode
            now = String(format: bundle.loc("Theme is %@."), bundle.loc(mode.label))
        case .changeSetting(let change):
            apply(change)
            now = reply(for: change)
        default:
            return
        }
        appendAssistantMessage(String(format: bundle.loc("Changed back. %@"), now))
    }

    /// The setting's value now, in the same shape as `change`.
    private func current(of change: AssistantSettingChange) -> AssistantSettingChange {
        switch change {
        case .messageSounds:
            return .messageSounds(defaults.object(forKey: "messageSoundEnabled") as? Bool ?? true)
        case .aiSuggestions:
            return .aiSuggestions(defaults.object(forKey: "aiSuggestionNotifsEnabled") as? Bool ?? true)
        case .translations:
            let raw = defaults.string(forKey: TranslationMode.storageKey) ?? ""
            return .translations(TranslationMode(rawValue: raw) ?? .original)
        case .searchRadius:
            return .searchRadius(defaults.integer(forKey: "searchRadiusKm"))
        case .themeColor:
            return .themeColor(themeManager.paletteId(for: appState.currentMode))
        case .appIcon:
            return .appIcon(appState.appIconId)
        }
    }

    /// Writes the value where its Settings screen reads it, so the screen
    /// shows the change as soon as it's opened.
    private func apply(_ change: AssistantSettingChange) {
        switch change {
        case .messageSounds(let on):   defaults.set(on, forKey: "messageSoundEnabled")
        case .aiSuggestions(let on):   defaults.set(on, forKey: "aiSuggestionNotifsEnabled")
        case .translations(let mode):  defaults.set(mode.rawValue, forKey: TranslationMode.storageKey)
        case .searchRadius(let km):    defaults.set(km, forKey: "searchRadiusKm")
        case .appIcon(let id):         appState.selectAppIcon(id)
        case .themeColor(let id):
            let mode = appState.currentMode
            Task {
                await themePicker.select(id, mode: mode, themeManager: themeManager)
                // Saving failed and the picker put the old colour back.
                if let error = themePicker.errorMessage {
                    themePicker.errorMessage = nil
                    appendAssistantMessage(error)
                }
            }
        }
    }

    private func reply(for change: AssistantSettingChange) -> String {
        switch change {
        case .messageSounds(let on):
            return bundle.loc(on ? "Message sounds are on." : "Message sounds are off.")
        case .aiSuggestions(let on):
            return bundle.loc(on ? "AI post suggestions are on." : "AI post suggestions are off.")
        case .translations(let mode):
            return bundle.loc(mode == .translated
                ? "Posts in the other language now show their translation first."
                : "Posts now show in their original language.")
        case .searchRadius(let km):
            return km == 0
                ? bundle.loc("Search now has no distance limit.")
                : String(format: bundle.loc("Search now looks within %d km of your ward."), km)
        case .themeColor(let id):
            return String(format: bundle.loc("Theme colour changed to %@."), paletteName(id))
        case .appIcon(let id):
            return String(format: bundle.loc("App icon changed to %@."), paletteName(id))
        }
    }

    private func paletteName(_ id: String) -> String {
        AssistantSettingParser.palettes.first { $0.id == id }?.name ?? id
    }

    // MARK: - Guidance handler

    private func handleGuidance(_ topic: AssistantGuidanceTopic) {
        // Someone who signed up with Google has "Set password", not "Change".
        let key = topic == .changePassword && appState.currentUser?.hasPassword == false
            ? AssistantGuidanceTopic.setPasswordMessageKey
            : topic.messageKey
        if let filter = topic.chatPicker {
            appendAssistantMessage(bundle.loc(key))
            Task { await offerChats(filter) }
            return
        }
        appendAssistantMessage(bundle.loc(key), action: topic.navigationTarget.map { .navigate($0) })
    }

    /// Lists recent chats in this mode so one tap opens the right chat's
    /// settings. Without a token, chats or a connection it points to Home.
    private func offerChats(_ filter: AssistantChatFilter) async {
        guard let token = appState.authToken else { return }
        let chats = (try? await messageRepository.fetchConversations(mode: appState.currentMode.rawValue, token: token)) ?? []
        let choices = chats
            .filter { !$0.isArchived && (filter == .all || $0.isGroup) }
            .prefix(chatChoiceLimit)
            .map { AssistantChatTarget(conversationId: $0.id, peer: ChatPeer($0)) }
        guard !choices.isEmpty else {
            let none = filter == .groups ? "You don't have any group chats yet." : "You don't have any chats yet."
            appendAssistantMessage(bundle.loc(none), action: .navigate(.tab(0)))
            return
        }
        appendAssistantMessage(bundle.loc("Pick a chat to open its settings."), action: .pickChat(Array(choices)))
    }

    // MARK: - Fallback

    private func handleUnknown() {
        // A shared word is a better hint than generic examples.
        let near = AssistantMatcher.closestTopics(lastInput)
        if !near.isEmpty {
            appendAssistantMessage(bundle.loc("I'm not sure what you mean. Is it one of these?"),
                                   action: .suggestTopics(near))
            return
        }
        // Reuses the same localized labels shown as suggestion chips in the
        // empty state, so the example phrasing is in the user's current
        // language rather than always English.
        let examples = [
            "\"\(bundle.loc("Switch to dark mode"))\"",
            "\"\(bundle.loc("Go to settings"))\"",
            "\"\(bundle.loc("How do I change my password?"))\""
        ].joined(separator: ", ")
        let text = String(
            format: bundle.loc("I didn't quite catch that. Try asking about theme, language, mode, or where to find something, for example: %@."),
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
