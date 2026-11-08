import SwiftUI

/// "..." › Moderation log (admin only): what the admin and moderators did,
/// newest first.
struct ModerationLogView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: ModerationLogViewModel

    init(communityId: String) {
        _viewModel = State(initialValue: ModerationLogViewModel(communityId: communityId))
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        List {
            if viewModel.entries.isEmpty && !viewModel.isLoading {
                Text("Nothing here yet. Reviews, removals, bans and role changes show up here.", bundle: bundle)
                    .scaledFont(14)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            ForEach(viewModel.entries) { entry in
                row(entry)
                    .task { if entry.id == viewModel.entries.last?.id { await viewModel.loadMore(token: token) } }
            }
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(Text("Moderation log", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(token: token) }
        .refreshable { await viewModel.load(token: token) }
        .alert(bundle.loc("Error"), isPresented: Binding(
            get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private func row(_ entry: ModLogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(entry.action))
                .frame(width: 24)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            VStack(alignment: .leading, spacing: 3) {
                Text(sentence(entry))
                    .scaledFont(15)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if let snippet = entry.postSnippet, !snippet.isEmpty {
                    Text("“\(snippet)”")
                        .scaledFont(13)
                        .lineLimit(2)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Text(entry.createdAt.formatted(.relative(presentation: .named)))
                    .scaledFont(12)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        .padding(.vertical, 4)
    }

    private func sentence(_ e: ModLogEntry) -> String {
        let actor = e.actorName ?? bundle.loc("Someone")
        let target = e.targetName ?? bundle.loc("someone")
        let key: String
        switch e.action {
        case "approve_member": key = "%1$@ approved %2$@'s request to join"
        case "deny_member":    key = "%1$@ declined %2$@'s request to join"
        case "approve_post":   key = "%1$@ approved a post by %2$@"
        case "decline_post":   key = "%1$@ declined a post by %2$@"
        case "resolve_report": key = "%1$@ reviewed a report"
        case "remove_content": key = "%1$@ removed reported content"
        case "remove_member":  key = "%1$@ removed %2$@ from the community"
        case "ban":            key = "%1$@ banned %2$@"
        case "unban":          key = "%1$@ lifted %2$@'s ban"
        case "role_change":
            key = e.detail == "moderator" ? "%1$@ made %2$@ a moderator" : "%1$@ made %2$@ a member"
        case "transfer_admin": key = "%1$@ made %2$@ the admin"
        case "pin":            key = "%1$@ pinned a post"
        case "disband":        key = "%1$@ disbanded the community"
        case "restore":        key = "%1$@ restored the community"
        default:               key = "%1$@ took an action"
        }
        return String(format: bundle.loc(key), actor, target)
    }

    private func icon(_ action: String) -> String {
        switch action {
        case "approve_member", "approve_post": return "checkmark.circle"
        case "deny_member", "decline_post": return "xmark.circle"
        case "resolve_report", "remove_content": return "flag"
        case "remove_member": return "person.crop.circle.badge.xmark"
        case "ban": return "nosign"
        case "unban": return "arrow.uturn.backward.circle"
        case "role_change", "transfer_admin": return "person.badge.shield.checkmark"
        case "pin": return "pin"
        case "disband", "restore": return "archivebox"
        default: return "circle"
        }
    }
}
