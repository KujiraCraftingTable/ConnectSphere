import SwiftUI

/// Create or edit your dating profile. Cancel always asks before throwing
/// the changes away, and swipe-to-dismiss can't skip that question.
struct DatingProfileEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: DatingProfileEditorViewModel
    let onSaved: (DatingProfile) -> Void

    init(profile: DatingProfile?, isTeen: Bool, onSaved: @escaping (DatingProfile) -> Void) {
        _viewModel = State(initialValue: DatingProfileEditorViewModel(profile: profile, isTeen: isTeen))
        self.onSaved = onSaved
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                photosSection
                Section {
                    TextField(bundle.loc("A few words about you"), text: $viewModel.bio, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("About you", bundle: bundle)
                } footer: {
                    Text(verbatim: "\(viewModel.bio.count)/\(DatingProfileEditorViewModel.maxBio)")
                        .foregroundColor(viewModel.bio.count > DatingProfileEditorViewModel.maxBio
                                         ? AppColors.danger(colorScheme) : AppColors.textTertiary(colorScheme))
                }
                Section {
                    Picker(bundle.loc("Height"), selection: $viewModel.heightCm) {
                        Text("Not shown", bundle: bundle).tag(Int?.none)
                        ForEach(DatingProfileEditorViewModel.heights, id: \.self) { cm in
                            Text(String(format: bundle.loc("%lld cm"), cm)).tag(Int?.some(cm))
                        }
                    }
                    Picker(bundle.loc("Kids"), selection: $viewModel.hasKids) {
                        Text("Not shown", bundle: bundle).tag(DatingKids?.none)
                        ForEach(DatingKids.allCases, id: \.self) { Text(bundle.loc($0.label)).tag(DatingKids?.some($0)) }
                    }
                }
                locationSection
                preferencesSection
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundColor(AppColors.danger(colorScheme)) }
                }
            }
            .tint(themeManager.theme.primary)
            .navigationTitle(Text(viewModel.isNew ? "Create dating profile" : "Edit dating profile", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ConfirmCancelButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Button(bundle.loc("Save")) {
                            Task<Void, Never>(name: nil) {
                                if let saved = await viewModel.save(token: token) {
                                    onSaved(saved)
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!viewModel.canSave)
                    }
                }
            }
        }
    }

    // MARK: photos

    private var photosSection: some View {
        Section {
            DatingPhotoStrip(form: viewModel)
        } header: {
            Text("Photos", bundle: bundle)
        } footer: {
            Text("1–6 photos. The first one is shown first; press and hold a photo to make it first.", bundle: bundle)
        }
    }

    // MARK: location — from the phone only

    @ViewBuilder
    private var locationSection: some View {
        Section {
            if viewModel.locationBlocked {
                DatingLocationRequiredView(isWorking: viewModel.isLocating) {
                    Task<Void, Never>(name: nil) { await viewModel.useCurrentLocation() }
                }
                .listRowInsets(EdgeInsets())
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "location.fill").foregroundColor(themeManager.theme.primary)
                    Text(viewModel.place?.name ?? bundle.loc("Not shared yet"))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    Spacer()
                    if viewModel.isLocating {
                        ProgressView()
                    } else {
                        Button(bundle.loc("Update")) {
                            Task<Void, Never>(name: nil) { await viewModel.useCurrentLocation() }
                        }
                    }
                }
            }
        } header: {
            Text("Location", bundle: bundle)
        } footer: {
            Text("From your phone, updated each time you open Dating. Others see only your district and city.", bundle: bundle)
        }
    }

    // MARK: who you want to meet

    private var preferencesSection: some View {
        Section {
            Picker(bundle.loc("Interested in"), selection: $viewModel.interestedIn) {
                ForEach(DatingInterest.allCases, id: \.self) { Text(bundle.loc($0.label)).tag($0) }
            }
            Stepper(value: Binding(get: { viewModel.minAge }, set: viewModel.setMinAge), in: viewModel.ageBounds) {
                Text(String(format: bundle.loc("From age %lld"), viewModel.minAge))
            }
            Stepper(value: Binding(get: { viewModel.maxAge }, set: viewModel.setMaxAge), in: viewModel.ageBounds) {
                Text(String(format: bundle.loc("To age %lld"), viewModel.maxAge))
            }
            Picker(bundle.loc("Distance"), selection: $viewModel.maxDistanceKm) {
                ForEach(DatingProfileEditorViewModel.distanceChoices, id: \.self) { km in
                    if let km {
                        Text(String(format: bundle.loc("Within %lld km"), km)).tag(Int?.some(km))
                    } else {
                        Text("Any distance", bundle: bundle).tag(Int?.none)
                    }
                }
            }
        } header: {
            Text("Who you'd like to meet", bundle: bundle)
        } footer: {
            if viewModel.ageBounds.upperBound < 18 {
                Text("People aged 16–17 only meet others aged 16–17.", bundle: bundle)
            } else {
                Text("Adults only meet other adults (18+).", bundle: bundle)
            }
        }
    }
}
