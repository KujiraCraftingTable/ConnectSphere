import SwiftUI

/// In-app notification settings — only includes options that actually have an effect.
/// Push notifications while the app is closed (APNs) will be added in a later build.
struct NotificationSettingsView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle

    /// Read by ChatView.playMessageSound
    @AppStorage("messageSoundEnabled") private var messageSoundEnabled = true
    /// Read by CreatePostViewModel.checkAndNotifyMismatch
    @AppStorage("aiSuggestionNotifsEnabled") private var aiSuggestionNotifsEnabled = true

    var body: some View {
        List {
            Section {
                Toggle(bundle.loc("Message sounds"), isOn: $messageSoundEnabled)
                    .tint(themeManager.theme.primary)
            } footer: {
                Text("Play a sound for new messages in an open chat.", bundle: bundle)
            }

            Section {
                Toggle(bundle.loc("AI post suggestions"), isOn: $aiSuggestionNotifsEnabled)
                    .tint(themeManager.theme.primary)
            } footer: {
                Text("Notify when AI suggests a better mode for your post.", bundle: bundle)
            }

            Section {
            } footer: {
                Text("Push notifications while the app is closed will arrive in a future update.", bundle: bundle)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(bundle.loc("Notifications"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
