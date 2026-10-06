import SwiftUI

/// Two-level location picker: Province → Ward.
/// Binds to selectedProvinceCode + selectedWardId.
struct WardPickerView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    @Binding var selectedProvinceCode: String?
    @Binding var selectedWardId: String?

    @State private var viewModel = WardPickerViewModel()

    var selectedProvinceName: String {
        viewModel.provinceName(code: selectedProvinceCode) ?? bundle.loc("Select province")
    }

    var selectedWardName: String {
        viewModel.wardName(id: selectedWardId) ?? bundle.loc("Select ward")
    }

    var body: some View {
        VStack(spacing: 12) {
            // Province picker
            Menu {
                if viewModel.isLoadingProvinces {
                    Text("Loading...", bundle: bundle).foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.provinces) { province in
                        Button(province.province_name) {
                            if selectedProvinceCode != province.province_code {
                                selectedProvinceCode = province.province_code
                                selectedWardId = nil
                                Task { await viewModel.loadWards(provinceCode: province.province_code) }
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
                if viewModel.isLoadingWards {
                    Text("Loading...", bundle: bundle).foregroundColor(.secondary)
                } else if viewModel.wards.isEmpty {
                    Text("Select a province first", bundle: bundle).foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.wards) { ward in
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
        .task { await viewModel.loadProvinces(selectedProvinceCode: selectedProvinceCode) }
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
}
