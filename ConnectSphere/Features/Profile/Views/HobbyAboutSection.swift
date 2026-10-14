import SwiftUI

/// A Hobby profile's "About": relationship, languages and education. Your
/// own profile can add and edit schools here (languages and relationship are
/// in Edit profile).
struct HobbyAboutSection: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let user: UserProfile
    let isMe: Bool

    @State private var viewModel = EducationListViewModel()
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable {
        let id = UUID()
        let school: Education?
    }

    private var token: String { appState.authToken ?? "" }
    private var relationship: RelationshipStatus? { user.relationshipStatus.flatMap(RelationshipStatus.init(rawValue:)) }
    private var isEmpty: Bool { relationship == nil && user.languages.isEmpty && viewModel.schools.isEmpty }

    var body: some View {
        Group {
            // Someone else's empty About isn't shown at all.
            if isMe || !isEmpty || !viewModel.loaded {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("About", bundle: bundle)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Spacer()
                        if isMe {
                            Button { editing = EditTarget(school: nil) } label: {
                                Label(bundle.loc("Add school"), systemImage: "plus")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                    }
                    if let relationship {
                        row(icon: "heart.fill", text: bundle.loc(relationship.label))
                    }
                    if !user.languages.isEmpty {
                        row(icon: "globe", text: user.languages
                            .map { ProfileLanguages.name($0, locale: bundle.locale) }.joined(separator: ", "))
                    }
                    ForEach(viewModel.schools) { school in
                        Button { if isMe { editing = EditTarget(school: school) } } label: { schoolRow(school) }
                            .buttonStyle(.plain)
                            .disabled(!isMe)
                    }
                    if isMe && isEmpty && viewModel.loaded {
                        Text("Add where you studied, the languages you speak and your relationship status.", bundle: bundle)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                .padding(16)
                .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, AppSpacing.sm)
            }
        }
        .task(id: user.id) { await viewModel.load(userId: user.id, token: token) }
        .sheet(item: $editing) { target in
            EducationEditorView(editing: target.school) { viewModel.replace($0) }
        }
    }

    private func row(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .frame(width: 22)
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(AppColors.textPrimary(colorScheme))
        }
    }

    private func schoolRow(_ school: Education) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: school.schoolType == .highSchool ? "book.closed.fill" : "graduationcap.fill")
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(school.schoolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                let detail = [school.major, school.yearsText(loc: bundle.loc)].compactMap { $0 }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            Spacer(minLength: 0)
            if isMe {
                Image(systemName: "pencil").font(.system(size: 13)).foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        .contentShape(Rectangle())
    }
}

/// Add or edit a school: name (from the built-in list, or typed), type,
/// major and years.
struct EducationEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: EducationEditorViewModel
    @State private var confirmRemove = false
    let onSaved: ([Education]) -> Void

    init(editing: Education?, onSaved: @escaping ([Education]) -> Void) {
        _viewModel = State(initialValue: EducationEditorViewModel(editing: editing))
        self.onSaved = onSaved
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(bundle.loc("School"), text: $viewModel.schoolName)
                        .autocorrectionDisabled()
                    ForEach(viewModel.suggestions, id: \.self) { school in
                        Button { viewModel.schoolName = school } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "graduationcap").foregroundStyle(.secondary)
                                Text(school).foregroundStyle(.primary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Picker(bundle.loc("Type"), selection: $viewModel.schoolType) {
                        ForEach(Education.SchoolType.allCases, id: \.self) { Text(bundle.loc($0.label)).tag($0) }
                    }
                    TextField(bundle.loc("Major or class (optional)"), text: $viewModel.major)
                } footer: {
                    Text("Pick from the list, or type your school's name.", bundle: bundle)
                }
                Section {
                    yearPicker(bundle.loc("From"), selection: $viewModel.startYear)
                    yearPicker(bundle.loc("To (or expected)"), selection: $viewModel.endYear)
                } footer: {
                    if let problem = viewModel.yearsProblem {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(problem)
                        }
                        .font(.footnote)
                        .foregroundStyle(.red)
                    }
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if viewModel.editing != nil {
                    Section {
                        Button(bundle.loc("Remove this school"), role: .destructive) { confirmRemove = true }
                    }
                }
            }
            .navigationTitle(bundle.loc(viewModel.editing == nil ? "Add school" : "Edit school"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Cancel")) { dismiss() } }
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
            .alert(bundle.loc("Remove this school?"), isPresented: $confirmRemove) {
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

    private func yearPicker(_ title: String, selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("Not set", bundle: bundle).tag(Int?.none)
            ForEach(EducationEditorViewModel.years(), id: \.self) { Text(String($0)).tag(Int?.some($0)) }
        }
    }
}

/// Pick the languages you speak (searchable, several).
struct LanguagesPickerView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: [String]
    @State private var query = ""

    private var codes: [String] {
        let all = ProfileLanguages.codes
        guard !query.isEmpty else { return all }
        let q = SchoolCatalog.fold(query)
        return all.filter { SchoolCatalog.fold(ProfileLanguages.name($0, locale: bundle.locale)).contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(codes, id: \.self) { code in
                Button {
                    if let i = selected.firstIndex(of: code) { selected.remove(at: i) }
                    else if selected.count < 10 { selected.append(code) }
                } label: {
                    HStack {
                        Text(ProfileLanguages.name(code, locale: bundle.locale)).foregroundStyle(.primary)
                        Spacer()
                        if selected.contains(code) { Image(systemName: "checkmark").foregroundStyle(themeManager.theme.primary) }
                    }
                }
            }
            .searchable(text: $query, prompt: bundle.loc("Search languages"))
            .navigationTitle(bundle.loc("Languages"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(bundle.loc("Done")) { dismiss() } }
            }
        }
    }
}
