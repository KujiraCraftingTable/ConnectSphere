import SwiftUI

/// A status as a small coloured pill.
struct ApplicationStatusPill: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    let status: String

    private var color: Color {
        switch status {
        case "shortlisted": .orange
        case "hired": .green
        case "rejected": .gray
        case "viewed": .blue
        default: themeManager.theme.primary
        }
    }

    var body: some View {
        Label(bundle.loc(JobApplication.statusLabel(status)), systemImage: JobApplication.statusIcon(status))
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// One of your applications: the job, where it stands, and each step so far.
struct MyApplicationCard: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    let application: JobApplication

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(name: application.companyName ?? application.jobTitle,
                       imageURL: application.companyLogoUrl, size: .md, shape: .roundedSquare)
                VStack(alignment: .leading, spacing: 3) {
                    Text(application.jobTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(2)
                    if let company = application.companyName {
                        Text(company)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                Spacer(minLength: 4)
                ApplicationStatusPill(status: application.status)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(application.events.enumerated()), id: \.offset) { index, event in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 0) {
                            Circle()
                                .fill(index == application.events.count - 1 ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
                                .frame(width: 8, height: 8)
                                .padding(.top, 5)
                            if index < application.events.count - 1 {
                                Rectangle().fill(AppColors.textTertiary(colorScheme).opacity(0.4)).frame(width: 1.5)
                            }
                        }
                        .frame(width: 8)
                        HStack {
                            Text(bundle.loc(JobApplication.statusLabel(event.status)))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                            Spacer()
                            Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textTertiary(colorScheme))
                        }
                        .padding(.bottom, 10)
                    }
                }
            }
            .padding(.leading, 4)
        }
        .padding(14)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }
}

/// A job's applicants, for its poster or company admins: filter by status,
/// swipe to shortlist or turn down, open one for the note, CV and a chat.
struct ApplicantsView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: ApplicantsViewModel
    @State private var chat: ChatTarget?

    struct ChatTarget: Hashable { let conversationId: String; let applicant: JobApplication.Applicant }

    init(jobId: String) {
        _viewModel = State(initialValue: ApplicantsViewModel(jobId: jobId))
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(nil)
                        ForEach(JobApplication.statuses, id: \.self) { chip($0) }
                    }
                    .padding(.horizontal, 16)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
            }
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if viewModel.shown.isEmpty {
                Text(viewModel.errorMessage ?? bundle.loc(viewModel.applications.isEmpty ? "No one has applied yet." : "No applicants here."))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.shown) { application in
                        NavigationLink {
                            ApplicantDetailView(application: application, viewModel: viewModel) { chat = $0 }
                        } label: { row(application) }
                        .swipeActions(edge: .leading) {
                            Button { Task { await viewModel.setStatus("shortlisted", for: application, token: token) } } label: {
                                Label(bundle.loc("Shortlist"), systemImage: "star.fill")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            Button { Task { await viewModel.setStatus("rejected", for: application, token: token) } } label: {
                                Label(bundle.loc("Turn down"), systemImage: "xmark")
                            }
                            .tint(.gray)
                        }
                    }
                }
            }
        }
        .navigationTitle(bundle.loc("Applicants"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load(token: token) }
        .task { await viewModel.load(token: token) }
        .navigationDestination(item: $chat) { target in
            ChatView(
                conversationId: target.conversationId,
                peer: .direct(otherUserId: target.applicant.id, name: target.applicant.displayName,
                              avatarColor: target.applicant.avatarColor ?? "", avatarUrl: target.applicant.avatarUrl),
                otherUserLocation: target.applicant.location,
                currentUserId: appState.currentUser?.id ?? "",
                token: token
            )
        }
    }

    private func chip(_ status: String?) -> some View {
        let selected = viewModel.filter == status
        let label = status.map { bundle.loc(JobApplication.statusLabel($0)) } ?? bundle.loc("All")
        return Button { viewModel.filter = status } label: {
            Text("\(label) \(viewModel.count(status))")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(selected ? .white : AppColors.textPrimary(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? themeManager.theme.primary : AppColors.elevated(colorScheme), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ application: JobApplication) -> some View {
        HStack(spacing: 12) {
            Avatar(name: application.applicant.displayName, colorHex: application.applicant.avatarColor,
                   imageURL: application.applicant.avatarUrl, size: .md)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(application.applicant.displayName)
                        .font(.system(size: 15, weight: application.status == "applied" ? .bold : .semibold))
                        .lineLimit(1)
                    if application.status == "applied" {
                        Circle().fill(themeManager.theme.primary).frame(width: 7, height: 7)
                            .accessibilityLabel(Text(bundle.loc("New")))
                    }
                }
                if let title = application.applicant.jobTitle, !title.isEmpty {
                    Text(title).font(.system(size: 13)).foregroundColor(AppColors.textSecondary(colorScheme)).lineLimit(1)
                }
                HStack(spacing: 8) {
                    ApplicationStatusPill(status: application.status)
                    if let skills = application.skillsText(loc: bundle.loc) {
                        Label(skills, systemImage: "sparkles").font(.system(size: 12)).foregroundColor(themeManager.theme.primary)
                            .lineLimit(1)
                    }
                    if application.cvUrl != nil {
                        Image(systemName: "doc.richtext").font(.system(size: 12)).foregroundColor(AppColors.textTertiary(colorScheme))
                            .accessibilityLabel(Text(bundle.loc("CV")))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// One applicant: profile, fit, note, CV, and the next step.
struct ApplicantDetailView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    let application: JobApplication
    @Bindable var viewModel: ApplicantsViewModel
    let onChat: (ApplicantsView.ChatTarget) -> Void

    private var token: String { appState.authToken ?? "" }
    /// The live copy, so a status change shows at once.
    private var current: JobApplication {
        viewModel.applications.first { $0.id == application.id } ?? application
    }

    var body: some View {
        List {
            Section {
                NavigationLink { UserProfileView(userId: current.applicant.id) } label: {
                    HStack(spacing: 12) {
                        Avatar(name: current.applicant.displayName, colorHex: current.applicant.avatarColor,
                               imageURL: current.applicant.avatarUrl, size: .lg)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(current.applicant.displayName).font(.system(size: 17, weight: .semibold))
                            if let title = current.applicant.jobTitle, !title.isEmpty {
                                Text(title).font(.system(size: 14)).foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                            Text(String(format: bundle.loc("Applied %@"), current.createdAt.formatted(date: .abbreviated, time: .omitted)))
                                .font(.system(size: 12)).foregroundColor(AppColors.textTertiary(colorScheme))
                        }
                    }
                }
                HStack {
                    Text("Status", bundle: bundle)
                    Spacer()
                    ApplicationStatusPill(status: current.status)
                }
            }
            if let match = current.match, !(match.matchedSkills.isEmpty && match.missingSkills.isEmpty) {
                Section(current.skillsText(loc: bundle.loc) ?? bundle.loc("Skills")) {
                    FlowLayout(spacing: 6) {
                        ForEach(match.matchedSkills, id: \.self) { skillChip($0, has: true) }
                        ForEach(match.missingSkills, id: \.self) { skillChip($0, has: false) }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let note = current.note {
                Section(bundle.loc("Note")) { Text(note).font(.system(size: 15)) }
            }
            if let cv = current.cvUrl, let url = APIConfig.mediaURL(cv) {
                Section(bundle.loc("CV")) {
                    Button { openURL(url) } label: { Label(bundle.loc("Open CV"), systemImage: "doc.richtext") }
                }
            }
            Section {
                Button {
                    Task {
                        if let id = await viewModel.openChat(with: current, token: token) {
                            onChat(.init(conversationId: id, applicant: current.applicant))
                        }
                    }
                } label: {
                    HStack {
                        Label(bundle.loc("Message"), systemImage: "message")
                        if viewModel.openingChatFor == current.id { Spacer(); ProgressView() }
                    }
                }
                Menu {
                    ForEach(["shortlisted", "hired", "rejected"], id: \.self) { status in
                        Button { Task { await viewModel.setStatus(status, for: current, token: token) } } label: {
                            Label(bundle.loc(JobApplication.statusLabel(status)), systemImage: JobApplication.statusIcon(status))
                        }
                        .disabled(current.status == status)
                    }
                } label: {
                    Label(bundle.loc("Move to…"), systemImage: "arrow.right.circle")
                }
            }
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundColor(.red).font(.system(size: 14)) }
            }
        }
        .navigationTitle(bundle.loc("Applicant"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.opened(application, token: token) }
    }

    private func skillChip(_ skill: String, has: Bool) -> some View {
        // Not a Label: a List restyles Labels in its rows and the chip's text
        // disappeared.
        HStack(spacing: 4) {
            Image(systemName: has ? "checkmark.circle.fill" : "circle.dashed")
            Text(skill)
        }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(has ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(has ? themeManager.theme.primary.opacity(0.1) : AppColors.elevated(colorScheme), in: Capsule())
    }
}
