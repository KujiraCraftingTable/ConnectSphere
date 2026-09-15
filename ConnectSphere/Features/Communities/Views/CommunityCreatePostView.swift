import SwiftUI
import PhotosUI

struct CommunityCreatePostView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @Environment(\.appBundle) var bundle
    @State private var viewModel = PostComposerViewModel()

    // Hashtags — same field/caps as Feed's CreatePostView, reusing the shared
    // HashtagInputView unmodified.
    @State private var hashtags: [String] = []
    @State private var hashtagController = HashtagInputController()

    let community: Community
    let onPostCreated: (Post) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Community tag chip
                    HStack(spacing: 6) {
                        Text(community.iconEmoji)
                        Text(String(format: bundle.loc("Post to %@"), community.name))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AppColors.elevated(colorScheme))

                    // Post type picker
                    Picker("Post type", selection: $viewModel.postType) {
                        Text("Text", bundle: bundle).tag(PostType.text)
                        Text("Poll", bundle: bundle).tag(PostType.poll)
                        Text("Event", bundle: bundle).tag(PostType.event)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    // Text editor
                    ZStack(alignment: .topLeading) {
                        if viewModel.content.isEmpty {
                            Text(placeholderText)
                                .font(.system(size: 16))
                                .foregroundColor(AppColors.textTertiary(colorScheme))
                                .padding(.horizontal, 18)
                                .padding(.top, 16)
                        }
                        TextEditor(text: $viewModel.content)
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .frame(minHeight: 140)
                            .onChange(of: viewModel.content) { _, new in
                                if new.count > viewModel.maxLength {
                                    viewModel.content = String(new.prefix(viewModel.maxLength))
                                }
                                viewModel.detectAndFetchLink(viewModel.content)
                            }
                    }
                    .appBackground()

                    // ── Media preview (text posts only — parity with Feed) ──
                    if viewModel.postType == .text, !viewModel.selectedMedia.isEmpty {
                        mediaPreview
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }

                    // ── Link preview card ────────────────────────────────
                    if viewModel.postType == .text {
                        if viewModel.isFetchingLink {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("Loading link preview...", bundle: bundle)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        } else if let preview = viewModel.linkPreview {
                            linkPreviewCard(preview)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        }
                    }

                    // ── Photo/Video button (text posts only — backend only
                    // accepts image_urls on post_type='text') ─────────────
                    if viewModel.postType == .text {
                        PhotosPicker(
                            selection: $viewModel.selectedItems,
                            maxSelectionCount: 10,
                            matching: .any(of: [.images, .videos])
                        ) {
                            HStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(Color(hex: "#45BD62"))
                                Text("Photo / Video", bundle: bundle)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(AppColors.surface(colorScheme))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                                    )
                            )
                        }
                        .onChange(of: viewModel.selectedItems) { _, items in
                            Task { await viewModel.loadSelectedMedia(items) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    // ── Hashtags — applies to all post types ──
                    HashtagInputView(hashtags: $hashtags, controller: hashtagController)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    Divider().background(AppColors.borderDefault(colorScheme))

                    // Character count
                    HStack {
                        Spacer()
                        Text("\(viewModel.remaining)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(viewModel.remaining < 50
                                ? .red
                                : AppColors.textTertiary(colorScheme))
                            .padding(.trailing, 16)
                            .padding(.vertical, 8)
                    }

                    Divider().background(AppColors.borderSubtle(colorScheme))

                    // Type-specific input sections
                    switch viewModel.postType {
                    case .poll:
                        CreatePollSheet(
                            options:     $viewModel.pollOptions,
                            endsAt:      $viewModel.pollEndsAt,
                            showEndDate: $viewModel.showPollEndDate
                        )
                    case .event:
                        CreateEventSheet(
                            title:       $viewModel.eventTitle,
                            location:    $viewModel.eventLocation,
                            startsAt:    $viewModel.eventStartsAt,
                            endsAt:      $viewModel.eventEndsAt,
                            showEndDate: $viewModel.showEventEndDate
                        )
                    case .text:
                        EmptyView()
                    }

                    if let err = viewModel.errorMessage {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }
            }
            .background(AppColors.base(colorScheme).ignoresSafeArea())
            .navigationTitle(bundle.loc("New post"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Post")) {
                        // Flush whatever's still typed-but-uncommitted in the hashtag
                        // field before reading `hashtags` — otherwise a hashtag typed
                        // right before tapping Post (no space/return/suggestion tap)
                        // is silently dropped.
                        hashtagController.commitPending(into: &hashtags)
                        Task<Void, Never>(name: nil) {
                            // mode/privacy here match exactly what the backend's
                            // own COALESCE fallback would have derived when these
                            // params were omitted (community.type -> hobby/work,
                            // privacy always 'public') — passing them explicitly
                            // keeps this call site's behavior identical to before
                            // the Phase 2 mode/privacy override was added.
                            let mode: AppMode = community.type == .work ? .work : .hobby
                            await viewModel.submitPost(
                                communityId: community.id,
                                token: appState.authToken ?? "",
                                mode: mode,
                                privacy: .publicAll,
                                hashtags: hashtags
                            ) { communityPost in
                                onPostCreated(communityPost.toPost(
                                    author: appState.currentUser ?? MockData.currentUser,
                                    mode: mode, privacy: .publicAll
                                ))
                                dismiss()
                            }
                        }
                    }
                    .font(.system(size: 15, weight: .bold))
                    .disabled(!viewModel.isValid || viewModel.isPosting)
                }
            }
        }
    }

    private var placeholderText: String {
        switch viewModel.postType {
        case .text:  return bundle.loc("Share something with the community…")
        case .poll:  return bundle.loc("What do you want to ask?")
        case .event: return bundle.loc("Describe this event…")
        }
    }

    // MARK: - Media preview

    /// Same layout as Feed's CreatePostView.mediaPreview so a community
    /// composer looks identical while picking photos/videos.
    private var mediaPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.selectedMedia) { media in
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            if let preview = media.previewImage {
                                Image(uiImage: preview)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle().fill(Color.black.opacity(0.85))
                            }
                            if media.isVideo {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white.opacity(0.92))
                            }
                        }
                        .frame(width: viewModel.selectedMedia.count == 1 ? 280 : 160,
                               height: viewModel.selectedMedia.count == 1 ? 200 : 160)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        Button {
                            if let index = viewModel.selectedMedia.firstIndex(where: { $0.id == media.id }) {
                                viewModel.selectedMedia.remove(at: index)
                                if index < viewModel.selectedItems.count {
                                    viewModel.selectedItems.remove(at: index)
                                }
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                        }
                        .padding(6)
                    }
                }
            }
        }
    }

    // MARK: - Link preview

    /// Same layout as Feed's CreatePostView.linkPreviewCard.
    private func linkPreviewCard(_ preview: LinkPreviewDTO) -> some View {
        HStack(spacing: 0) {
            if let imageStr = preview.image, let imageURL = URL(string: imageStr) {
                AsyncImage(url: imageURL) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipped()
                    } else {
                        Rectangle().fill(AppColors.base(colorScheme)).frame(width: 80, height: 80)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let site = preview.siteName {
                    Text(site.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Text(preview.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(2)
                if let desc = preview.description {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { viewModel.linkPreview = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(10)
            }
        }
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
    }
}
