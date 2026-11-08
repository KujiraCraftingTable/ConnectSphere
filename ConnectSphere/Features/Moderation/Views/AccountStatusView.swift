import SwiftUI

/// Settings › Account status. Also the whole app for a banned account
/// (`SuspendedView`), since appeals are the one thing it can still do.
struct AccountStatusView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @Environment(ThemeManager.self) private var themeManager

    @State private var viewModel = AccountStatusViewModel()

    var body: some View {
        List {
            if let status = viewModel.status {
                Section { standing(status) }
                // Each profile's health: warnings (3 within 90 days is a ban) and any ban.
                ForEach(["hobby", "work"], id: \.self) { mode in
                    modeSection(status, mode: mode)
                }
                Section {
                    if status.decisions.isEmpty {
                        Text("Nothing of yours has been removed.", bundle: bundle)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    ForEach(status.decisions) { decision in decisionRow(decision) }
                } header: {
                    Text("Removed content", bundle: bundle)
                }
                Section {
                    if status.reports.isEmpty {
                        Text("You haven't reported anything.", bundle: bundle)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    ForEach(Array(status.reports.enumerated()), id: \.offset) { _, report in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bundle.loc(report.targetType.reportTargetLabel)).font(.system(size: 15, weight: .medium))
                                Text(bundle.loc(report.reason.policyLabel))
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                            Spacer()
                            Text(bundle.loc(outcomeLabel(report.outcome)))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(report.outcome == "removed" ? .green : AppColors.textSecondary(colorScheme))
                        }
                    }
                } header: {
                    Text("Your reports", bundle: bundle)
                } footer: {
                    Text("People you report are never told it was you.", bundle: bundle)
                }
            } else if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error = viewModel.errorMessage {
                EmptyStateView(systemImage: "wifi.exclamationmark", title: error, actionTitle: bundle.loc("Retry")) {
                    Task<Void, Never>(name: nil) { await viewModel.load() }
                }
            }
        }
        .navigationTitle(Text("Account status", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
        .sheet(item: $viewModel.appealing) { decision in appealSheet(decision) }
    }

    @ViewBuilder
    private func standing(_ status: AccountStatus) -> some View {
        if status.bannedAt != nil {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your account is suspended", bundle: bundle).font(.system(size: 16, weight: .semibold))
                    Text(String(format: bundle.loc("It broke our rules on %@. You can ask for a review below."),
                                bundle.loc((status.banReason ?? "other").policyLabel)))
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            } icon: { Image(systemName: "exclamationmark.octagon.fill").foregroundColor(.red) }
        } else if let until = status.restrictedUntil {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Some features are paused", bundle: bundle).font(.system(size: 16, weight: .semibold))
                    Text(String(format: bundle.loc("You can't post, comment or message new people until %@."),
                                until.formatted(date: .abbreviated, time: .shortened)))
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            } icon: { Image(systemName: "clock.badge.exclamationmark.fill").foregroundColor(.orange) }
        } else {
            Label {
                Text("Your account is in good standing", bundle: bundle).font(.system(size: 16, weight: .semibold))
            } icon: { Image(systemName: "checkmark.seal.fill").foregroundColor(.green) }
        }
    }

    private func decisionRow(_ d: AccountStatus.Decision) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(bundle.loc(d.targetType.reportTargetLabel)).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(d.decidedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Text(String(format: bundle.loc("Broke our rules on: %@"), bundle.loc(d.policy.policyLabel)))
                .font(.system(size: 14))
            Text(bundle.loc(ModerationDecisionKind(rawValue: d.decision)?.outcome ?? d.decision))
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            CaseSnapshotView(snapshot: d.snapshot)
                .padding(10)
                .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 10))
            if let appeal = d.appealStatus {
                Text(bundle.loc(appealLabel(appeal)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(appeal == "overturned" ? .green : AppColors.textSecondary(colorScheme))
            } else if d.canAppeal {
                Button(bundle.loc("Request review")) { viewModel.appealing = d }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(themeManager.theme.primary)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func appealSheet(_ decision: AccountStatus.Decision) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $viewModel.appealMessage).frame(minHeight: 120)
                } header: {
                    Text("Why should we look again? (optional)", bundle: bundle)
                } footer: {
                    Text("A different moderator reviews your request when possible. You can ask once for each decision.", bundle: bundle)
                }
                if let err = viewModel.appealError {
                    Text(err).foregroundColor(.red)
                }
            }
            .navigationTitle(Text("Request review", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ConfirmCancelButton(hasChanges: !viewModel.appealMessage.isEmpty) { viewModel.appealing = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Send")) {
                        Task<Void, Never>(name: nil) { _ = await viewModel.sendAppeal() }
                    }
                    .disabled(!viewModel.canSendAppeal)
                }
            }
        }
        .interactiveDismissDisabled()
        .environment(themeManager)
    }

    @ViewBuilder
    private func modeSection(_ status: AccountStatus, mode: String) -> some View {
        let warnings = status.warnings(in: mode)
        Section {
            if let ban = status.ban(in: mode) {
                Label {
                    Text(ban.bannedUntil.map {
                        String(format: bundle.loc("Banned until %@"), $0.formatted(date: .abbreviated, time: .omitted))
                    } ?? bundle.loc("Banned permanently"))
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundColor(AppColors.danger(colorScheme))
                }
                .font(.system(size: 15, weight: .semibold))
            } else if warnings.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Healthy", bundle: bundle).font(.system(size: 15, weight: .semibold))
                        Text("No warnings", bundle: bundle)
                            .font(.system(size: 13)).foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                }
            }
            ForEach(warnings, id: \.self) { warning in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(bundle.loc(warning.policy.policyLabel)).font(.system(size: 15, weight: .medium))
                    }
                    Text(String(format: bundle.loc("Given %@ · counts until %@"),
                                warning.createdAt.formatted(date: .abbreviated, time: .omitted),
                                warning.expiresAt.formatted(date: .abbreviated, time: .omitted)))
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                    if let snapshot = warning.snapshot, warning.targetType != "user" {
                        CaseSnapshotView(snapshot: snapshot)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(bundle.loc(mode == "work" ? "Work profile" : "Hobby profile"))
        } footer: {
            if !warnings.isEmpty && status.ban(in: mode) == nil {
                Text(String(format: bundle.loc("%lld of 3 warnings. A third warning within 90 days means a ban, so take care with what you share."),
                            warnings.count))
            }
        }
    }

    private func outcomeLabel(_ outcome: String) -> String {
        switch outcome {
        case "removed": "Removed"
        case "kept": "Didn't break the rules"
        default: "Under review"
        }
    }

    private func appealLabel(_ status: String) -> String {
        switch status {
        case "overturned": "Review: we put it back"
        case "upheld": "Review: the decision stands"
        default: "Review requested"
        }
    }
}

/// What a banned account sees instead of the app: why, and a way to appeal.
/// What a banned person sees in a banned mode (migration 106): why, until
/// when, the post or comment it was about, and how to appeal. Banned in one
/// mode only, they can switch to the other and keep using the app there.
struct SuspendedView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @State private var viewModel = AccountStatusViewModel()

    private var mode: String { appState.currentMode.rawValue }
    private var ban: AccountStatus.Ban? { viewModel.status?.ban(in: mode) }
    private var otherMode: AppMode { appState.currentMode == .hobby ? .work : .hobby }
    private var canSwitch: Bool {
        !appState.isSuspended && !appState.suspendedModes.contains(otherMode.rawValue)
            && (appState.currentUser?.hasPersona(otherMode) ?? false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 44))
                        .foregroundColor(AppColors.danger(colorScheme))
                        .padding(.top, 24)
                    Text(appState.isSuspended ? bundle.loc("Your account is banned")
                         : bundle.loc(mode == "work" ? "Your Work profile is banned" : "Your Hobby profile is banned"))
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)

                    if let ban {
                        VStack(alignment: .leading, spacing: 10) {
                            if let policy = ban.policy {
                                row(bundle.loc("Reason"), bundle.loc(policy.policyLabel))
                            }
                            row(bundle.loc("Until"), ban.bannedUntil.map {
                                $0.formatted(date: .abbreviated, time: .shortened)
                            } ?? bundle.loc("Permanently"))
                            if let note = ban.note, !note.isEmpty { row(bundle.loc("Note"), note) }
                            if let snapshot = ban.snapshot, ban.targetType != "user" {
                                Text("What this was about", bundle: bundle)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                                    .padding(.top, 4)
                                CaseSnapshotView(snapshot: snapshot)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else if viewModel.isLoading {
                        ProgressView()
                    }

                    Text("While it's banned, nobody can find or message this profile, and what you shared here is hidden. If you think we got it wrong, tell us.", bundle: bundle)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .multilineTextAlignment(.center)

                    VStack(spacing: 10) {
                        if let url = appealMailURL {
                            Link(destination: url) {
                                Label(bundle.loc("Email us to appeal"), systemImage: "envelope.fill")
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .background(themeManager.theme.primary, in: Capsule())
                                    .foregroundColor(.white)
                            }
                        }
                        NavigationLink {
                            AccountStatusView()
                        } label: {
                            Label(bundle.loc("Request review"), systemImage: "arrow.uturn.backward.circle")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(AppColors.elevated(colorScheme), in: Capsule())
                        }
                        if canSwitch {
                            Button {
                                appState.switchMode(to: otherMode)
                            } label: {
                                Label(bundle.loc(otherMode == .work ? "Switch to Work" : "Switch to Hobby"),
                                      systemImage: otherMode.glyph)
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .background(AppColors.elevated(colorScheme), in: Capsule())
                            }
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 20)
            }
            .background(AppColors.base(colorScheme))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Log out")) { appState.logout() }
                }
            }
            .task(id: mode) {
                await viewModel.load()
                // Lifted or run out since: back to the app.
                if viewModel.status != nil, ban == nil, !appState.isSuspended {
                    appState.suspendedModes.remove(mode)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundColor(AppColors.textSecondary(colorScheme))
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 15))
    }

    /// Mail to the safety address, with what we need to find the case.
    private var appealMailURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = SettingsView.safetyEmail
        let who = appState.currentUser.map { "@" + $0.username } ?? ""
        c.queryItems = [
            URLQueryItem(name: "subject", value: "Ban appeal \(who) (\(mode))"),
            URLQueryItem(name: "body", value: "Account: \(who)\nProfile: \(mode)\nCase: \(ban?.caseId ?? "-")\n\nWhy we should look again:\n")
        ]
        return c.url
    }
}
