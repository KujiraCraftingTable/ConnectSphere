import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var step    = 0
    @State private var form    = OnboardingForm()
    @State private var isLoading = false
    @State private var error: String? = nil
    @State private var selectedInterests: [InterestItem] = []
    @State private var showProvincePicker = false

    // Realtime username availability (only checks username — display_name doesn't need it
    // since many people can share the same name, only username needs to be unique).
    @State private var usernameAvailability: UsernameAvailability = .idle
    @State private var usernameCheckTask: Task<Void, Never>?

    private enum UsernameAvailability: Equatable {
        case idle, checking, available, taken
    }

    private let totalSteps = 4

    var body: some View {
        ZStack {
            AppColors.base(.light).ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress bar
                progressBar.padding(.horizontal, 24).padding(.top, 16)

                // Step content — a plain switch, not a swipeable TabView, so the
                // user can't swipe past a step's required-field validation and
                // submit an incomplete form. Navigation is Next/Back only.
                Group {
                    switch step {
                    case 0:  step0
                    case 1:  step1
                    case 2:  step2
                    default: step3
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .animation(.easeInOut, value: step)
            }
        }
    }

    // MARK: Progress

    private var progressBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Set up profile", bundle: bundle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary(.light))
                Spacer()
                Text("\(step + 1)/\(totalSteps)")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(.light))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColors.borderDefault(.light)).frame(height: 4)
                    Capsule()
                        .fill(themeManager.theme.primary)
                        .frame(width: geo.size.width * CGFloat(step + 1) / CGFloat(totalSteps), height: 4)
                        .animation(.spring(), value: step)
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
        let selected = form.default_mode == mode
        return Button { form.default_mode = mode } label: {
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

    private var step1: some View {
        OnboardingCard(title: bundle.loc("Basic information"), subtitle: bundle.loc("Enter your display name and username")) {
            VStack(spacing: 14) {
                AuthTextField(icon: "textformat", placeholder: bundle.loc("Display name *"), text: $form.display_name)

                VStack(alignment: .leading, spacing: 6) {
                    AuthTextField(icon: "at", placeholder: bundle.loc("Username * (a-z, 0-9, _ only)"), text: Binding(
                        get: { form.username },
                        set: {
                            form.username = $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
                            scheduleUsernameCheck(form.username)
                        }
                    ))
                    usernameStatusView
                }

                // Province picker (required)
                Button { showProvincePicker = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle")
                            .foregroundColor(AppColors.textSecondary(.light))
                        Text(selectedProvinceDisplay)
                            .foregroundColor(form.location.isEmpty
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
                    ProvincePickerSheet(selectedId: $form.location)
                }

                // Gender picker (required)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gender *", bundle: bundle)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(.light))
                    HStack(spacing: 10) {
                        ForEach([("male", "Male"), ("female", "Female"), ("other", "Other")], id: \.0) { value, label in
                            let selected = form.gender == value
                            Button { form.gender = value } label: {
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar").foregroundColor(AppColors.textSecondary(.light))
                        Text(form.dob.isEmpty ? bundle.loc("Date of birth *") : String(format: bundle.loc("Date of birth: %@"), form.dob))
                            .foregroundColor(form.dob.isEmpty ? AppColors.textTertiary(.light) : AppColors.textPrimary(.light))
                            .font(.system(size: 15))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(AppColors.surface(.light))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        DatePicker("", selection: Binding(
                            get: { dobDate },
                            set: { form.dob = dobFormatter.string(from: $0) }
                        ), displayedComponents: .date)
                        .blendMode(.destinationOver)
                        .padding(.horizontal, 8)
                    )
                }

                // Who can see the age — defaults to Private, doesn't affect age-based search
                DobVisibilityToggle(visibility: $form.dob_visibility, accentColor: themeManager.theme.primary)
            }

            if let e = error { errorBanner(e) }

            nextButton(
                enabled: !form.display_name.trimmingCharacters(in: .whitespaces).isEmpty &&
                         form.username.count >= 3 &&
                         usernameAvailability != .taken &&
                         !form.location.isEmpty &&
                         !form.gender.isEmpty &&
                         !form.dob.isEmpty,
                label: bundle.loc("Continue")
            )
        }
    }

    /// Availability status shown right below the username field: checking / taken / available.
    @ViewBuilder
    private var usernameStatusView: some View {
        switch usernameAvailability {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Checking availability...", bundle: bundle)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary(.light))
            }
            .padding(.leading, 4)
        case .available:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(AppColors.success(.light))
                Text("Username available", bundle: bundle)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.success(.light))
            }
            .padding(.leading, 4)
        case .taken:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Username already taken", bundle: bundle)
                    .font(.system(size: 12))
            }
            .foregroundColor(AppColors.danger(.light))
            .padding(.leading, 4)
        }
    }

    /// Debounces for 500ms then calls the check-username API; cancels the previous run if still in flight.
    private func scheduleUsernameCheck(_ username: String) {
        usernameCheckTask?.cancel()
        guard username.count >= 3 else {
            usernameAvailability = .idle
            return
        }
        usernameAvailability = .checking
        usernameCheckTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let token = appState.authToken else { return }
            do {
                let available = try await AuthService.shared.checkUsernameAvailable(token: token, username: username)
                guard !Task.isCancelled else { return }
                usernameAvailability = available ? .available : .taken
            } catch {
                guard !Task.isCancelled else { return }
                usernameAvailability = .idle
            }
        }
    }

    private var selectedProvinceDisplay: String {
        guard !form.location.isEmpty else { return bundle.loc("Province / City *") }
        return VietnamProvinces.all.first(where: { $0.id == form.location })?.displayName ?? form.location
    }

    // MARK: Step 2 — Interests / Skills

    private var step2: some View {
        OnboardingCard(
            title: form.default_mode == "hobby" ? bundle.loc("Your interests") : bundle.loc("Skills & Company"),
            subtitle: bundle.loc("Help ConnectSphere find the right people for you")
        ) {
            if form.default_mode == "hobby" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select what you like", bundle: bundle)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(.light))
                    InterestPickerView(selectedInterests: $selectedInterests)
                }
            } else {
                VStack(spacing: 14) {
                    AuthTextField(icon: "briefcase", placeholder: bundle.loc("Job title (iOS Developer...)"), text: $form.job_title)
                    AuthTextField(icon: "building.2", placeholder: bundle.loc("Company / School"), text: $form.company)
                    AuthTextField(icon: "sparkles", placeholder: bundle.loc("Skills (Swift, Python, UI/UX...)"), text: Binding(
                        get: { form.skills.joined(separator: ", ") },
                        set: { form.skills = $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    ))
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
                if form.bio.isEmpty {
                    Text("e.g. iOS Developer | Love coffee and anime ☕🌸", bundle: bundle)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textDisabled(.light))
                        .padding(14)
                }
                TextEditor(text: $form.bio)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(.light))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: 120)
                    .padding(8)
            }
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColors.borderDefault(.light), lineWidth: 1))

            if let e = error { errorBanner(e) }

            GradientButton(title: isLoading ? bundle.loc("Saving...") : bundle.loc("Complete 🎉"), isLoading: isLoading) {
                Task { await finish() }
            }
        }
    }

    // MARK: Helpers

    private func nextButton(enabled: Bool, label: String) -> some View {
        GradientButton(title: label, isLoading: false) {
            withAnimation { step = min(step + 1, totalSteps - 1) }
        }
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
        dobFormatter.date(from: form.dob) ?? Calendar.current.date(byAdding: .year, value: -20, to: Date())!
    }

    private let dobFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private func finish() async {
        // Sync selectedInterests → form.interests
        form.interests = selectedInterests.map { $0.displayText }

        isLoading = true
        error = nil
        do {
            try await appState.completeOnboarding(form: form)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
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
