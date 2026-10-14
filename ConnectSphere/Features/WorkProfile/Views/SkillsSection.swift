import SwiftUI

/// Work mode's "Skills" on a profile: the top three by endorsements, each
/// with its count and the faces of who endorsed it; "Show all" for the rest.
/// A Work connection can endorse (+) or take it back (✓).
struct SkillsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let userId: String
    let isMe: Bool
    /// Off on a view-only Work profile opened from Hobby mode.
    var allowsEndorsing = true

    @State private var viewModel = SkillsViewModel()
    @State private var showAll = false

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        Group {
            if viewModel.loaded && viewModel.skills.isEmpty && !isMe {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Skills", bundle: bundle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    if !viewModel.loaded {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if viewModel.skills.isEmpty {
                        Text("Add skills in Edit profile — your Work connections can then endorse them.", bundle: bundle)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    } else {
                        let shown = showAll ? viewModel.skills : Array(viewModel.skills.prefix(3))
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, skill in
                            if index > 0 { Divider() }
                            row(skill)
                        }
                        if viewModel.skills.count > 3 {
                            Button(showAll ? bundle.loc("Show less") : String(format: bundle.loc("Show all %lld"), viewModel.skills.count)) {
                                withAnimation(.snappy) { showAll.toggle() }
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(themeManager.theme.primary)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    if let error = viewModel.errorMessage {
                        Text(error).font(.system(size: 13)).foregroundColor(.red)
                    }
                }
                .padding(16)
                .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, AppSpacing.sm)
            }
        }
        .task(id: userId) { await viewModel.load(userId: userId, token: token) }
    }

    private func row(_ skill: ProfileSkill) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.skill)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if skill.endorsementCount > 0 {
                    HStack(spacing: 6) {
                        HStack(spacing: -6) {
                            ForEach(skill.topEndorsers) { e in
                                Avatar(name: e.displayName, colorHex: e.avatarColor, imageURL: e.avatarUrl, diameter: 20)
                                    .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 1.5))
                            }
                        }
                        Text(String(format: bundle.loc(skill.endorsementCount == 1 ? "%lld endorsement" : "%lld endorsements"),
                                    skill.endorsementCount))
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
            }
            Spacer(minLength: 8)
            if viewModel.canEndorse && allowsEndorsing {
                Button {
                    Task { await viewModel.toggleEndorse(skill, userId: userId, token: token) }
                } label: {
                    Label(bundle.loc(skill.endorsedByMe ? "Endorsed" : "Endorse"),
                          systemImage: skill.endorsedByMe ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(skill.endorsedByMe ? AppColors.textSecondary(colorScheme) : themeManager.theme.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(Capsule().stroke(skill.endorsedByMe ? AppColors.borderDefault(colorScheme)
                                                                     : themeManager.theme.primary, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
