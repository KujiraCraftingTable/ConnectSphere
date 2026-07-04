import SwiftUI

struct SettingsSheet: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var showThemePicker = false
    @AppStorage("searchRadiusKm") private var searchRadiusKm: Int = 0  // 0 = no limit

    private let radiusOptions = [0, 1, 5, 10, 15, 20, 25, 30]

    var body: some View {
        NavigationStack {
            List {
                // Mode Switch — top section
                Section {
                    modeSwitchRow
                } header: {
                    Text("Chế độ đang dùng", bundle: bundle)
                }

                // Theme color for current mode
                Section {
                    themePickerRow
                } header: {
                    Text(String(format: bundle.loc("Giao diện · %@"), appState.currentMode == .friend ? bundle.loc("Chế độ Bạn bè") : bundle.loc("Chế độ Đồng nghiệp")))
                }

                // Appearance
                Section {
                    appearancePicker
                } header: {
                    Text("Giao diện", bundle: bundle)
                }

                // Search Settings
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
                    settingsRow(icon: "person.fill", label: bundle.loc("Chỉnh sửa hồ sơ"), color: themeManager.theme.primary)
                    settingsRow(icon: "bell.fill", label: bundle.loc("Thông báo"), color: Color(hex: "#FF6B35"))
                    settingsRow(icon: "lock.fill", label: bundle.loc("Quyền riêng tư & Bảo mật"), color: Color(hex: "#4CAF50"))
                    settingsRow(icon: "bookmark.fill", label: bundle.loc("Đã lưu"), color: Color(hex: "#9C27B0"))
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
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(bundle.loc("Cài đặt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundColor(themeManager.theme.primary)
                }
            }
        }
        .preferredColorScheme(appState.appearanceMode.colorScheme)
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

    // MARK: Appearance Picker

    private var appearancePicker: some View {
        // @Environment vars aren't directly bindable — wrap with Bindable first
        Picker("", selection: Bindable(appState).appearanceMode) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
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
                // Live swatch of active palette
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
        .sheet(isPresented: $showThemePicker) {
            ThemePickerView()
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

            // Step slider over discrete values
            Slider(
                value: Binding(
                    get: { Double(radiusOptions.firstIndex(of: searchRadiusKm) ?? 0) },
                    set: { searchRadiusKm = radiusOptions[Int($0.rounded())] }
                ),
                in: 0...Double(radiusOptions.count - 1),
                step: 1
            )
            .tint(themeManager.theme.primary)

            // Labels
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
