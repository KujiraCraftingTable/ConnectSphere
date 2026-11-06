import SwiftUI

/// Multi-select picker over the current user's accepted connections. Used
/// both for picking a brand-new group's initial members (`excludedUserIds`
/// empty) and for adding members to an existing group (`excludedUserIds` =
/// current roster). No reusable multi-select picker existed in the app
/// before this; row style follows `ConnectionsListView`'s `userRow`, and the
/// `Set<String>` selection mechanic follows `InterestPickerView`'s chip
/// selection pattern.
struct GroupMemberPickerView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss

    /// Existing members to exclude from the pickable list (empty for group creation).
    let excludedUserIds: Set<String>
    /// Remaining slots under the group's 100-member hard cap.
    let remainingSlots: Int
    /// Label for the confirm button ("Next" for creation, "Add" for an existing group).
    let confirmTitle: String
    /// Confirm stays disabled until at least this many are picked.
    var minimumSelection = 1
    /// A line above the list (e.g. "With Minh, add at least 1 more person").
    var note: String? = nil
    /// Called with the chosen user ids once the user taps confirm; the sheet
    /// dismisses itself right after.
    let onConfirm: (Set<String>) -> Void

    @State private var viewModel = GroupMemberPickerViewModel()

    private var canConfirm: Bool { viewModel.selectedIds.count >= max(1, minimumSelection) }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.connections.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.connections.isEmpty {
                    emptyState
                } else {
                    List {
                        if let note {
                            Section {
                                Text(note)
                                    .scaledFont(13)
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                                    .listRowBackground(Color.clear)
                            }
                        }
                        ForEach(viewModel.connections) { item in
                        Button {
                            viewModel.toggle(item.user.id, cap: remainingSlots)
                        } label: {
                            row(item)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(AppColors.surface(colorScheme))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Select members"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(confirmTitle) {
                        onConfirm(viewModel.selectedIds)
                        dismiss()
                    }
                    .disabled(!canConfirm)
                    // An explicit colour would hide the disabled state, so it follows it.
                    .foregroundColor(canConfirm ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
                }
                ToolbarItem(placement: .principal) {
                    if !viewModel.selectedIds.isEmpty {
                        Text("\(viewModel.selectedIds.count)/\(remainingSlots)")
                            .scaledFont(12, .medium)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
            }
        }
        .task {
            await viewModel.load(mode: appState.currentMode.rawValue, excluding: excludedUserIds)
        }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.error != nil)) {
            Button(bundle.loc("OK")) { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }

    private func row(_ item: ConnectionItemDTO) -> some View {
        let isSelected = viewModel.selectedIds.contains(item.user.id)
        return HStack(spacing: 10) {
            AvatarView(user: item.user.toUserProfile(), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.user.displayName)
                    .scaledFont(15, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if appState.currentMode == .work, let title = item.user.jobTitle, !title.isEmpty {
                    Text(title)
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                } else if let location = item.user.location, !location.isEmpty {
                    Text(location)
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .scaledFont(22)
                .foregroundColor(isSelected ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .scaledFont(40)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No connections available to add", bundle: bundle)
                .scaledFont(14)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Group creation: name step

/// Second step of "New group": name the group (optional) after picking
/// members, then create it.
struct NewGroupDetailsSheet: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss

    let memberCount: Int
    var isCreating: Bool
    /// Called when the user confirms creation with the (possibly empty) name.
    let onCreate: (String) -> Void

    @State private var name = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(themeManager.theme.primaryGradient).frame(width: 84, height: 84)
                    Image(systemName: "person.3.fill")
                        .scaledFont(30, .semibold)
                        .foregroundColor(.white)
                }
                .padding(.top, 24)

                TextField(bundle.loc("Group name (optional)"), text: $name)
                    .scaledFont(16)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)

                Text(String(format: bundle.loc("%d members selected"), memberCount))
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))

                Spacer()
            }
            .background(AppColors.base(colorScheme).ignoresSafeArea())
            .navigationTitle(bundle.loc("New group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button(bundle.loc("Create")) {
                            onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .foregroundColor(themeManager.theme.primary)
                    }
                }
            }
        }
    }
}
