import SwiftUI

/// Privacy & Security screen. Currently manages the blocked-users list;
/// password change will be added once the full forgot/change-password flow exists.
struct PrivacySecurityView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var showChangePassword = false
    @State private var showManageAccount = false
    @State private var friendRequests = FriendRequestSettingViewModel()
    @State private var suggestionVisibility = SuggestionVisibilitySettingViewModel()
    @State private var personaLink = PersonaLinkSettingViewModel()
    @State private var profileLock = ProfileLockSettingViewModel()
    @State private var confirmLock = false
    @State private var twoFactorChange: Bool?

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
                                .scaledFont(14)
                                .foregroundColor(.white)
                        }
                        Text(bundle.loc(hasPassword ? "Change password" : "Set password"))
                            .scaledFont(16)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .scaledFont(13)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
            } footer: {
                if !hasPassword {
                    Text("Set a password so you can also sign in with your username and password, not only with Google.", bundle: bundle)
                }
            }

            // Who can send friend requests
            Section {
                SettingToggleRow(isOn: Binding(
                    get: { appState.currentUser?.allowFriendRequests ?? true },
                    set: { allow in Task { await friendRequests.set(allow, appState: appState) } }
                )) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(themeManager.theme.primary)
                                .frame(width: 30, height: 30)
                            Image(systemName: "person.badge.plus")
                                .scaledFont(14)
                                .foregroundColor(.white)
                        }
                        Text("Allow friend requests", bundle: bundle)
                            .scaledFont(16)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
                .disabled(friendRequests.isSaving)
            } footer: {
                Text("When off, people who aren't your friends can only follow you. You can still send friend requests yourself.", bundle: bundle)
            }

            // Whether I'm suggested to others
            Section {
                SettingToggleRow(isOn: Binding(
                    get: { appState.currentUser?.showInSuggestions ?? true },
                    set: { show in Task { await suggestionVisibility.set(show, appState: appState) } }
                )) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(themeManager.theme.primary)
                                .frame(width: 30, height: 30)
                            Image(systemName: "person.2.wave.2")
                                .scaledFont(13)
                                .foregroundColor(.white)
                        }
                        Text("Show me in People you may know", bundle: bundle)
                            .scaledFont(16)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
                .disabled(suggestionVisibility.isSaving)
            } footer: {
                Text("When off, you're never suggested to anyone. You still see suggestions yourself.", bundle: bundle)
            }

            // Two-factor sign-in: a code by email every time
            Section {
                SettingToggleRow(isOn: Binding(
                    get: { appState.currentUser?.twoFactorEnabled ?? false },
                    set: { twoFactorChange = $0 }
                )) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(hex: "#3949AB"))
                                .frame(width: 30, height: 30)
                            Image(systemName: "lock.shield.fill")
                                .scaledFont(13)
                                .foregroundColor(.white)
                        }
                        Text("Two-factor authentication", bundle: bundle)
                            .scaledFont(16)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
                .disabled(!(appState.currentUser?.emailVerified ?? false))
            } footer: {
                Text(bundle.loc((appState.currentUser?.emailVerified ?? false)
                    ? "When on, every sign-in needs a code sent to your email. You're also emailed each time your account is signed in to."
                    : "Add and verify an email first, in Manage account."))
            }

            // Lock this mode's profile (Facebook-style)
            Section {
                SettingToggleRow(isOn: Binding(
                    get: { appState.currentUser?.isLocked ?? false },
                    set: { lock in
                        if lock { confirmLock = true }
                        else { Task { await profileLock.set(false, appState: appState) } }
                    }
                )) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(themeManager.theme.primary)
                                .frame(width: 30, height: 30)
                            Image(systemName: "lock.shield.fill")
                                .scaledFont(13)
                                .foregroundColor(.white)
                        }
                        Text(bundle.loc(appState.currentMode == .work ? "Lock my Work profile" : "Lock my Hobby profile"))
                            .scaledFont(16)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
                .disabled(profileLock.isSaving)
            } footer: {
                Text(bundle.loc(appState.currentMode == .work
                    ? "Only your Work connections can see your posts and profile details. Others see your name, photo and cover."
                    : "Only your friends can see your posts and profile details. Others see your name, photo and cover."))
            }

            // This mode's profile → my other persona (each mode has its own switch)
            Section {
                SettingToggleRow(isOn: Binding(
                    get: { appState.currentUser?.linksOtherMode ?? true },
                    set: { link in Task { await personaLink.set(link, appState: appState) } }
                )) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(themeManager.theme.primary)
                                .frame(width: 30, height: 30)
                            Image(systemName: otherMode.glyph)
                                .scaledFont(13)
                                .foregroundColor(.white)
                        }
                        Text(bundle.loc(otherMode == .work ? "Show a link to my Work profile" : "Show a link to my Hobby profile"))
                            .scaledFont(16)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
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
                                .scaledFont(14)
                                .foregroundColor(.white)
                        }
                        Text("Blocked users", bundle: bundle)
                            .scaledFont(16)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
            } footer: {
                Text("People you block can't see your posts or message you.", bundle: bundle)
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
        .sheet(isPresented: Binding(get: { twoFactorChange != nil }, set: { if !$0 { twoFactorChange = nil } })) {
            if let enabling = twoFactorChange { TwoFactorSheet(enabling: enabling) }
        }
        .alert(bundle.loc("Lock your profile?"), isPresented: $confirmLock) {
            Button(bundle.loc("Lock")) { Task { await profileLock.set(true, appState: appState) } }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text(bundle.loc(appState.currentMode == .work
                ? "People who aren't your Work connections will only see your name, photo, cover and username, not your posts, experience, skills or lists."
                : "People who aren't your friends will only see your name, photo, cover and username, not your posts, highlights, details or lists."))
        }
        .alert(profileLock.errorMessage ?? "", isPresented: Binding(
            get: { profileLock.errorMessage != nil },
            set: { if !$0 { profileLock.errorMessage = nil } }
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
        .navigationDestination(isPresented: $showManageAccount) { ManageAccountView() }
        .task { consumePendingAssistantSheet() }
        .onChange(of: appState.pendingAssistantSheet) { _, _ in
            consumePendingAssistantSheet()
        }
    }

    /// Opens Change Password / Manage account when the AI assistant's
    /// guidance action landed here. Mirrors the consume-then-clear pattern
    /// `pendingDeepLink`/`pendingAssistantNavigation` use elsewhere.
    private func consumePendingAssistantSheet() {
        switch appState.pendingAssistantSheet {
        case .changePassword:
            appState.pendingAssistantSheet = nil
            showChangePassword = true
        case .deleteAccount:
            appState.pendingAssistantSheet = nil
            showManageAccount = true
        case .editProfile, nil:
            break
        }
    }
}
