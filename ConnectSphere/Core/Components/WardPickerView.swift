import SwiftUI

/// Two-level location picker: Province → Ward.
/// Binds to selectedProvinceCode + selectedWardId.
struct WardPickerView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    @Binding var selectedProvinceCode: String?
    @Binding var selectedWardId: String?

    @State private var provinces: [ProvinceDTO] = []
    @State private var wards:     [WardDTO]     = []
    @State private var isLoadingProvinces = false
    @State private var isLoadingWards     = false

    private let repository = WardRepository()

    var selectedProvinceName: String {
        provinces.first { $0.province_code == selectedProvinceCode }?.province_name ?? bundle.loc("Chọn tỉnh/thành")
    }

    var selectedWardName: String {
        wards.first { $0.id == selectedWardId }?.full_name ?? bundle.loc("Chọn phường/xã")
    }

    var body: some View {
        VStack(spacing: 12) {
            // Province picker
            Menu {
                if isLoadingProvinces {
                    Text("Đang tải...", bundle: bundle).foregroundColor(.secondary)
                } else {
                    ForEach(provinces) { province in
                        Button(province.province_name) {
                            if selectedProvinceCode != province.province_code {
                                selectedProvinceCode = province.province_code
                                selectedWardId = nil
                                loadWards(provinceCode: province.province_code)
                            }
                        }
                    }
                }
            } label: {
                pickerRow(
                    icon: "map.fill",
                    text: selectedProvinceName,
                    isPlaceholder: selectedProvinceCode == nil
                )
            }

            // Ward picker — only enabled after province selected
            Menu {
                if isLoadingWards {
                    Text("Đang tải...", bundle: bundle).foregroundColor(.secondary)
                } else if wards.isEmpty {
                    Text("Chọn tỉnh/thành trước", bundle: bundle).foregroundColor(.secondary)
                } else {
                    ForEach(wards) { ward in
                        Button(ward.full_name) {
                            selectedWardId = ward.id
                        }
                    }
                }
            } label: {
                pickerRow(
                    icon: "location.fill",
                    text: selectedWardName,
                    isPlaceholder: selectedWardId == nil
                )
            }
            .disabled(selectedProvinceCode == nil)
            .opacity(selectedProvinceCode == nil ? 0.5 : 1)
        }
        .task { await loadProvinces() }
    }

    // MARK: - Row UI

    private func pickerRow(icon: String, text: String, isPlaceholder: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(isPlaceholder ? .secondary : .primary)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color(.systemBackground).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator), lineWidth: 0.5))
    }

    // MARK: - Data loading

    private func loadProvinces() async {
        guard provinces.isEmpty else { return }
        isLoadingProvinces = true
        if let fetched = try? await repository.fetchProvinces() {
            provinces = fetched
        }
        isLoadingProvinces = false

        // If province already selected (edit mode), pre-load wards
        if let code = selectedProvinceCode { loadWards(provinceCode: code) }
    }

    private func loadWards(provinceCode: String) {
        isLoadingWards = true
        wards = []
        Task {
            if let fetched = try? await repository.fetchWards(provinceCode: provinceCode) {
                wards = fetched
            }
            isLoadingWards = false
        }
    }
}
