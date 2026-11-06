import SwiftUI

/// "..." › Share community: into chats, or to your own feed. In the app
/// only (there's no web link yet).
struct ShareCommunitySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager

    let community: Community
    @State private var viewModel = SharePostViewModel()
    @State private var showAllChats = false

    private var token: String { appState.authToken ?? "" }
    private var ref: SharedCommunityRef {
        SharedCommunityRef(id: community.id, name: community.name, coverUrl: community.coverUrl,
                           coverColor: community.coverColor, iconEmoji: community.iconEmoji,
                           memberCount: community.memberCount, privacy: community.privacy.rawValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField(bundle.loc("Say something about this community..."), text: $viewModel.comment, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(1...4)
                        .padding(12)
                        .background(AppColors.base(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    SharedCommunityCard(community: ref).allowsHitTesting(false)

                    Button {
                        Task {
                            if await viewModel.share(.community(community.id), mode: appState.currentMode, token: token) {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            if viewModel.isSharing { ProgressView().tint(.white) }
                            Text("Share to my feed", bundle: bundle).fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(.white)
                        .background(themeManager.theme.primary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(viewModel.isSharing)
                    if viewModel.shareFailed {
                        Text("Couldn't share, please try again", bundle: bundle)
                            .font(.system(size: 13)).foregroundColor(AppColors.danger(colorScheme))
                    }

                    Text("Send in a chat", bundle: bundle)
                        .font(.system(size: 15, weight: .semibold))
                    if viewModel.recipients.isEmpty {
                        Text(viewModel.isLoadingRecipients ? "" : bundle.loc("No conversations yet"))
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(viewModel.recent) { conversation in
                                    ShareRecipientTile(conversation: conversation,
                                                       isSelected: viewModel.isSelected(conversation),
                                                       onTap: { viewModel.toggle(conversation) })
                                }
                                Button { showAllChats = true } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(AppColors.textPrimary(colorScheme))
                                        .frame(width: Avatar.Size.lg.rawValue, height: Avatar.Size.lg.rawValue)
                                        .background(AppColors.elevated(colorScheme), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("All chats", bundle: bundle))
                            }
                        }
                        ShareSendButton(viewModel: viewModel) {
                            if await viewModel.sendSelected(.community(community.id), token: token) { dismiss() }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(bundle.loc("Share community"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Close")) { dismiss() } }
            }
            .navigationDestination(isPresented: $showAllChats) {
                ShareRecipientsView(viewModel: viewModel)
            }
            .task { await viewModel.loadRecipients(mode: community.type == .work ? "work" : "hobby", token: token) }
        }
    }
}
