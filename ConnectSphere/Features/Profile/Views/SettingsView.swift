import SwiftUI

struct SettingsView: View {
    @AppStorage(TranslationMode.storageKey) private var translationModeRaw = TranslationMode.original.rawValue
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var showThemePicker = false
    @State private var showLogoutConfirm = false
    @State private var moderationEntry = ModerationEntryViewModel()
    @AppStorage("searchRadiusKm") private var searchRadiusKm: Int = 0


    /// Read from the bundle rather than hardcoded, so it can't silently go
    /// stale on the next release.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    var body: some View {
        List {
            // The official account's own section, first and apart from Safety:
            // review reports, stats and account lookup.
            if moderationEntry.isAdmin {
                Section {
                    NavigationLink {
                        AdminToolsView().environment(themeManager)
                    } label: {
                        settingsRow(icon: "checkmark.seal.fill", label: bundle.loc("Admin tools"),
                                    color: Color(hex: "#1E88E5"), showsChevron: false)
                    }
                } header: {
                    Text("Admin", bundle: bundle)
                }
            }

            // Theme color (per mode) and app icon (app-wide) share a section; Light/Dark
            // is its own, below.
            Section {
                themePickerRow
                AppIconRow()
            } header: {
                Text("App theme", bundle: bundle)
            }

            Section {
                appearancePicker
            } header: {
                Text("Appearance", bundle: bundle)
            }

            // Language
            Section {
                languagePickerRow
                translationModeRow
            } header: {
                Text("Language", bundle: bundle)
            } footer: {
                Text("Posts and comments in English or Vietnamese can be translated into the other. Translations are made by AI and may not be perfect.", bundle: bundle)
            }

            // Search
            Section {
                radiusSliderRow
            } header: {
                Text("Search", bundle: bundle)
            } footer: {
                Text(searchRadiusKm == 0
                     ? bundle.loc("No distance limit when searching with location.")
                     : String(format: bundle.loc("Search only suggests people within %dkm of your ward, or of the place you name."), searchRadiusKm))
            }

            // Account, identity, privacy, activity and deleting live in Manage account
            Section {
                NavigationLink {
                    ManageAccountView()
                } label: {
                    settingsRow(icon: "person.crop.circle", label: bundle.loc("Manage account"),
                                color: themeManager.theme.primary, showsChevron: false)
                }
                NavigationLink {
                    NotificationSettingsView()
                        .environment(appState)
                        .environment(themeManager)
                } label: {
                    settingsRow(icon: "bell.fill", label: bundle.loc("Notifications"), color: Color(hex: "#FF6B35"), showsChevron: false)
                }
                NavigationLink {
                    MutedWordsView()
                        .environment(appState)
                        .environment(themeManager)
                } label: {
                    settingsRow(icon: "speaker.slash.fill", label: bundle.loc("Muted words"), color: Color(hex: "#5C6BC0"), showsChevron: false)
                }
                NavigationLink {
                    DraftsView()
                        .environment(appState)
                        .environment(themeManager)
                } label: {
                    settingsRow(icon: "doc.text.fill", label: bundle.loc("Drafts & scheduled"), color: Color(hex: "#26A69A"), showsChevron: false)
                }
                NavigationLink {
                    SavedPostsView()
                        .environment(themeManager)
                } label: {
                    settingsRow(icon: "bookmark.fill", label: bundle.loc("Saved"), color: Color(hex: "#795548"), showsChevron: false)
                }
                // The official account can't sell, so it has no items to manage.
                if !(appState.currentUser?.isOfficial ?? false) {
                    NavigationLink {
                        MarketplaceMyItemsView(mode: appState.currentMode, sellerId: appState.currentUser?.id ?? "")
                            .environment(appState)
                            .environment(themeManager)
                    } label: {
                        settingsRow(icon: "bag.fill", label: bundle.loc("Marketplace"), color: Color(hex: "#E67E22"), showsChevron: false)
                    }
                }
                NavigationLink {
                    RecentlyDeletedView()
                        .environment(themeManager)
                } label: {
                    settingsRow(icon: "trash.fill", label: bundle.loc("Recently Deleted"), color: Color(hex: "#8E8E93"), showsChevron: false)
                }
            } header: {
                Text("Account", bundle: bundle)
            } footer: {
                Text("Your username, email, privacy, activity and deleting your account are in Manage account.", bundle: bundle)
            }

            // Safety: the review queue for app moderators and a way to reach us
            // (App Store rule 1.2). Account status lives in Manage account.
            Section {
                // The admin reviews reports inside Admin tools; moderators come here.
                if moderationEntry.isStaff && !moderationEntry.isAdmin {
                    NavigationLink {
                        AppModerationQueueView().environment(themeManager)
                    } label: {
                        settingsRow(icon: "hammer.fill", label: bundle.loc("Moderation"),
                                    color: Color(hex: "#E53935"), showsChevron: false)
                    }
                }
                Link(destination: URL(string: "mailto:\(Self.safetyEmail)")!) {
                    settingsRow(icon: "envelope.fill", label: bundle.loc("Safety & contact"), color: Color(hex: "#455A64"))
                }
            } header: {
                Text("Safety", bundle: bundle)
            } footer: {
                Text(String(format: bundle.loc("To report something urgent or ask about a decision, email %@."), Self.safetyEmail))
            }

            #if DEBUG
            // Dev-only: override the backend address without an Xcode
            // rebuild, for networks where the built-in .local Bonjour
            // hostname doesn't resolve (see APIConfig.serverBase).
            Section(bundle.loc("Developer")) {
                NavigationLink {
                    DevServerSettingsView()
                        .environment(themeManager)
                } label: {
                    settingsRow(icon: "wrench.and.screwdriver.fill", label: bundle.loc("Server address"), color: Color(hex: "#5C6BC0"), showsChevron: false)
                }
            }
            #endif

            // About
            Section(bundle.loc("About")) {
                NavigationLink {
                    StaticInfoView(titleKey: "Help & Support", sections: StaticInfoView.helpSections)
                        .environment(appState)
                } label: {
                    settingsRow(icon: "questionmark.circle.fill", label: bundle.loc("Help & Support"), color: Color(hex: "#2196F3"), showsChevron: false)
                }
                NavigationLink {
                    StaticInfoView(titleKey: "Terms of Service", sections: StaticInfoView.termsSections)
                        .environment(appState)
                } label: {
                    settingsRow(icon: "doc.text.fill", label: bundle.loc("Terms of Service"), color: Color(hex: "#607D8B"), showsChevron: false)
                }
                NavigationLink {
                    StaticInfoView(titleKey: "Privacy Policy", sections: StaticInfoView.privacySections)
                        .environment(appState)
                } label: {
                    settingsRow(icon: "hand.raised.fill", label: bundle.loc("Privacy Policy"), color: Color(hex: "#607D8B"), showsChevron: false)
                }
                NavigationLink {
                    StaticInfoView(titleKey: "Acknowledgements", sections: StaticInfoView.acknowledgementSections)
                        .environment(appState)
                } label: {
                    settingsRow(icon: "curlybraces", label: bundle.loc("Acknowledgements"), color: Color(hex: "#607D8B"), showsChevron: false)
                }
                HStack {
                    settingsRow(icon: "info.circle.fill", label: bundle.loc("Version"), color: Color(hex: "#9E9E9E"), showsChevron: false)
                    Spacer()
                    Text(appVersion)
                        .scaledFont(14)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }

            // Logout
            Section {
                Button(role: .destructive) {
                    showLogoutConfirm = true
                } label: {
                    HStack(spacing: 12) {
                        // Same 30×30 tile as every other row.
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.red)
                                .frame(width: 30, height: 30)
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .scaledFont(14)
                                .foregroundColor(.white)
                        }
                        Text("Log out", bundle: bundle)
                            .scaledFont(16)
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .task { await moderationEntry.load() }
        // .alert (not .confirmationDialog). Always a centered box regardless
        // of action count, matching the familiar Facebook-style "Log out of
        // your account?" pattern. .confirmationDialog with just one
        // destructive action rendered as an anchored popover bubble near the
        // tapped row instead of a centered dialog.
        .alert(bundle.loc("Log out of ConnectSphere?"), isPresented: $showLogoutConfirm) {
            Button(bundle.loc("Cancel"), role: .cancel) {}
            Button(bundle.loc("Log out"), role: .destructive) {
                appState.logout()
                dismiss()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(bundle.loc("Settings"))
        .navigationBarTitleDisplayMode(.large)
        .alert(bundle.loc("Error"), isPresented: Binding(
            get: { appState.appIconError != nil },
            set: { if !$0 { appState.appIconError = nil } }
        )) {
            Button(bundle.loc("OK")) { appState.appIconError = nil }
        } message: {
            Text(appState.appIconError ?? "")
        }
        .sheet(isPresented: $showThemePicker) {
            ThemePickerView()
        }
    }

    // MARK: Language Picker Row

    private var languagePickerRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: "#5856D6"))
                    .frame(width: 30, height: 30)
                Image(systemName: "globe")
                    .scaledFont(14)
                    .foregroundColor(.white)
            }
            Text("Language", bundle: bundle)
                .scaledFont(16)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer()
            Picker("", selection: Bindable(appState).appLanguage) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text("\(lang.flag) \(lang.displayName)").tag(lang)
                }
            }
            .pickerStyle(.menu)
            .tint(AppColors.textSecondary(colorScheme))
        }
    }

    /// Whether posts in the other language show their translation first.
    private var translationModeRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: "#30B0C7"))
                    .frame(width: 30, height: 30)
                Image(systemName: "character.bubble")
                    .scaledFont(14)
                    .foregroundColor(.white)
            }
            Text("Translations", bundle: bundle)
                .scaledFont(16)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer()
            Picker("", selection: $translationModeRaw) {
                ForEach(TranslationMode.allCases, id: \.rawValue) { mode in
                    Text(bundle.loc(mode.label)).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
            .tint(AppColors.textSecondary(colorScheme))
        }
    }

    // MARK: Appearance Picker

    private var appearancePicker: some View {
        AppearancePicker(selection: Bindable(appState).appearanceMode)
    }

    // MARK: Theme Picker Row

    private var themePickerRow: some View {
        Button {
            showThemePicker = true
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(themeManager.theme.primary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Theme color", bundle: bundle)
                        .scaledFont(16)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    Text(appState.currentMode == .hobby ? bundle.loc("Hobby Mode") : bundle.loc("Work Mode"))
                        .scaledFont(12)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Spacer()
                Text(themeManager.theme.name)
                    .scaledFont(15)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                Image(systemName: "chevron.right")
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
    }

    // MARK: Radius Slider Row

    private var radiusSliderRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "location.circle.fill")
                    .foregroundColor(themeManager.theme.primary)
                Text("Search radius", bundle: bundle)
                    .scaledFont(16)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Spacer()
                Text(searchRadiusKm == 0 ? bundle.loc("Unlimited") : String(format: bundle.loc("%d km"), searchRadiusKm))
                    .scaledFont(15, .semibold)
                    .foregroundColor(themeManager.theme.primary)
            }

            SearchRadiusSlider(km: $searchRadiusKm, tint: themeManager.theme.primary)
        }
        .padding(.vertical, 4)
    }

    // MARK: Settings Row

    /// Shown in the app so anyone can reach the team about safety.
    static let safetyEmail = "kujira.gwer@gmail.com"

    private func settingsRow(icon: String, label: String, color: Color, showsChevron: Bool = true) -> some View {
        SettingsRowLabel(icon: icon, label: label, color: color, showsChevron: showsChevron)
    }
}
