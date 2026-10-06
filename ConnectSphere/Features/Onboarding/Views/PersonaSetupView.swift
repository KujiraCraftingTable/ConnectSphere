import SwiftUI

/// Form for creating a persona for the second mode — shown when the user first
/// switches into a mode that isn't set up yet (appState.pendingPersonaMode).
/// Same account but an independent display identity: work needs display name +
/// job title/company/skills; hobby needs display name + interests. Cancel = stay in the old mode.
struct PersonaSetupView: View {
    let mode: AppMode
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: PersonaSetupViewModel

    init(mode: AppMode) {
        self.mode = mode
        _viewModel = State(initialValue: PersonaSetupViewModel(mode: mode))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    VStack(spacing: 14) {
                        AuthTextField(
                            icon: "textformat",
                            placeholder: bundle.loc("Display name *"),
                            text: $viewModel.displayName
                        )

                        if mode == .work {
                            AuthTextField(icon: "briefcase",
                                          placeholder: bundle.loc("Job title (iOS Developer...)"),
                                          text: $viewModel.jobTitle)
                            AuthTextField(icon: "building.2",
                                          placeholder: bundle.loc("Company / School"),
                                          text: $viewModel.company)
                            AuthTextField(icon: "sparkles",
                                          placeholder: bundle.loc("Skills (Swift, Python, UI/UX...)"),
                                          text: $viewModel.skillsText)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Select what you like", bundle: bundle)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                                InterestPickerView(selectedInterests: $viewModel.selectedInterests,
                                                   colorScheme: colorScheme)
                            }
                        }
                    }

                    if let e = viewModel.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(e).font(.system(size: 13))
                        }
                        .foregroundColor(AppColors.danger(.light))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.danger(.light).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button {
                        Task {
                            guard let user = await viewModel.save() else { return }
                            appState.personaCreated(user, mode: mode)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if viewModel.isSaving { ProgressView().tint(.white).scaleEffect(0.8) }
                            Text(viewModel.isSaving ? bundle.loc("Saving...") : bundle.loc("Start"))
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(viewModel.isValid ? themeManager.theme.primary : AppColors.borderDefault(colorScheme),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!viewModel.isValid || viewModel.isSaving)
                }
                .padding(16)
            }
            .background(AppColors.base(colorScheme))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) {
                        appState.pendingPersonaMode = nil
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isSaving)
    }

    // MARK: Header — explains why this form is needed

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(themeManager.theme.primary.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: mode.glyph)
                    .font(.system(size: 26))
                    .foregroundColor(themeManager.theme.primary)
            }
            VStack(spacing: 6) {
                Text(mode == .work
                     ? bundle.loc("Set up your Work profile")
                     : bundle.loc("Set up your Hobby profile"))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                Text("This mode has its own separate identity — name, avatar and bio won't be shared with the other mode", bundle: bundle)
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}
