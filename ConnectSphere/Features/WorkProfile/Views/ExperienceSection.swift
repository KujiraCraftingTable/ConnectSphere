import SwiftUI

/// Work mode's "Experience" on a profile: roles grouped by company with the
/// logo and the total time there, and, for several roles at one company,
/// a timeline of them. Your own profile can add and edit.
struct ExperienceSection: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let userId: String
    let isMe: Bool

    @State private var viewModel = ExperienceListViewModel()
    @State private var editing: EditTarget?
    @State private var showAll = false

    /// nil role = adding a new one.
    struct EditTarget: Identifiable {
        let id = UUID()
        let role: WorkExperience?
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        let groups = viewModel.groups
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Experience", bundle: bundle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Spacer()
                if isMe {
                    Button { editing = EditTarget(role: nil) } label: {
                        Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text(bundle.loc("Add a role")))
                }
            }
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if groups.isEmpty {
                Text(isMe ? bundle.loc("Add the places you've worked and your roles there.")
                          : bundle.loc("No work history yet."))
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            } else {
                ForEach(Array((showAll ? groups : Array(groups.prefix(3))).enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider() }
                    groupView(group)
                }
                if groups.count > 3 {
                    Button(showAll ? bundle.loc("Show less") : String(format: bundle.loc("Show all %lld"), groups.count)) {
                        withAnimation(.snappy) { showAll.toggle() }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(themeManager.theme.primary)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, AppSpacing.sm)
        .task(id: userId) { await viewModel.load(userId: userId, token: token) }
        .sheet(item: $editing) { target in
            ExperienceEditorView(editing: target.role) { viewModel.replace($0) }
        }
    }

    @ViewBuilder
    private func groupView(_ group: WorkExperience.Group) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: group.companyName, imageURL: group.logoUrl, size: .md, shape: .roundedSquare)
            VStack(alignment: .leading, spacing: 4) {
                if group.roles.count == 1, let role = group.roles.first {
                    roleTitle(role)
                    companyLine(group, extra: bundle.loc(role.employmentType.label))
                    dates(role)
                    details(role)
                } else {
                    companyLine(group, extra: WorkMonth.duration(group.totalMonths, loc: bundle.loc), bold: true)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(group.roles.enumerated()), id: \.element.id) { index, role in
                            HStack(alignment: .top, spacing: 10) {
                                // The timeline: a dot per role, joined by a line.
                                VStack(spacing: 0) {
                                    Circle().fill(AppColors.textTertiary(colorScheme)).frame(width: 8, height: 8).padding(.top, 6)
                                    if index < group.roles.count - 1 {
                                        Rectangle().fill(AppColors.borderDefault(colorScheme)).frame(width: 2)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    roleTitle(role)
                                    Text(bundle.loc(role.employmentType.label))
                                        .font(.system(size: 13))
                                        .foregroundColor(AppColors.textSecondary(colorScheme))
                                    dates(role)
                                    details(role)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func roleTitle(_ role: WorkExperience) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(role.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer(minLength: 4)
            if isMe {
                Button { editing = EditTarget(role: role) } label: {
                    Image(systemName: "pencil").font(.system(size: 14))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
                .accessibilityLabel(Text(bundle.loc("Edit")))
            }
        }
    }

    /// The company, a link to its page when there is one, and a note.
    @ViewBuilder
    private func companyLine(_ group: WorkExperience.Group, extra: String, bold: Bool = false) -> some View {
        let label = HStack(spacing: 4) {
            Text(group.companyName)
                .font(.system(size: bold ? 15 : 14, weight: bold ? .semibold : .regular))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            if group.verified { OfficialBadge(compact: true) }
            Text("· " + extra)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        if let id = group.companyId {
            NavigationLink { CompanyPageView(companyId: id) } label: { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }

    private func dates(_ role: WorkExperience) -> some View {
        let start = WorkMonth(role.startMonth)
        let end = role.endMonth.flatMap(WorkMonth.init)
        let from = start?.label(locale: bundle.locale) ?? role.startMonth
        let to = end?.label(locale: bundle.locale) ?? bundle.loc("Present")
        let months = start.map { WorkMonth.span(from: $0, to: end ?? .now) } ?? 1
        return Text("\(from) – \(to) · \(WorkMonth.duration(months, loc: bundle.loc))")
            .font(.system(size: 13))
            .foregroundColor(AppColors.textTertiary(colorScheme))
    }

    @ViewBuilder
    private func details(_ role: WorkExperience) -> some View {
        let place = [role.location, role.locationType.map { bundle.loc($0.label) }].compactMap { $0 }.joined(separator: " · ")
        if !place.isEmpty {
            Text(place)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
        if let text = role.description {
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(4)
                .padding(.top, 2)
        }
    }
}

/// The role form: title, company (a page or a typed name), type, place,
/// months, and what you did.
struct ExperienceEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ExperienceEditorViewModel
    @State private var confirmRemove = false
    @FocusState private var focus: ExperienceEditorViewModel.Field?
    let onSaved: ([WorkExperience]) -> Void

    init(editing: WorkExperience?, onSaved: @escaping ([WorkExperience]) -> Void) {
        _viewModel = State(initialValue: ExperienceEditorViewModel(editing: editing))
        self.onSaved = onSaved
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(bundle.loc("Title (e.g. iOS Engineer)"), text: $viewModel.title)
                        .focused($focus, equals: .title)
                    TextField(bundle.loc("Company"), text: $viewModel.companyName)
                        .focused($focus, equals: .company)
                        .onChange(of: viewModel.companyName) { _, text in viewModel.companyTyped(text, token: token) }
                    if viewModel.companyId != nil {
                        Label(bundle.loc("Linked to the company's page"), systemImage: "link")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.suggestions.prefix(4)) { company in
                        Button { viewModel.pick(company) } label: {
                            HStack(spacing: 10) {
                                Avatar(name: company.name, imageURL: company.logoUrl, size: .sm, shape: .roundedSquare)
                                Text(company.name).foregroundStyle(.primary)
                                if company.isVerified { OfficialBadge(compact: true) }
                            }
                        }
                    }
                    Picker(bundle.loc("Employment type"), selection: $viewModel.employmentType) {
                        ForEach(WorkExperience.EmploymentKind.allCases, id: \.self) { Text(bundle.loc($0.label)).tag($0) }
                    }
                } footer: {
                    problems(viewModel.titleProblem, viewModel.companyProblem)
                }
                Section {
                    LocationSearchField(bundle.loc("Location (e.g. Ho Chi Minh City)"), text: $viewModel.location)
                    Picker(bundle.loc("Work format"), selection: $viewModel.locationType) {
                        Text("Not set", bundle: bundle).tag(WorkExperience.LocationKind?.none)
                        ForEach(WorkExperience.LocationKind.allCases, id: \.self) {
                            Text(bundle.loc($0.label)).tag(WorkExperience.LocationKind?.some($0))
                        }
                    }
                } footer: {
                    problems(viewModel.locationProblem)
                }
                Section {
                    Toggle(bundle.loc("I currently work here"), isOn: $viewModel.isCurrent)
                    MonthYearPicker(title: bundle.loc("Start"), month: $viewModel.start)
                    if !viewModel.isCurrent {
                        MonthYearPicker(title: bundle.loc("End"), month: $viewModel.end)
                    }
                } footer: {
                    problems(viewModel.dateProblem)
                }
                Section {
                    TextField(bundle.loc("Responsibilities, results…"), text: $viewModel.description, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("What you did", bundle: bundle)
                } footer: {
                    problems(viewModel.descriptionProblem)
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if viewModel.editing != nil {
                    Section {
                        Button(bundle.loc("Remove this role"), role: .destructive) { confirmRemove = true }
                    }
                }
            }
            .onChange(of: focus) { left, _ in if let left { viewModel.touched.insert(left) } }
            .navigationTitle(bundle.loc(viewModel.editing == nil ? "Add a role" : "Edit role"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ConfirmCancelButton(hasChanges: viewModel.hasChanges) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Button(bundle.loc("Save")) {
                            Task {
                                guard let list = await viewModel.save(token: token) else { return }
                                onSaved(list)
                                dismiss()
                            }
                        }
                        .disabled(!viewModel.canSave)
                    }
                }
            }
            .alert(bundle.loc("Remove this role?"), isPresented: $confirmRemove) {
                Button(bundle.loc("Remove"), role: .destructive) {
                    Task {
                        guard let list = await viewModel.remove(token: token) else { return }
                        onSaved(list)
                        dismiss()
                    }
                }
                Button(bundle.loc("Cancel"), role: .cancel) {}
            }
        }
    }
}

extension ExperienceEditorView {
    /// What's wrong in a section, in red under it.
    @ViewBuilder
    fileprivate func problems(_ messages: String?...) -> some View {
        let shown = messages.compactMap { $0 }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                // Not a Label, Form rows drop a Label's text.
                ForEach(shown, id: \.self) { message in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(message)
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.red)
        }
    }
}

/// Month and year wheels for a role's start or end.
struct MonthYearPicker: View {
    @Environment(\.appBundle) private var bundle
    let title: String
    @Binding var month: WorkMonth

    private var years: [Int] { Array((1970...WorkMonth.now.year).reversed()) }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: Binding(get: { month.month }, set: { month = WorkMonth(year: month.year, month: $0) })) {
                ForEach(1...12, id: \.self) { m in
                    Text(WorkMonth(year: 2000, month: m).label(locale: bundle.locale).components(separatedBy: " ").first ?? "\(m)")
                        .tag(m)
                }
            }
            .labelsHidden()
            Picker("", selection: Binding(get: { month.year }, set: { month = WorkMonth(year: $0, month: month.month) })) {
                ForEach(years, id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden()
        }
    }
}

/// A company page's People tab: who works there now (from work history).
struct CompanyPeopleList: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let companyId: String
    @State private var viewModel = CompanyPeopleViewModel()

    var body: some View {
        VStack(spacing: 8) {
            if !viewModel.loaded {
                ProgressView().padding(32)
            } else if viewModel.people.isEmpty {
                Text("People who list this company in their work history will show here.", bundle: bundle)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .multilineTextAlignment(.center)
                    .padding(32)
            } else {
                ForEach(viewModel.people) { person in
                    NavigationLink { UserProfileView(userId: person.id) } label: {
                        HStack(spacing: 12) {
                            Avatar(name: person.displayName, colorHex: person.avatarColor, imageURL: person.avatarUrl, size: .md)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.displayName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                Text(person.title)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                                if let since = WorkMonth(person.since) {
                                    Text(String(format: bundle.loc("Since %@"), since.label(locale: bundle.locale)))
                                        .font(.system(size: 12))
                                        .foregroundColor(AppColors.textTertiary(colorScheme))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .task { await viewModel.load(companyId: companyId, token: appState.authToken ?? "") }
    }
}
