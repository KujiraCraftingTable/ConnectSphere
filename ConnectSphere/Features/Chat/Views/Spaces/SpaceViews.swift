import SwiftUI

// MARK: - Explainer

/// Shown in Messages while the Spaces view is on and the user has no spaces
/// yet, says what a space is (a folder for people) before asking for anything.
struct SpacesIntroCard: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                SpacePlanetIcon(color: themeManager.theme.primary, size: 22)
                    .frame(width: 36, height: 36)
                    .background(themeManager.theme.primary.opacity(0.14), in: Circle())
                Text("Organise chats with Spaces", bundle: bundle)
                    .scaledFont(16, .bold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            Text("Spaces work like folders. Make one, add people and group chats to it, and those chats are kept together there.", bundle: bundle)
                .scaledFont(14)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            Label(bundle.loc("Only you can see your spaces."), systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .scaledFont(12, .medium)
                .foregroundColor(AppColors.textTertiary(colorScheme))

            Button(action: onCreate) {
                Label(bundle.loc("Create your first space"), systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .scaledFont(15, .semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(themeManager.theme.primary, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.lg)
        .cardStyle()
        .padding(.horizontal, AppSpacing.sm)
        .padding(.top, AppSpacing.sm)
    }
}

// MARK: - Name + colour

/// Create a space, or edit one's name and colour.
struct SpaceEditorSheet: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let title: String
    let confirmTitle: String
    var initialName = ""
    var initialColor: SpaceColor = .blue
    var isSaving = false
    /// Return false to keep the sheet open (e.g. the name is taken).
    let onSave: (String, SpaceColor) async -> Bool

    @State private var name = ""
    @State private var color: SpaceColor = .blue
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty && trimmed.count <= 30 && !isSaving }
    /// A new Space starts blank; renaming starts from the current name and colour.
    private var hasChanges: Bool { trimmed != initialName.trimmingCharacters(in: .whitespacesAndNewlines) || color != initialColor }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                // The name is typed straight into the title, beside its planet.
                HStack(spacing: 10) {
                    SpacePlanetIcon(color: color.color, size: 26)
                    TextField(bundle.loc("Space name"), text: $name)
                        .scaledFont(22, .bold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onChange(of: name) { _, new in if new.count > 30 { name = String(new.prefix(30)) } }
                }
                .padding(.bottom, AppSpacing.sm)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(nameFocused ? color.color : AppColors.borderDefault(colorScheme))
                        .frame(height: nameFocused ? 2 : 1)
                }

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("Colour", bundle: bundle)
                        .scaledFont(13, .semibold)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                    // 24 colours: three rows of eight, in hue order.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 10) {
                        ForEach(SpaceColor.allCases) { option in
                            Button { color = option } label: {
                                // Unselected: a plain dot. Selected: a ring around it
                                // and a check, so the choice stands out among 24.
                                ZStack {
                                    Circle().fill(option.color).frame(width: 28, height: 28)
                                    if option == color {
                                        Circle().stroke(option.color, lineWidth: 2.5).frame(width: 36, height: 36)
                                        Image(systemName: "checkmark")
                                            .scaledFont(12, .bold)
                                            .foregroundColor(.white)
                                    }
                                }
                                .frame(width: 38, height: 38)
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(bundle.loc(option.label)))
                            .accessibilityAddTraits(option == color ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    .sensoryFeedback(.selection, trigger: color)
                }
                Spacer()
            }
            .padding(AppSpacing.lg)
            .background(AppColors.base(colorScheme))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ConfirmCancelButton(hasChanges: hasChanges) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        Task { if await onSave(trimmed, color) { dismiss() } }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            name = initialName
            color = initialColor
            nameFocused = initialName.isEmpty
        }
    }
}

// MARK: - People and groups

/// Choose who's in a space: people you chat with in this mode plus your
/// connections, and your group chats. Ids already in the space but not
/// listed (e.g. someone you no longer chat with) are kept as they are rather
/// than silently dropped.
struct SpacePeoplePickerView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let spaceName: String
    let people: [SpaceCandidate]
    let groups: [SpaceCandidate]
    let initialPeople: [String]
    let initialGroups: [String]
    /// People ids, then group ids. Return false to keep the sheet open.
    let onDone: ([String], [String]) async -> Bool

    @State private var selectedPeople: Set<String> = []
    @State private var selectedGroups: Set<String> = []
    @State private var query = ""

    private func matching(_ list: [SpaceCandidate]) -> [SpaceCandidate] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if people.isEmpty && groups.isEmpty {
                    EmptyStateView(systemImage: "person.2",
                                   title: bundle.loc("No one to add yet"),
                                   message: bundle.loc("Start a chat or connect with someone, then add them here."))
                } else {
                    List {
                        let shownPeople = matching(people)
                        if !shownPeople.isEmpty {
                            Section(bundle.loc("People")) {
                                ForEach(shownPeople) { candidateRow($0, selection: $selectedPeople) }
                            }
                        }
                        let shownGroups = matching(groups)
                        if !shownGroups.isEmpty {
                            Section(bundle.loc("Groups")) {
                                ForEach(shownGroups) { candidateRow($0, selection: $selectedGroups) }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $query, prompt: bundle.loc("Search people and groups"))
                }
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(spaceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(spaceName).scaledFont(16, .semibold)
                        Text(String(format: bundle.loc("%lld selected"), selectedPeople.count + selectedGroups.count))
                            .scaledFont(12)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Done")) {
                        Task { if await onDone(Array(selectedPeople), Array(selectedGroups)) { dismiss() } }
                    }
                }
            }
        }
        .onAppear {
            selectedPeople = Set(initialPeople.map { $0.lowercased() })
            selectedGroups = Set(initialGroups.map { $0.lowercased() })
        }
    }

    private func candidateRow(_ candidate: SpaceCandidate, selection: Binding<Set<String>>) -> some View {
        let key = candidate.id.lowercased()
        let isOn = selection.wrappedValue.contains(key)
        return Button {
            if isOn { selection.wrappedValue.remove(key) } else { selection.wrappedValue.insert(key) }
        } label: {
            HStack(spacing: 12) {
                if candidate.isGroup {
                    GroupAvatar(name: candidate.name, colorHex: candidate.avatarColor, imageURL: candidate.avatarUrl, size: 44)
                } else {
                    Avatar(name: candidate.name, colorHex: candidate.avatarColor, imageURL: candidate.avatarUrl, size: .md)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .scaledFont(15, .semibold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    if let subtitle = candidate.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .scaledFont(13)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .scaledFont(22)
                    .foregroundColor(isOn ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(AppColors.surface(colorScheme))
    }
}

// MARK: - One chat's spaces (chat settings)

/// Checklist of the user's spaces for one person or group chat: tick to put
/// it in, untick to take it out, or start a new space with it in.
struct SpaceMembershipSheet: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager

    let name: String
    let spaces: [ChatSpace]
    let isIn: (ChatSpace) -> Bool
    let onToggle: (ChatSpace, Bool) -> Void
    let onNewSpace: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(spaces) { space in
                        let isIn = isIn(space)
                        Button { onToggle(space, !isIn) } label: {
                            HStack(spacing: 12) {
                                SpacePlanetIcon(color: space.color.color, size: 20)
                                Text(space.name)
                                    .scaledFont(16)
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                Spacer()
                                if isIn {
                                    Image(systemName: "checkmark")
                                        .scaledFont(15, .semibold)
                                        .foregroundColor(themeManager.theme.primary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button(action: onNewSpace) {
                        Label(bundle.loc("New space"), systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .foregroundColor(themeManager.theme.primary)
                    }
                } footer: {
                    Text("Only you can see your spaces.", bundle: bundle)
                }
            }
            .navigationTitle(String(format: bundle.loc("Spaces for %@"), name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
