import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = OnboardingViewModel()
    @State private var emailCode = EmailVerificationViewModel(replacingVerifiedEmail: false)
    @State private var showProvincePicker = false
    @State private var showDobPicker = false
    @State private var dobDraft = Date()
    /// Bumped on a blocked forward swipe/tap — drives the shake + haptic.
    @State private var blockedAttempts = 0

    private let totalSteps = OnboardingViewModel.totalSteps

    var body: some View {
        ZStack {
            AppColors.base(.light).ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress bar
                progressBar.padding(.horizontal, 24).padding(.top, 16)

                // Step content. Swiping right-to-left goes on, left-to-right goes
                // back; going on is refused (shake) until the step's required
                // fields are filled, so an incomplete form can't be submitted.
                ZStack {
                    stepContent
                        .id(viewModel.step)
                        .transition(.asymmetric(
                            insertion: .move(edge: viewModel.movedForward ? .trailing : .leading),
                            removal: .move(edge: viewModel.movedForward ? .leading : .trailing)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .modifier(ShakeEffect(shakes: CGFloat(blockedAttempts)))
                .sensoryFeedback(.error, trigger: blockedAttempts)
                .gesture(StepSwipe(direction: .left, action: goForward))
                .gesture(StepSwipe(direction: .right, action: goBack))
            }
        }
        .onAppear {
            viewModel.prefill(username: appState.currentUser?.username,
                              hasPassword: appState.currentUser?.hasPassword ?? true)
            viewModel.prefillEmail(appState.currentUser?.email, verified: appState.currentUser?.emailVerified ?? false)
            // The email given at sign-up, ready for its code.
            if emailCode.email.isEmpty, let email = appState.currentUser?.email { emailCode.email = email }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.step {
        case 0:  step0
        case 1:  step1
        case 2:  step2
        default: step3
        }
    }

    private func goForward() {
        guard viewModel.step < totalSteps - 1 else { return }
        if viewModel.canAdvance {
            withAnimation(.snappy) { _ = viewModel.next() }
        } else {
            withAnimation(.linear(duration: 0.35)) { blockedAttempts += 1 }
        }
    }

    private func goBack() {
        withAnimation(.snappy) { viewModel.back() }
    }

    // MARK: Progress

    private var progressBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if viewModel.canGoBack {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary(.light))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Back", bundle: bundle))
                }
                Text("Set up profile", bundle: bundle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary(.light))
                Spacer()
                Text("\(viewModel.step + 1)/\(totalSteps)")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(.light))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColors.borderDefault(.light)).frame(height: 4)
                    Capsule()
                        .fill(themeManager.theme.primary)
                        .frame(width: geo.size.width * CGFloat(viewModel.step + 1) / CGFloat(totalSteps), height: 4)
                        .animation(.spring(), value: viewModel.step)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: Step 0 — Mode selection

    private var step0: some View {
        OnboardingCard(title: bundle.loc("What do you want to use ConnectSphere for?"),
                       subtitle: bundle.loc("You can change this later")) {
            VStack(spacing: 14) {
                modeCard(mode: "hobby", icon: "person.2.fill",
                         title: bundle.loc("Friends & Fun"),
                         desc: bundle.loc("Find friends, share interests"),
                         color: themeManager.theme.primary)
                modeCard(mode: "work", icon: "briefcase.fill",
                         title: bundle.loc("Work & Study"),
                         desc: bundle.loc("Networking, find collaborators"),
                         color: themeManager.theme.primary)
            }
            nextButton(enabled: true, label: bundle.loc("Continue"))
        }
    }

    private func modeCard(mode: String, icon: String, title: String, desc: String, color: Color) -> some View {
        let selected = viewModel.form.default_mode == mode
        return Button { viewModel.form.default_mode = mode } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(color.opacity(0.15)).frame(width: 50, height: 50)
                    Image(systemName: icon).font(.system(size: 22)).foregroundColor(color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(AppColors.textPrimary(.light))
                    Text(desc).font(.system(size: 13)).foregroundColor(AppColors.textSecondary(.light))
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22)).foregroundColor(color)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? themeManager.theme.primary.opacity(0.14) : AppColors.elevated(.light))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(selected ? color : Color.clear, lineWidth: 2))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 1 — Basic info

    /// Email (required): a 6-digit code proves it's theirs before Continue.
    @ViewBuilder
    private var emailBlock: some View {
        if viewModel.emailVerified {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text(viewModel.verifiedEmail ?? "")
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(.light))
                    .lineLimit(1)
                Spacer()
                Text("Verified", bundle: bundle).font(.system(size: 13)).foregroundColor(.green)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppColors.surface(.light), in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                AuthTextField(icon: "envelope", placeholder: bundle.loc("Email *"), text: $emailCode.email,
                              keyboardType: .emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(emailCode.sentTo != nil)
                if emailCode.sentTo == nil {
                    Button(bundle.loc("Send code")) { Task { await emailCode.sendCode(token: appState.authToken ?? "") } }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(themeManager.theme.primary)
                        .disabled(emailCode.email.trimmingCharacters(in: .whitespaces).isEmpty || emailCode.isSending)
                } else {
                    Text(String(format: bundle.loc("We sent a code to %@. It expires in 10 minutes."), emailCode.sentTo ?? ""))
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(.light))
                    AuthTextField(icon: "number", placeholder: bundle.loc("6-digit code"), text: $emailCode.code,
                                  keyboardType: .numberPad)
                        .textContentType(.oneTimeCode)
                    HStack {
                        ResendButton(availableAt: emailCode.resendAt, isSending: emailCode.isSending) {
                            Task { await emailCode.sendCode(token: appState.authToken ?? "") }
                        }
                        Spacer()
                        Button(bundle.loc("Verify")) {
                            Task {
                                if let email = await emailCode.verify(token: appState.authToken ?? "") {
                                    viewModel.emailVerified = true
                                    viewModel.verifiedEmail = email
                                    appState.currentUser?.email = email
                                    appState.currentUser?.emailVerified = true
                                }
                            }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .disabled(!emailCode.canVerify)
                    }
                }
                if let error = emailCode.errorMessage {
                    Text(error).font(.system(size: 13)).foregroundColor(AppColors.danger(.light))
                }
            }
        }
    }

    private var step1: some View {
        OnboardingCard(title: bundle.loc("Basic information"), subtitle: bundle.loc("Enter your display name")) {
            VStack(spacing: 14) {
                if viewModel.needsUsername { usernameField }

                AuthTextField(icon: "textformat", placeholder: bundle.loc("Display name *"), text: $viewModel.form.display_name,
                              characterLimit: DisplayNameRules.maxLength)

                emailBlock

                // Province picker (required)
                Button { showProvincePicker = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle")
                            .foregroundColor(AppColors.textSecondary(.light))
                        Text(selectedProvinceDisplay)
                            .foregroundColor(viewModel.form.location.isEmpty
                                ? AppColors.textTertiary(.light)
                                : AppColors.textPrimary(.light))
                            .font(.system(size: 15))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary(.light))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(AppColors.surface(.light))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showProvincePicker) {
                    // Sheets don't inherit the screen's forced light scheme.
                    ProvincePickerSheet(selectedId: $viewModel.form.location)
                        .preferredColorScheme(.light)
                }

                // Gender picker (required)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gender *", bundle: bundle)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(.light))
                    HStack(spacing: 10) {
                        ForEach([("male", "Male"), ("female", "Female"), ("other", "Other")], id: \.0) { value, label in
                            let selected = viewModel.form.gender == value
                            Button { viewModel.form.gender = value } label: {
                                Text(bundle.loc(label))
                                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                                    .foregroundColor(selected ? .white : AppColors.textSecondary(.light))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(selected ? themeManager.theme.primary : AppColors.surface(.light))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // DOB (required)
                Button {
                    dobDraft = dobDate
                    showDobPicker = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar").foregroundColor(AppColors.textSecondary(.light))
                        Text(viewModel.form.dob.isEmpty ? bundle.loc("Date of birth *") : String(format: bundle.loc("Date of birth: %@"), viewModel.form.dob))
                            .foregroundColor(viewModel.form.dob.isEmpty ? AppColors.textTertiary(.light) : AppColors.textPrimary(.light))
                            .font(.system(size: 15))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(AppColors.surface(.light))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showDobPicker) {
                    dobPickerSheet
                        .preferredColorScheme(.light)
                }

                // Who can see the age — defaults to Private, doesn't affect age-based search
                DobVisibilityToggle(visibility: $viewModel.form.dob_visibility, accentColor: themeManager.theme.primary)
            }

            if let e = viewModel.errorMessage { errorBanner(e) }

            nextButton(
                enabled: viewModel.canAdvance,
                label: bundle.loc("Continue")
            )
        }
    }

    /// Google accounts only: choose the @name people find you by.
    private var usernameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AuthTextField(icon: "at", placeholder: bundle.loc("Username *"), text: $viewModel.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            usernameStatusLine
                .font(.system(size: 12))
                .padding(.leading, 4)
        }
        .task(id: viewModel.form.username) { await viewModel.checkUsername(token: appState.authToken) }
    }

    @ViewBuilder
    private var usernameStatusLine: some View {
        if let problem = viewModel.usernameProblem {
            Text(problem).foregroundColor(AppColors.danger(.light))
        } else {
            switch viewModel.usernameStatus {
            case .checking:
                Text("Checking…", bundle: bundle).foregroundColor(AppColors.textTertiary(.light))
            case .available:
                Label(bundle.loc("Username available"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(AppColors.success(.light))
            case .taken:
                Text("That username is taken", bundle: bundle).foregroundColor(AppColors.danger(.light))
            case .failed:
                Text("Couldn't check the username — try again", bundle: bundle).foregroundColor(AppColors.danger(.light))
            case .idle:
                Text(UsernameRules.hint).foregroundColor(AppColors.textTertiary(.light))
            }
        }
    }

    private var selectedProvinceDisplay: String {
        guard !viewModel.form.location.isEmpty else { return bundle.loc("Province / City *") }
        return VietnamProvinces.all.first(where: { $0.id == viewModel.form.location })?.displayName ?? viewModel.form.location
    }

    // MARK: Step 2 — Interests / Skills

    private var step2: some View {
        OnboardingCard(
            title: viewModel.form.default_mode == "hobby" ? bundle.loc("Your interests") : bundle.loc("Skills & Company"),
            subtitle: bundle.loc("Help ConnectSphere find the right people for you")
        ) {
            if viewModel.form.default_mode == "hobby" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select what you like", bundle: bundle)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(.light))
                    InterestPickerView(selectedInterests: $viewModel.selectedInterests)
                }
            } else {
                VStack(spacing: 14) {
                    AuthTextField(icon: "briefcase", placeholder: bundle.loc("Job title (iOS Developer...)"), text: $viewModel.form.job_title)
                    AuthTextField(icon: "building.2", placeholder: bundle.loc("Company / School"), text: $viewModel.form.company)
                    SkillTagField(skills: $viewModel.form.skills, colorScheme: .light, boxed: true)
                }
            }

            nextButton(enabled: true, label: bundle.loc("Continue"))
        }
    }

    // MARK: Step 3 — Bio + finish

    private var step3: some View {
        OnboardingCard(title: bundle.loc("About yourself"), subtitle: bundle.loc("Write a few lines so people know who you are")) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppColors.surface(.light))
                    .frame(minHeight: 120)
                if viewModel.form.bio.isEmpty {
                    Text("e.g. iOS Developer | Love coffee and anime ☕🌸", bundle: bundle)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textDisabled(.light))
                        .padding(14)
                }
                TextEditor(text: $viewModel.form.bio)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(.light))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: 120)
                    .padding(8)
            }
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColors.borderDefault(.light), lineWidth: 1))

            if let e = viewModel.errorMessage { errorBanner(e) }

            GradientButton(title: viewModel.isLoading ? bundle.loc("Saving...") : bundle.loc("Complete 🎉"), isLoading: viewModel.isLoading) {
                Task { await viewModel.finish(appState: appState) }
            }

            // Bio is optional — finish() never validates it — but nothing
            // on screen said so, so people got stuck typing something
            // just to get past this step. Same action as Complete, just
            // a second, lower-emphasis entry point that makes "leave this
            // blank" an obvious, explicit choice.
            Button {
                Task { await viewModel.finish(appState: appState) }
            } label: {
                Text("Skip for now", bundle: bundle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppColors.textSecondary(.light))
            }
            .disabled(viewModel.isLoading)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }

    // MARK: Helpers

    private func nextButton(enabled: Bool, label: String) -> some View {
        GradientButton(title: label, isLoading: false) { goForward() }
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(msg).font(.system(size: 13))
        }
        .foregroundColor(AppColors.danger(.light))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.danger(.light).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var dobDate: Date {
        dobFormatter.date(from: viewModel.form.dob) ?? Calendar.current.date(byAdding: .year, value: -20, to: Date())!
    }

    private let dobFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private var dobPickerSheet: some View {
        NavigationStack {
            DatePicker("", selection: $dobDraft, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding()
                .navigationTitle(bundle.loc("Date of birth"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(bundle.loc("Done")) {
                            viewModel.form.dob = dobFormatter.string(from: dobDraft)
                            showDobPicker = false
                        }
                    }
                }
        }
        .presentationDetents([.height(340)])
    }
}

// MARK: - Onboarding Card container

struct OnboardingCard<Content: View>: View {
    let title:    String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(AppColors.textPrimary(.light))
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(.light))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 28)
                .padding(.bottom, 24)

                GlassCard {
                    VStack(spacing: 16) { content() }.padding(24)
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 40)
            }
        }
        .preferredColorScheme(.light)
    }
}

// MARK: - Province picker sheet

struct ProvincePickerSheet: View {
    @Binding var selectedId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) var bundle
    @State private var searchText = ""

    private var filtered: [Province] {
        if searchText.isEmpty { return VietnamProvinces.all }
        let q = searchText.lowercased()
        return VietnamProvinces.all.filter {
            $0.displayName.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { province in
                Button {
                    selectedId = province.id
                    dismiss()
                } label: {
                    HStack {
                        Text(province.displayName)
                            .foregroundColor(.primary)
                        Spacer()
                        if selectedId == province.id {
                            Image(systemName: "checkmark")
                                .foregroundColor(themeManager.theme.primary)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: bundle.loc("Search province / city"))
            .navigationTitle(bundle.loc("Select province / city"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
            }
        }
    }
}

/// Horizontal wobble, one full shake per unit of `shakes`.
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(shakes * .pi * 4), y: 0))
    }
}

/// A step-to-step page swipe. UIKit's swipe recognizer rather than a SwiftUI
/// `DragGesture`: it only ever fires on a horizontal flick, so the step's own
/// vertical scrolling is untouched, and taps underneath wait for it to fail —
/// a swipe that starts on a full-width row (Province, Date of birth) no
/// longer also taps it open.
private struct StepSwipe: UIGestureRecognizerRepresentable {
    let direction: UISwipeGestureRecognizer.Direction
    let action: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UISwipeGestureRecognizer {
        let recognizer = UISwipeGestureRecognizer()
        recognizer.direction = direction
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The step's scroll view grabs every pan first; without this the
        /// swipe never got to recognize at all.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// Taps underneath (a row's button) wait until this swipe has failed —
        /// which a plain tap does the moment the finger lifts — so a swipe
        /// starting on the Province row no longer also opens its picker.
        /// Scrolling is left alone so it never waits on the swipe.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            !(other is UIPanGestureRecognizer) && !(other is UISwipeGestureRecognizer)
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UISwipeGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action() }
    }
}
