import SwiftUI

// MARK: - Explainer

/// Shown in Messages while the Spaces view is on and the user has no spaces
/// yet — says what a space is, with real examples, before asking for anything.
struct SpacesIntroCard: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(themeManager.theme.primary)
                    .frame(width: 36, height: 36)
                    .background(themeManager.theme.primary.opacity(0.14), in: Circle())
                Text("Organise chats with Spaces", bundle: bundle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            Text("A space groups people by where you know them from, so you can tell at a glance who's who.", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                exampleChip("Greenwich Uni", .teal)
                exampleChip(bundle.loc("Badminton"), .orange)
                exampleChip(bundle.loc("Family"), .pink)
            }

            Label(bundle.loc("Only you can see your spaces."), systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppColors.textTertiary(colorScheme))

            Button(action: onCreate) {
                Label(bundle.loc("Create your first space"), systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 15, weight: .semibold))
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

    private func exampleChip(_ text: String, _ color: SpaceColor) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color.color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(AppColors.textPrimary(colorScheme))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.color.opacity(0.14), in: Capsule())
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

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                // Live preview of the label as it'll appear in Messages.
                HStack(spacing: 8) {
                    Circle().fill(color.color).frame(width: 12, height: 12)
                    Text(trimmed.isEmpty ? bundle.loc("Space name") : trimmed)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(trimmed.isEmpty ? AppColors.textTertiary(colorScheme) : AppColors.textPrimary(colorScheme))
                }

                TextField(bundle.loc("e.g. Greenwich Uni"), text: $name)
                    .font(.system(size: 16))
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    .onChange(of: name) { _, new in if new.count > 30 { name = String(new.prefix(30)) } }

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("Colour", bundle: bundle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                    HStack(spacing: 12) {
                        ForEach(SpaceColor.allCases) { option in
                            Button { color = option } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 2).padding(2))
                                    .overlay(Circle().stroke(option == color ? option.color : .clear, lineWidth: 2))
                                    .padding(2)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
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

// MARK: - People

/// Choose who's in a space: people you chat with in this mode plus your
/// connections. Members not in that list (e.g. someone you no longer chat
/// with) are kept as they are rather than silently dropped.
struct SpacePeoplePickerView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let spaceName: String
    let candidates: [SpaceCandidate]
    let initialSelection: [String]
    /// Return false to keep the sheet open.
    let onDone: ([String]) async -> Bool

    @State private var selected: Set<String> = []
    @State private var query = ""

    private var shown: [SpaceCandidate] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    EmptyStateView(systemImage: "person.2",
                                   title: bundle.loc("No one to add yet"),
                                   message: bundle.loc("Start a chat or connect with someone, then add them here."))
                } else {
                    List(shown) { person in
                        Button { toggle(person.id) } label: { row(person) }
                            .buttonStyle(.plain)
                            .listRowBackground(AppColors.surface(colorScheme))
                    }
                    .listStyle(.plain)
                    .searchable(text: $query, prompt: bundle.loc("Search people"))
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
                        Text(spaceName).font(.system(size: 16, weight: .semibold))
                        Text(String(format: bundle.loc("%lld people"), selected.count))
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Done")) {
                        Task { if await onDone(Array(selected)) { dismiss() } }
                    }
                }
            }
        }
        .onAppear { selected = Set(initialSelection.map { $0.lowercased() }) }
    }

    private func toggle(_ id: String) {
        let key = id.lowercased()
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    private func row(_ person: SpaceCandidate) -> some View {
        let isOn = selected.contains(person.id.lowercased())
        return HStack(spacing: 12) {
            Avatar(name: person.name, colorHex: person.avatarColor, imageURL: person.avatarUrl, size: .md)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if let subtitle = person.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            Spacer()
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundColor(isOn ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

// MARK: - One person's spaces (chat settings)

/// Checklist of the user's spaces for one person: tick to put them in,
/// untick to take them out, or start a new space with them in it.
struct SpaceMembershipSheet: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager

    let personName: String
    let spaces: [ChatSpace]
    let personId: String
    let onToggle: (ChatSpace, Bool) -> Void
    let onNewSpace: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(spaces) { space in
                        let isIn = space.contains(personId)
                        Button { onToggle(space, !isIn) } label: {
                            HStack(spacing: 12) {
                                Circle().fill(space.color.color).frame(width: 12, height: 12)
                                Text(space.name)
                                    .font(.system(size: 16))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                Spacer()
                                if isIn {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .semibold))
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
            .navigationTitle(String(format: bundle.loc("Spaces for %@"), personName))
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
