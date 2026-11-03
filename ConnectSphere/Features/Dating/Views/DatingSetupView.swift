import SwiftUI

/// The first visit to Dating, Facebook-style: a welcome, what stays private,
/// then the profile one question at a time with a progress bar. Leaving with
/// answers asks first.
struct DatingSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: DatingSetupViewModel
    @State private var confirmLeave = false
    let onCreated: (DatingProfile) -> Void

    init(basics: DatingBasics?, isTeen: Bool, onCreated: @escaping (DatingProfile) -> Void) {
        _viewModel = State(initialValue: DatingSetupViewModel(basics: basics, isTeen: isTeen))
        self.onCreated = onCreated
    }

    private var token: String { appState.authToken ?? "" }
    private var form: DatingProfileEditorViewModel { viewModel.form }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.xl)
                    .padding(.top, AppSpacing.md)
                    .id(viewModel.step)
            }
            footer
        }
        .background((viewModel.isFirstStep ? themeManager.theme.primary : AppColors.base(colorScheme)).ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        // The bottom button stands where the tab bar would; one thing at a time.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: goBack) { Image(systemName: "chevron.left") }
                    .accessibilityLabel(Text("Back", bundle: bundle))
            }
            if viewModel.isSkippable {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Skip")) { viewModel.skip() }
                }
            }
        }
        .confirmationDialog(bundle.loc("Leave setup?"), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(bundle.loc("Leave"), role: .destructive) { dismiss() }
            Button(bundle.loc("Keep going"), role: .cancel) {}
        } message: {
            Text("Your answers won't be saved.", bundle: bundle)
        }
        .alert(bundle.loc("Something went wrong."), isPresented: Binding(
            get: { form.errorMessage != nil }, set: { if !$0 { form.errorMessage = nil } })) {
            Button(bundle.loc("OK"), role: .cancel) {}
        } message: {
            Text(form.errorMessage ?? "")
        }
    }

    private func goBack() {
        if !viewModel.isFirstStep {
            viewModel.back()
        } else if viewModel.hasAnswers {
            confirmLeave = true
        } else {
            dismiss()
        }
    }

    // MARK: footer — the main button and the progress bar

    private var footer: some View {
        VStack(spacing: AppSpacing.md) {
            Button(action: primaryAction) {
                Group {
                    if form.isSaving {
                        ProgressView().tint(viewModel.isFirstStep ? themeManager.theme.primary : .white)
                    } else {
                        Text(primaryTitle)
                    }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(viewModel.isFirstStep ? AppColors.textPrimary(.light) : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(primaryBackground, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoNext || form.isSaving)
            if !viewModel.isFirstStep {
                ProgressView(value: viewModel.progress)
                    .tint(themeManager.theme.primary)
                    .padding(.horizontal, AppSpacing.lg)
            }
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.bottom, AppSpacing.md)
    }

    private var primaryBackground: Color {
        if viewModel.isFirstStep { return .white }
        return viewModel.canGoNext || form.isSaving
            ? themeManager.theme.primary : AppColors.textTertiary(colorScheme).opacity(0.4)
    }

    private var primaryTitle: String {
        switch viewModel.step {
        case .welcome: return bundle.loc("Get started")
        case .about: return bundle.loc("Create profile")
        default: return bundle.loc("Next")
        }
    }

    private func primaryAction() {
        guard viewModel.isLastStep else { viewModel.next(); return }
        Task<Void, Never>(name: nil) {
            if let saved = await form.save(token: token) { onCreated(saved) }
        }
    }

    // MARK: steps

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.step {
        case .welcome: welcome
        case .privacy: privacy
        case .basics: basicsStep
        case .interestedIn: interestStep
        case .height: heightStep
        case .kids: kidsStep
        case .location: locationStep
        case .photos: photosStep
        case .about: aboutStep
        }
    }

    private func heading(_ title: String, _ subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(bundle.loc(title))
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            if let subtitle {
                Text(bundle.loc(subtitle))
                    .font(.system(size: 16))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, AppSpacing.lg)
    }

    private var welcome: some View {
        VStack(spacing: AppSpacing.xl) {
            Text("Welcome to Dating", bundle: bundle)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.top, AppSpacing.xl)
            if let user = appState.currentUser {
                Avatar(name: user.name, colorHex: user.avatarColor, imageURL: user.avatarUrl, diameter: 140)
                    .overlay(Circle().stroke(.white, lineWidth: 4))
            }
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                welcomePoint("heart.circle", "A new way to meet people",
                             "Meet people who are looking for someone too, with a profile made just for Dating.")
                welcomePoint("gift", "Free",
                             "Everything in Dating is free.")
                welcomePoint("lock", "Privacy first",
                             "Your Hobby friends aren't suggested, and nobody is told you joined.")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func welcomePoint(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Image(systemName: icon).font(.system(size: 26)).foregroundColor(.white).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.loc(title)).font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                Text(bundle.loc(text)).font(.system(size: 15)).foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("A space for dating",
                    "Your Hobby friends aren't suggested in Dating. What you do here stays in Dating — it never shows on your profile, in search or in feeds.")
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 120))
                .foregroundStyle(themeManager.theme.primary, themeManager.theme.primary.opacity(0.25))
                .frame(maxWidth: .infinity)
                .padding(.top, AppSpacing.xxl)
        }
    }

    private var basicsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Let's start building your Dating profile",
                    "Your Dating profile is visible to anyone in Dating. These come from your account; changes you make in Dating won't affect your profile.")
            basicsRow("person.crop.circle", "First name", viewModel.basics?.displayName ?? appState.currentUser?.name ?? "")
            basicsRow("leaf", "Age", viewModel.basics?.age.map(String.init) ?? "—")
            basicsRow("figure.stand", "Gender", genderLabel)
            Text("To change these, edit your profile.", bundle: bundle)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .padding(.top, AppSpacing.sm)
        }
    }

    private var genderLabel: String {
        switch viewModel.basics?.gender {
        case "male": return bundle.loc("Man")
        case "female": return bundle.loc("Woman")
        default: return bundle.loc("Other")
        }
    }

    private func basicsRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: AppSpacing.lg) {
            Image(systemName: icon).font(.system(size: 26)).frame(width: 34)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.loc(title)).font(.system(size: 17)).foregroundColor(AppColors.textPrimary(colorScheme))
                Text(value).font(.system(size: 15)).foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
        .padding(.vertical, AppSpacing.sm)
    }

    private var interestStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Who do you want to date?")
            ForEach(DatingInterest.allCases, id: \.self) { interest in
                Button { viewModel.chooseInterest(interest) } label: {
                    HStack {
                        Text(bundle.loc(interest.label)).font(.system(size: 18))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Spacer()
                        Image(systemName: viewModel.hasChosenInterest && form.interestedIn == interest
                              ? "checkmark.square.fill" : "square")
                            .font(.system(size: 24))
                            .foregroundColor(viewModel.hasChosenInterest && form.interestedIn == interest
                                             ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
                    }
                    .padding(.vertical, AppSpacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Age range", bundle: bundle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .padding(.top, AppSpacing.xl)
            Stepper(value: Binding(get: { form.minAge }, set: form.setMinAge), in: form.ageBounds) {
                Text(String(format: bundle.loc("From age %lld"), form.minAge))
            }
            .padding(.vertical, AppSpacing.xs)
            Stepper(value: Binding(get: { form.maxAge }, set: form.setMaxAge), in: form.ageBounds) {
                Text(String(format: bundle.loc("To age %lld"), form.maxAge))
            }
            .padding(.vertical, AppSpacing.xs)
            Text(form.ageBounds.upperBound < 18
                 ? bundle.loc("People aged 16–17 only meet others aged 16–17.")
                 : bundle.loc("Adults only meet other adults (18+)."))
                .font(.system(size: 13))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
    }

    private var heightStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("How tall are you?")
            Picker(bundle.loc("Height"), selection: $viewModel.heightDraft) {
                ForEach(DatingProfileEditorViewModel.heights, id: \.self) { cm in
                    Text(String(format: bundle.loc("%lld cm"), cm)).tag(cm)
                }
            }
            .pickerStyle(.wheel)
            Text("Visible on your Dating profile", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }

    private var kidsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Do you have kids?")
            FlowLayout(spacing: 10) {
                ForEach(DatingKids.allCases, id: \.self) { answer in
                    let selected = form.hasKids == answer
                    Button { form.hasKids = answer } label: {
                        Text(bundle.loc(answer.label))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(selected ? .white : AppColors.textPrimary(colorScheme))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(selected ? themeManager.theme.primary : AppColors.elevated(colorScheme), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Visible on your Dating profile", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.top, AppSpacing.lg)
        }
    }

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            heading("Where are you dating?",
                    "Dating uses your phone's location to suggest people near you. Your profile shows only your district and city, and it updates each time you open Dating.")
            if let place = form.place, !form.locationBlocked {
                ListingMapPreview(latitude: place.latitude, longitude: place.longitude, name: place.name)
                Label(place.name, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Picker(bundle.loc("Distance"), selection: Binding(get: { form.maxDistanceKm }, set: { form.maxDistanceKm = $0 })) {
                    ForEach(DatingProfileEditorViewModel.distanceChoices, id: \.self) { km in
                        if let km {
                            Text(String(format: bundle.loc("Within %lld km"), km)).tag(Int?.some(km))
                        } else {
                            Text("Any distance", bundle: bundle).tag(Int?.none)
                        }
                    }
                }
                .pickerStyle(.menu)
            } else if form.locationBlocked {
                DatingLocationRequiredView(isWorking: form.isLocating) {
                    Task<Void, Never>(name: nil) { await form.useCurrentLocation() }
                }
            } else {
                Text("Share your location?", bundle: bundle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Button {
                    Task<Void, Never>(name: nil) { await form.useCurrentLocation() }
                } label: {
                    HStack {
                        Image(systemName: "location.fill")
                        Text("While using the app", bundle: bundle)
                        Spacer()
                        if form.isLocating { ProgressView() }
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(themeManager.theme.primary)
                    .padding(AppSpacing.lg)
                    .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(form.isLocating)
                Button { form.refuseLocation() } label: {
                    HStack {
                        Image(systemName: "location.slash")
                        Text("Don't allow", bundle: bundle)
                        Spacer()
                    }
                    .font(.system(size: 17))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(AppSpacing.lg)
                    .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var photosStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Add photos", "Add 1–6 photos. The first one is shown first; press and hold a photo to make it first.")
            DatingPhotoStrip(form: form, tileSize: CGSize(width: 110, height: 146))
        }
    }

    private var aboutStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("About you", "A few words people see on your card. You can leave it empty.")
            TextField(bundle.loc("A few words about you"), text: Binding(get: { form.bio }, set: { form.bio = $0 }),
                      axis: .vertical)
                .lineLimit(4...8)
                .padding(AppSpacing.md)
                .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 12))
            Text(verbatim: "\(form.bio.count)/\(DatingProfileEditorViewModel.maxBio)")
                .font(.system(size: 12))
                .foregroundColor(form.bio.count > DatingProfileEditorViewModel.maxBio
                                 ? AppColors.danger(colorScheme) : AppColors.textTertiary(colorScheme))
                .padding(.top, AppSpacing.xs)
        }
    }
}
