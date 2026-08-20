import SwiftUI

struct CommunityCreatePostView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @Environment(\.appBundle) var bundle
    @State private var viewModel = CreateCommunityPostViewModel()

    let community: Community
    let onPostCreated: (CommunityPost) -> Void

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
                            }
                    }
                    .appBackground()

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
                        Task<Void, Never>(name: nil) {
                            await viewModel.submitPost(
                                communityId: community.id,
                                token: appState.authToken ?? ""
                            ) { post in
                                onPostCreated(post)
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
}
