import SwiftUI

/// Privacy & Security screen. Currently manages the blocked-users list;
/// password change will be added once the full forgot/change-password flow exists.
struct PrivacySecurityView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var showChangePassword = false
    @State private var showDeleteAccount = false
    @State private var friendRequests = FriendRequestSettingViewModel()
    @State private var suggestionVisibility = SuggestionVisibilitySettingViewModel()
    @State private var personaLink = PersonaLinkSettingViewModel()

    private var hasPassword: Bool { appState.currentUser?.hasPassword ?? true }

    private var otherMode: AppMode { appState.currentMode == .hobby ? .work : .hobby }

    var body: some View {
        List {
            // Account security
            Section {
                Button { showChangePassword = true } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(hex: "#FF9500"))
                                .frame(width: 30, height: 30)
                            Image(systemName: "key.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                        }
                        Text(bundle.loc(hasPassword ? "Change password" : "Set password"))
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
            } footer: {
                if !hasPassword {
                    Text("Set a password to also sign in without Google.", bundle: bundle)
                }
            }

            // Who can send friend requests
            Section {
                Toggle(isOn: Binding(
                    get: { appState.currentUser?.allowFriendRequests ?? true },
                    set: { allow in Task { await friendRequests.set(allow, appState: appState) } }
                )) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(themeManager.theme.primary)
                                .frame(width: 30, height: 30)
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                        }
                        Text("Allow friend requests", bundle: bundle)
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
                .tint(themeManager.theme.primary)
                .disabled(friendRequests.isSaving)
            } footer: {
                Text("When off, people who aren't your friends can only follow you. You can still send friend requests yourself.", bundle: bundle)
            }

            // Whether I'm suggested to others
            Section {
                Toggle(isOn: Binding(
                    get: { appState.currentUser?.showInSuggestions ?? true },
                    set: { show in Task { await suggestionVisibility.set(show, appState: appState) } }
                )) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(themeManager.theme.primary)
                                .frame(width: 30, height: 30)
                            Image(systemName: "person.2.wave.2")
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                        }
                        Text("Show me in People you may know", bundle: bundle)
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
                .tint(themeManager.theme.primary)
                .disabled(suggestionVisibility.isSaving)
            } footer: {
                Text("When off, you're never suggested to anyone. You still see suggestions yourself.", bundle: bundle)
            }

            // This mode's profile → my other persona (each mode has its own switch)
            Section {
                Toggle(isOn: Binding(
                    get: { appState.currentUser?.linksOtherMode ?? true },
                    set: { link in Task { await personaLink.set(link, appState: appState) } }
                )) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(themeManager.theme.primary)
                                .frame(width: 30, height: 30)
                            Image(systemName: otherMode.glyph)
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                        }
                        Text(bundle.loc(otherMode == .work ? "Show a link to my Work profile" : "Show a link to my Hobby profile"))
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
                .tint(themeManager.theme.primary)
                .disabled(personaLink.isSaving)
            } footer: {
                Text(bundle.loc(otherMode == .work
                    ? "Shown on your Hobby profile. Your Work profile stays visible to people in Work mode either way."
                    : "Shown on your Work profile. Your Hobby profile stays visible to people in Hobby mode either way."))
            }

            Section {
                NavigationLink {
                    BlockedUsersView()
                        .environment(appState)
                        .environment(themeManager)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(hex: "#E53935"))
                                .frame(width: 30, height: 30)
                            Image(systemName: "nosign")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                        }
                        Text("Blocked users", bundle: bundle)
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
            } footer: {
                Text("People you block can't see your posts or message you.", bundle: bundle)
            }

            // Danger zone
            Section {
                Button(role: .destructive) { showDeleteAccount = true } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.red)
                                .frame(width: 30, height: 30)
                            Image(systemName: "trash.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                        }
                        Text("Delete account", bundle: bundle)
                            .font(.system(size: 16))
                            .foregroundColor(.red)
                    }
                }
            } footer: {
                Text("Your profile will be anonymized and you won't be able to sign in again. Posts and messages you sent will remain, shown as \"Deleted User\".", bundle: bundle)
            }
        }
        .alert(friendRequests.errorMessage ?? "", isPresented: Binding(
            get: { friendRequests.errorMessage != nil },
            set: { if !$0 { friendRequests.errorMessage = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        }
        .alert(suggestionVisibility.errorMessage ?? "", isPresented: Binding(
            get: { suggestionVisibility.errorMessage != nil },
            set: { if !$0 { suggestionVisibility.errorMessage = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        }
        .alert(personaLink.errorMessage ?? "", isPresented: Binding(
            get: { personaLink.errorMessage != nil },
            set: { if !$0 { personaLink.errorMessage = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        }
        .listStyle(.insetGrouped)
        .navigationTitle(bundle.loc("Privacy & Security"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordView(hasPassword: hasPassword)
                .environment(appState)
                .environment(themeManager)
        }
        .sheet(isPresented: $showDeleteAccount) {
            DeleteAccountView(hasPassword: hasPassword)
                .environment(appState)
        }
        .task { consumePendingAssistantSheet() }
        .onChange(of: appState.pendingAssistantSheet) { _, _ in
            consumePendingAssistantSheet()
        }
    }

    /// Opens Change Password / Delete Account when the AI assistant's
    /// guidance action landed here — mirrors the consume-then-clear pattern
    /// `pendingDeepLink`/`pendingAssistantNavigation` use elsewhere.
    private func consumePendingAssistantSheet() {
        switch appState.pendingAssistantSheet {
        case .changePassword:
            appState.pendingAssistantSheet = nil
            showChangePassword = true
        case .deleteAccount:
            appState.pendingAssistantSheet = nil
            showDeleteAccount = true
        case .editProfile, nil:
            break
        }
    }
}
