import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var showThemePicker = false
    @AppStorage("searchRadiusKm") private var searchRadiusKm: Int = 0

    private let radiusOptions = [0, 1, 5, 10, 15, 20, 25, 30]

    var body: some View {
        List {
            // Mode Switch
            Section {
                modeSwitchRow
            } header: {
                Text("Chế độ đang dùng", bundle: bundle)
            }

            // Theme
            Section {
                themePickerRow
            } header: {
                Text(String(format: bundle.loc("Giao diện · %@"), appState.currentMode == .friend ? bundle.loc("Chế độ Bạn bè") : bundle.loc("Chế độ Đồng nghiệp")))
            }

            // Language
            Section {
                languagePickerRow
            } header: {
                Text("Giao diện", bundle: bundle)
            }

            // Appearance
            Section {
                appearancePicker
            }

            // Search
            Section {
                radiusSliderRow
            } header: {
                Text("Tìm kiếm", bundle: bundle)
            } footer: {
                Text(searchRadiusKm == 0
                     ? bundle.loc("Không giới hạn khoảng cách khi tìm kiếm có địa điểm.")
                     : String(format: bundle.loc("Kujira chỉ gợi ý người trong vòng %dkm khi bạn tìm kiếm có địa điểm."), searchRadiusKm))
            }

            // Account
            Section(bundle.loc("Tài khoản")) {
                settingsRow(icon: "person.fill",    label: bundle.loc("Chỉnh sửa hồ sơ"),         color: themeManager.theme.primary)
                settingsRow(icon: "bell.fill",      label: bundle.loc("Thông báo"),                color: Color(hex: "#FF6B35"))
                settingsRow(icon: "lock.fill",      label: bundle.loc("Quyền riêng tư & Bảo mật"), color: Color(hex: "#4CAF50"))
                settingsRow(icon: "bookmark.fill",  label: bundle.loc("Đã lưu"),                   color: Color(hex: "#9C27B0"))
            }

            // About
            Section(bundle.loc("Thông tin")) {
                settingsRow(icon: "questionmark.circle.fill", label: bundle.loc("Trợ giúp & Hỗ trợ"), color: Color(hex: "#2196F3"))
                settingsRow(icon: "doc.text.fill",            label: bundle.loc("Điều khoản dịch vụ"), color: Color(hex: "#607D8B"))
                settingsRow(icon: "hand.raised.fill",         label: bundle.loc("Chính sách bảo mật"), color: Color(hex: "#607D8B"))
                HStack {
                    settingsRow(icon: "info.circle.fill", label: bundle.loc("Phiên bản"), color: Color(hex: "#9E9E9E"))
                    Spacer()
                    Text("1.0.0")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }

            // Logout
            Section {
                Button(role: .destructive) {
                    appState.logout()
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right.square.fill")
                            .foregroundColor(.red)
                        Text("Đăng xuất", bundle: bundle)
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(bundle.loc("Cài đặt"))
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showThemePicker) {
            ThemePickerView()
        }
    }

    // MARK: Mode Switch

    private var modeSwitchRow: some View {
        HStack(spacing: 8) {
            modePill(mode: .friend,    icon: "person.2.fill",  label: bundle.loc("Chế độ Bạn bè"))
            modePill(mode: .colleague, icon: "briefcase.fill", label: bundle.loc("Chế độ Đồng nghiệp"))
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }

    private func modePill(mode: AppMode, icon: String, label: String) -> some View {
        let isActive = appState.currentMode == mode
        let color    = themeManager.theme.primary
        return Button {
            withAnimation(.spring(response: 0.3)) { appState.currentMode = mode }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isActive ? .white : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? color : color.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
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
            Text("Ngôn ngữ", bundle: bundle)
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
                Text(mode.label(for: appState.appLanguage)).tag(mode)
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
                Text("Bán kính tìm kiếm", bundle: bundle)
                    .font(.system(size: 16))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Spacer()
                Text(searchRadiusKm == 0 ? bundle.loc("Không giới hạn") : String(format: bundle.loc("%d km"), searchRadiusKm))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(themeManager.theme.primary)
            }

            Slider(
                value: Binding(
                    get: { Double(radiusOptions.firstIndex(of: searchRadiusKm) ?? 0) },
                    set: { searchRadiusKm = radiusOptions[Int($0.rounded())] }
                ),
                in: 0...Double(radiusOptions.count - 1),
                step: 1
            )
            .tint(themeManager.theme.primary)

            HStack {
                Text("Không\ngiới hạn", bundle: bundle)
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .multilineTextAlignment(.center)
                Spacer()
                ForEach([5, 10, 20, 30], id: \.self) { km in
                    Text("\(km)km")
                        .font(.system(size: 10))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                    if km != 30 { Spacer() }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Settings Row

    private func settingsRow(icon: String, label: String, color: Color) -> some View {
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
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }
}
