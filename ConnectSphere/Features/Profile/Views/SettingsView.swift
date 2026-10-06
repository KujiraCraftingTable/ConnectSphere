import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var showThemePicker = false
    @State private var showEditProfile = false
    @State private var showLogoutConfirm = false
    @AppStorage("searchRadiusKm") private var searchRadiusKm: Int = 0


    /// Read from the bundle rather than hardcoded, so it can't silently go
    /// stale on the next release.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        List {
            // Appearance: theme picker + System/Light/Dark, one section, one
            // header — previously split across two sections that both ended
            // up headed "Appearance".
            Section {
                themePickerRow
                appearancePicker
            } header: {
                Text(String(format: bundle.loc("Appearance · %@"), appState.currentMode == .hobby ? bundle.loc("Hobby Mode") : bundle.loc("Work Mode")))
            }

            // Language
            Section {
                languagePickerRow
            } header: {
                Text("Language", bundle: bundle)
            }

            // Search
            Section {
                radiusSliderRow
            } header: {
                Text("Search", bundle: bundle)
            } footer: {
                Text(searchRadiusKm == 0
                     ? bundle.loc("No distance limit when searching with location.")
                     : String(format: bundle.loc("Kujira only suggests people within %dkm when searching with location."), searchRadiusKm))
            }

            // Account
            Section(bundle.loc("Account")) {
                Button { showEditProfile = true } label: {
                    settingsRow(icon: "person.fill", label: bundle.loc("Edit profile"), color: themeManager.theme.primary)
                }
                NavigationLink {
                    NotificationSettingsView()
                        .environment(appState)
                        .environment(themeManager)
                } label: {
                    settingsRow(icon: "bell.fill", label: bundle.loc("Notifications"), color: Color(hex: "#FF6B35"), showsChevron: false)
                }
                NavigationLink {
                    PrivacySecurityView()
                        .environment(appState)
                        .environment(themeManager)
                } label: {
                    settingsRow(icon: "lock.fill", label: bundle.loc("Privacy & Security"), color: Color(hex: "#4CAF50"), showsChevron: false)
                }
                NavigationLink {
                    RecentlyDeletedView()
                        .environment(themeManager)
                } label: {
                    settingsRow(icon: "trash.fill", label: bundle.loc("Recently Deleted"), color: Color(hex: "#8E8E93"), showsChevron: false)
                }
                NavigationLink {
                    SavedPostsView()
                        .environment(themeManager)
                } label: {
                    settingsRow(icon: "bookmark.fill", label: bundle.loc("Saved"), color: Color(hex: "#795548"), showsChevron: false)
                }
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
                HStack {
                    settingsRow(icon: "info.circle.fill", label: bundle.loc("Version"), color: Color(hex: "#9E9E9E"), showsChevron: false)
                    Spacer()
                    Text(appVersion)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }

            // Logout
            Section {
                Button(role: .destructive) {
                    showLogoutConfirm = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right.square.fill")
                            .foregroundColor(.red)
                        Text("Log out", bundle: bundle)
                            .foregroundColor(.red)
                    }
                }
            }
        }
        // .alert (not .confirmationDialog) — always a centered box regardless
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
        .sheet(isPresented: $showThemePicker) {
            ThemePickerView()
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileView()
                .environment(appState)
                .environment(themeManager)
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
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
            Text("Language", bundle: bundle)
                .font(.system(size: 16))
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

    // MARK: Appearance Picker

    private var appearancePicker: some View {
        Picker("", selection: Bindable(appState).appearanceMode) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                Text(bundle.loc(mode.label)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
    }

    // MARK: Theme Picker Row

    private var themePickerRow: some View {
        Button {
            showThemePicker = true
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(themeManager.theme.primaryGradient)
                    .frame(width: 28, height: 28)
                Text(themeManager.theme.name)
                    .font(.system(size: 16))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
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
                    .font(.system(size: 16))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Spacer()
                Text(searchRadiusKm == 0 ? bundle.loc("Unlimited") : String(format: bundle.loc("%d km"), searchRadiusKm))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(themeManager.theme.primary)
            }

            SearchRadiusSlider(km: $searchRadiusKm, tint: themeManager.theme.primary)
        }
        .padding(.vertical, 4)
    }

    // MARK: Settings Row

    private func settingsRow(icon: String, label: String, color: Color, showsChevron: Bool = true) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(color)
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
            Text(label)
                .font(.system(size: 16))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer()
            // NavigationLink inside a List draws its own chevron, so that row disables this manual one
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
    }
}
