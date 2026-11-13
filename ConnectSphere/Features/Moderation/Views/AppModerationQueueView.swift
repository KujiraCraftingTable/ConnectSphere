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
    /// In hours, one of `ModerationCaseViewModel.restrictOptions`.
    @State private var restrictHours = 72
    /// The decision picked on an open case; nothing happens until it's confirmed.
    @State private var selectedDecision: ModerationDecisionKind?
    @State private var confirmingSubmit = false

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

    /// Grey until a decision is picked; red for anything that removes content.
    private var submitColor: Color {
        guard let kind = selectedDecision else { return AppColors.textTertiary(colorScheme) }
        return kind == .keep ? Color.accentColor : AppColors.danger(colorScheme)
    }

    private var submitQuestion: String {
        switch selectedDecision {
        case .restrict: String(format: bundle.loc("Restrict the account for %@"),
                               RestrictionCountdown.length(hours: restrictHours, bundle: bundle)) + "?"
        case let kind?: bundle.loc(kind.label) + "?"
        case nil: ""
        }
    }

    @ViewBuilder
    private func decisionSection(_ d: ModerationCaseDetail) -> some View {
        if viewModel.isOpen {
            // A form: the decision, how long (Restrict), a note, then Submit,
            // which stays off until a decision is picked.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(bundle.loc("Decision"), selection: $selectedDecision) {
                        Text("Choose…", bundle: bundle).tag(ModerationDecisionKind?.none)
                        ForEach(ModerationDecisionKind.pickable, id: \.self) { kind in
                            Text(bundle.loc(kind.shortLabel)).tag(ModerationDecisionKind?.some(kind))
                        }
                    }
                    .pickerStyle(.menu)
                    if let kind = selectedDecision {
                        Text(bundle.loc(kind.summary))
                            .font(.footnote)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                if selectedDecision == .restrict {
                    Picker(bundle.loc("Restrict for"), selection: $restrictHours) {
                        ForEach(ModerationCaseViewModel.restrictOptions, id: \.self) { hours in
                            Text(RestrictionCountdown.length(hours: hours, bundle: bundle)).tag(hours)
                        }
                    }
                }
                VStack(alignment: .trailing, spacing: 10) {
                    // The same box as the post composer's "What's on your mind?".
                    MarkdownTextEditor(text: $viewModel.note,
                                       placeholder: bundle.loc("Private note, staff only (optional)"),
                                       minHeight: 80, maxHeight: 160)
                        .padding(.horizontal, 6)
                        .background(AppColors.base(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                    MarkdownTextEditor(text: $viewModel.reporterMessage,
                                       placeholder: bundle.loc("Message to the reporter (optional)"),
                                       minHeight: 80, maxHeight: 160)
                        .padding(.horizontal, 6)
                        .background(AppColors.base(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                    Button { confirmingSubmit = true } label: {
                        Text("Submit", bundle: bundle)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .foregroundColor(.white)
                            .background(submitColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedDecision == nil)
                }
                .padding(.vertical, 4)
                .alert(submitQuestion, isPresented: $confirmingSubmit) {
                    Button(bundle.loc("Submit"), role: selectedDecision == .keep ? nil : .destructive) {
                        guard let kind = selectedDecision else { return }
                        Task<Void, Never>(name: nil) {
                            await viewModel.decide(kind, hours: kind == .restrict ? restrictHours : nil)
                        }
                    }
                    Button(bundle.loc("Cancel"), role: .cancel) {}
                } message: {
                    if let kind = selectedDecision { Text(bundle.loc(kind.summary)) }
                }
            } header: {
                Text("Decision", bundle: bundle)
            } footer: {
                Text("Everything except Keep removes the content.", bundle: bundle)
            }
        } else if let decision = d.case.decision {
            Section(bundle.loc("Decision")) {
                Text(bundle.loc(decision == "warn" ? "Warned" : (ModerationDecisionKind(rawValue: decision)?.outcome ?? decision)))
                if let note = d.decisionNote {
                    LabeledContent(bundle.loc("Private note")) { Text(note).foregroundColor(AppColors.textSecondary(colorScheme)) }
                }
                if let message = d.reporterMessage {
                    LabeledContent(bundle.loc("To the reporter")) { Text(message).foregroundColor(AppColors.textSecondary(colorScheme)) }
                }
                if viewModel.pendingAppeal != nil {
                    TextField(bundle.loc("Private note, staff only (optional)"), text: $viewModel.note, axis: .vertical)
                    TextField(bundle.loc("Message to the reporter if you put it back (optional)"),
                              text: $viewModel.reporterMessage, axis: .vertical)
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
                // Older entries only have days.
                let hours = detail["restricted_hours"].flatMap(Int.init)
                    ?? detail["restricted_days"].flatMap(Int.init).map { $0 * 24 }
                return String(format: bundle.loc("%@ removed it and restricted the account for %@"),
                              who, hours.map { RestrictionCountdown.length(hours: $0, bundle: bundle) } ?? "?")
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
