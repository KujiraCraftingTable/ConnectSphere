import SwiftUI

/// Settings › Moderation, for app moderators and admins: reports to approve
/// or deny, items the automatic checks held, and appeals. Most urgent first.
struct AppModerationQueueView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @Environment(ThemeManager.self) private var themeManager

    @State private var viewModel = ModerationQueueViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).foregroundColor(.red)
            }
            if viewModel.tab == .appeals {
                ForEach(viewModel.appeals) { item in
                    NavigationLink {
                        ModerationCaseView(caseId: item.case.id).environment(themeManager)
                    } label: {
                        caseRow(item.case, appeal: item.appeal)
                    }
                }
            } else {
                ForEach(viewModel.cases) { c in
                    NavigationLink {
                        ModerationCaseView(caseId: c.id).environment(themeManager)
                    } label: {
                        caseRow(c, appeal: nil)
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoading && isEmpty {
                ProgressView()
            } else if !viewModel.isLoading && isEmpty && viewModel.errorMessage == nil {
                EmptyStateView(systemImage: "checkmark.shield", title: bundle.loc("Nothing to review"))
            }
        }
        // The tabs sit right under the title, outside the list, so the cases get the room.
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("", selection: $viewModel.tab) {
                Text("Reports", bundle: bundle).tag(ModerationQueueViewModel.Tab.reports)
                Text("Held by AI", bundle: bundle).tag(ModerationQueueViewModel.Tab.auto)
                Text("Appeals", bundle: bundle).tag(ModerationQueueViewModel.Tab.appeals)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .contentMargins(.top, 4, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(AppColors.base(colorScheme))
        // Swipe left or right anywhere on the list to move between the tabs.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                let tabs = ModerationQueueViewModel.Tab.allCases
                guard let i = tabs.firstIndex(of: viewModel.tab) else { return }
                let next = dx < 0 ? min(i + 1, tabs.count - 1) : max(i - 1, 0)
                withAnimation(.snappy) { viewModel.tab = tabs[next] }
            }
        )
        .navigationTitle(Text("Moderation", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load() }
        .task(id: viewModel.tab) { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .moderationCaseDecided)) { _ in
            Task<Void, Never>(name: nil) { await viewModel.load() }
        }
    }

    private var isEmpty: Bool { viewModel.tab == .appeals ? viewModel.appeals.isEmpty : viewModel.cases.isEmpty }

    private func caseRow(_ c: ModerationCase, appeal: ModerationAppeal?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(severityColor(c.severity))
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(bundle.loc(c.policy.policyLabel)).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    let created = appeal?.createdAt ?? c.createdAt
                    Text(created.formatted(.relative(presentation: .numeric)))
                        .font(.system(size: 12, weight: ModerationQueueViewModel.isOverdue(created) ? .semibold : .regular))
                        .foregroundColor(ModerationQueueViewModel.isOverdue(created) ? .red : AppColors.textSecondary(colorScheme))
                }
                Text(verbatim: [bundle.loc(c.targetType.reportTargetLabel),
                                c.author.map { "@\($0.username)" },
                                c.reportCount > 1 ? String(format: bundle.loc("%lld reports"), c.reportCount) : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                if let text = appeal?.message ?? c.snapshot.text {
                    Text(text)
                        .font(.system(size: 14))
                        .lineLimit(2)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func severityColor(_ severity: Int) -> Color {
        switch severity {
        case 0: .red
        case 1: .orange
        case 2: .yellow
        default: .gray
        }
    }
}

/// One case: what was reported, by whom and why, the author's record, what's
/// been done — and the decision.
struct ModerationCaseView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    @State private var viewModel: ModerationCaseViewModel
    @State private var restrictDays = 3

    init(caseId: String) {
        _viewModel = State(initialValue: ModerationCaseViewModel(caseId: caseId))
    }

    var body: some View {
        List {
            if let d = viewModel.detail {
                // The real item, with its photos, video and link preview, to look at before deciding.
                if let link = openLink(d.case) {
                    Section { link }
                }
                Section {
                    CaseSnapshotView(snapshot: d.case.snapshot, showsEarlierMessages: true)
                } header: {
                    Text(bundle.loc(d.case.targetType.reportTargetLabel))
                } footer: {
                    Text("As it was when it was first reported.", bundle: bundle)
                }
                Section {
                    info("Rule", bundle.loc(d.case.policy.policyLabel))
                    info("Came from", bundle.loc(d.case.source == "auto" ? "Automatic check" : "User reports"))
                    if d.case.autoHidden { info("Hidden while in review", bundle.loc("Yes")) }
                    if let author = d.case.author {
                        info("Author", "@\(author.username)")
                        info("Active strikes", "\(author.activeStrikes)")
                        info("Earlier removals", "\(author.pastCases)")
                        if author.bannedAt != nil { info("Account", bundle.loc("Banned")) }
                        else if let until = author.restrictedUntil {
                            info("Restricted until", until.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                if !d.reports.isEmpty {
                    Section {
                        ForEach(d.reports) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bundle.loc(r.reason.policyLabel)).font(.system(size: 15, weight: .medium))
                                if let detail = r.detail { Text(detail).font(.system(size: 14)) }
                                Text(verbatim: "@\(r.reporterUsername) · \(r.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 12))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                        }
                    } header: {
                        Text(String(format: bundle.loc("Reports (%lld)"), d.reports.count))
                    } footer: {
                        Text("Reporters are shown only to moderators, never to the person reported.", bundle: bundle)
                    }
                }
                if let appeal = d.appeal {
                    Section(bundle.loc("Appeal")) {
                        Text(appeal.message ?? bundle.loc("No message"))
                        info("Status", bundle.loc(appeal.status.capitalized))
                    }
                }
                decisionSection(d)
                Section(bundle.loc("History")) {
                    ForEach(Array(d.actions.enumerated()), id: \.offset) { _, a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: historySentence(action: a.action, actor: a.actorUsername, detail: a.detail))
                                .font(.system(size: 14))
                            if let note = a.detail["note"], !note.isEmpty {
                                Text(verbatim: "“\(note)”").font(.system(size: 13)).italic()
                            }
                            Text(a.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                    }
                }
            } else if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let error = viewModel.errorMessage {
                Text(error).foregroundColor(.red)
            }
        }
        .navigationTitle(Text("Case", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(viewModel.isWorking)
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private func decisionSection(_ d: ModerationCaseDetail) -> some View {
        if viewModel.isOpen {
            Section {
                TextField(bundle.loc("Note for the record (optional)"), text: $viewModel.note, axis: .vertical)
                ForEach(ModerationDecisionKind.allCases, id: \.self) { kind in
                    if kind == .restrict {
                        Picker(bundle.loc("Restrict for"), selection: $restrictDays) {
                            ForEach(ModerationCaseViewModel.restrictOptions, id: \.self) { days in
                                Text(String(format: bundle.loc("%lld days"), days)).tag(days)
                            }
                        }
                    }
                    ConfirmingButton(title: bundle.loc(kind.label), question: bundle.loc(kind.label),
                                     message: bundle.loc(kind == .keep
                                        ? "The content stays up and the reporters are told it doesn't break the rules."
                                        : "The author is told what was removed and why, and can ask for a review."),
                                     destructive: kind != .keep) {
                        Task<Void, Never>(name: nil) {
                            await viewModel.decide(kind, days: kind == .restrict ? restrictDays : nil)
                        }
                    }
                }
            } header: {
                Text("Decision", bundle: bundle)
            } footer: {
                Text("Everything except Keep removes the content. A strike for child sexual exploitation bans the account.", bundle: bundle)
            }
        } else if let decision = d.case.decision {
            Section(bundle.loc("Decision")) {
                Text(bundle.loc(decision == "warn" ? "Warned" : (ModerationDecisionKind(rawValue: decision)?.outcome ?? decision)))
                if let note = d.decisionNote { Text(note).foregroundColor(AppColors.textSecondary(colorScheme)) }
                if viewModel.pendingAppeal != nil {
                    TextField(bundle.loc("Note for the record (optional)"), text: $viewModel.note, axis: .vertical)
                    ConfirmingButton(title: bundle.loc("Overturn — put it back"), question: bundle.loc("Put it back?")) {
                        Task<Void, Never>(name: nil) { await viewModel.decideAppeal(overturn: true) }
                    }
                    ConfirmingButton(title: bundle.loc("Uphold — keep the decision"), question: bundle.loc("Keep the decision?")) {
                        Task<Void, Never>(name: nil) { await viewModel.decideAppeal(overturn: false) }
                    }
                }
            }
        }
    }

    /// Opens the reported post, comment (in its post) or profile; a message
    /// has no screen of its own, so its snapshot is all there is.
    @ViewBuilder
    private func openLink(_ c: ModerationCase) -> (some View)? {
        if let postId = c.postId, c.targetType == "post" || c.targetType == "comment" {
            NavigationLink {
                PostDetailView(postId: postId, scrollToCommentId: c.targetType == "comment" ? c.targetId : nil)
            } label: {
                Label(bundle.loc(c.targetType == "comment" ? "Open comment" : "Open post"), systemImage: "arrow.up.forward.square")
            }
        } else if c.targetType == "user", let userId = c.targetId {
            NavigationLink {
                UserProfileView(userId: userId)
            } label: {
                Label(bundle.loc("Open profile"), systemImage: "person.crop.circle")
            }
        }
    }

    /// One history entry as a sentence ("@connectsphere warned them").
    private func historySentence(action: String, actor: String?, detail: [String: String]) -> String {
        let who = actor.map { "@" + $0 } ?? bundle.loc("The automatic check")
        func say(_ key: String) -> String { String(format: bundle.loc(key), who) }
        switch action {
        case "case_opened": return say("%@ opened the case")
        case "decided":
            switch detail["decision"] {
            case "keep": return say("%@ kept it up")
            case "remove": return say("%@ removed it")
            case "remove_strike": return say("%@ removed it and gave a strike")
            case "restrict":
                return String(format: bundle.loc("%@ removed it and restricted the account for %@ days"),
                              who, detail["restricted_days"] ?? "?")
            case "ban": return say("%@ banned them")
            case "warn": return say("%@ warned them")
            default: return say("%@ decided")
            }
        case "appeal_filed": return say("%@ asked for a review")
        case "appeal_decided":
            return say(detail["result"] == "overturned" ? "%@ overturned the decision and put it back" : "%@ kept the decision")
        case "auto_flagged":
            return String(format: bundle.loc("The automatic check flagged it (%@)"),
                          bundle.loc((detail["policy"] ?? "other").policyLabel))
        case "auto_hidden": return bundle.loc("The automatic check hid it while it's reviewed")
        case "spam_signal": return bundle.loc("Flagged as possible spam")
        default: return "\(who) · \(action.replacingOccurrences(of: "_", with: " "))"
        }
    }

    private func info(_ key: String, _ value: String) -> some View {
        HStack {
            Text(bundle.loc(key)).foregroundColor(AppColors.textSecondary(colorScheme))
            Spacer()
            Text(verbatim: value)
        }
        .font(.system(size: 15))
    }
}

/// A button that asks before acting, with the question shown from the button
/// itself (a popover on iPad and newer iOS anchors to what it's attached to,
/// so it no longer floats at the top of the screen).
private struct ConfirmingButton: View {
    let title: String
    let question: String
    var message: String? = nil
    var destructive = false
    let action: () -> Void
    @State private var asking = false
    @Environment(\.appBundle) private var bundle

    var body: some View {
        Button(title, role: destructive ? .destructive : nil) { asking = true }
            .confirmationDialog(question, isPresented: $asking, titleVisibility: .visible) {
                Button(bundle.loc("Confirm"), role: destructive ? .destructive : nil, action: action)
                Button(bundle.loc("Cancel"), role: .cancel) {}
            } message: {
                if let message { Text(message) }
            }
    }
}
