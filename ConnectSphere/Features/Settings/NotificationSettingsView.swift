import SwiftUI

/// Cài đặt thông báo trong app — chỉ gồm những tuỳ chọn có tác dụng thật.
/// Push khi app đóng (APNs) sẽ bổ sung ở bản sau.
struct NotificationSettingsView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle

    /// Đọc bởi ChatView.playMessageSound
    @AppStorage("messageSoundEnabled") private var messageSoundEnabled = true
    /// Đọc bởi CreatePostViewModel.checkAndNotifyMismatch
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
