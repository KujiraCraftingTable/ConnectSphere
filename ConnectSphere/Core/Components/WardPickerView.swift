import SwiftUI

/// Two-level location picker: Province → Ward. The ward is a person's private
/// home point for distance search; only its province is ever shown publicly.
/// Binds to selectedProvinceCode + selectedWardId.
struct WardPickerView: View {
    @Environment(\.appBundle) var bundle

    @Binding var selectedProvinceCode: String?
    @Binding var selectedWardId: String?
    /// The line under the pickers; a person's ward and a job's are explained differently.
    var note: String? = nil

    @State private var viewModel = WardPickerViewModel()
    @State private var showWardList = false
    @State private var showProvinceList = false

    var selectedProvinceName: String {
        viewModel.provinceName(code: selectedProvinceCode) ?? bundle.loc("Select province")
    }

    var selectedWardName: String {
        viewModel.wardName(id: selectedWardId) ?? bundle.loc("Select ward *")
    }

    var body: some View {
        VStack(spacing: 12) {
            // Same searchable list as the wards, so both steps look and work alike.
            Button { showProvinceList = true } label: {
                pickerRow(icon: "map.fill", text: selectedProvinceName, isPlaceholder: selectedProvinceCode == nil)
            }
            .buttonStyle(.plain)

            // About a hundred wards per province: a searchable list.
            Button { showWardList = true } label: {
                pickerRow(icon: "location.fill", text: selectedWardName, isPlaceholder: selectedWardId == nil)
            }
            .buttonStyle(.plain)
            .disabled(selectedProvinceCode == nil)
            .opacity(selectedProvinceCode == nil ? 0.5 : 1)

            Text(note ?? bundle.loc("Your ward stays private. It is only used to tell how far away people are; others see your province."))
                .scaledFont(12)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await viewModel.loadProvinces(selectedProvinceCode: selectedProvinceCode) }
        .sheet(isPresented: $showWardList) {
            WardListSheet(viewModel: viewModel, selectedWardId: $selectedWardId)
        }
        .sheet(isPresented: $showProvinceList) {
            ProvinceListSheet(viewModel: viewModel, selectedProvinceCode: selectedProvinceCode) { code in
                guard selectedProvinceCode != code else { return }
                selectedProvinceCode = code
                selectedWardId = nil
                Task { await viewModel.loadWards(provinceCode: code) }
            }
        }
    }

    // MARK: - Row UI

    private func pickerRow(icon: String, text: String, isPlaceholder: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(14)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(text)
                .scaledFont(15)
                .foregroundColor(isPlaceholder ? .secondary : .primary)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .scaledFont(12)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color(.systemBackground).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator), lineWidth: 0.5))
    }
}

/// The 34 provinces, searchable with or without Vietnamese accents.
private struct ProvinceListSheet: View {
    let viewModel: WardPickerViewModel
    let selectedProvinceCode: String?
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) var bundle
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(viewModel.provinces(matching: searchText)) { province in
                Button {
                    onPick(province.province_code)
                    dismiss()
                } label: {
                    HStack {
                        Text(province.province_name).foregroundColor(.primary)
                        Spacer()
                        if selectedProvinceCode == province.province_code { Image(systemName: "checkmark") }
                    }
                }
            }
            .overlay {
                if viewModel.isLoadingProvinces { ProgressView() }
            }
            .searchable(text: $searchText, prompt: bundle.loc("Search province"))
            .navigationTitle(bundle.loc("Select province"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
            }
        }
    }
}

/// The chosen province's wards, searchable with or without Vietnamese accents.
private struct WardListSheet: View {
    let viewModel: WardPickerViewModel
    @Binding var selectedWardId: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) var bundle
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(viewModel.wards(matching: searchText)) { ward in
                Button {
                    selectedWardId = ward.id
                    dismiss()
                } label: {
                    HStack {
                        Text(ward.full_name).foregroundColor(.primary)
                        Spacer()
                        if selectedWardId == ward.id { Image(systemName: "checkmark") }
                    }
                }
            }
            .overlay {
                if viewModel.isLoadingWards { ProgressView() }
            }
            .searchable(text: $searchText, prompt: bundle.loc("Search ward"))
            .navigationTitle(bundle.loc("Select ward"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
            }
        }
    }
}
