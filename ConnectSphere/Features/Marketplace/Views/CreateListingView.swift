import SwiftUI
import PhotosUI

/// "Sell" in the Marketplace: what's for sale, then (Next) which of your
/// communities to also list it in — up to 5, or none for the Marketplace only.
struct CreateListingView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: CreateListingViewModel
    @State private var showCommunities = false
    @State private var altTarget: PickedPostMedia?
    let onCreated: (Post) -> Void

    init(mode: AppMode, preselectedCommunityId: String? = nil, onCreated: @escaping (Post) -> Void) {
        _viewModel = State(initialValue: CreateListingViewModel(mode: mode,
                                                                preselected: preselectedCommunityId.map { [$0] } ?? []))
        self.onCreated = onCreated
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                mediaSection
                Section {
                    TextField(bundle.loc("What are you selling?"), text: $viewModel.title)
                    TextField(bundle.loc("Price (₫) — 0 = free"), text: $viewModel.price)
                        .keyboardType(.numberPad)
                    Picker(bundle.loc("Condition"), selection: $viewModel.condition) {
                        ForEach(ListingCondition.allCases, id: \.self) { Text(bundle.loc($0.label)).tag($0) }
                    }
                    ListingLocationRow(place: $viewModel.place)
                } header: {
                    Text("Listing details", bundle: bundle)
                }
                Section {
                    TextField(bundle.loc("Describe what you're selling…"), text: $viewModel.details, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Description", bundle: bundle)
                }
                Section {
                    Toggle(bundle.loc("Auto-reply"), isOn: $viewModel.autoReplyOn)
                    if viewModel.autoReplyOn {
                        TextField(bundle.loc("Your reply"), text: $viewModel.autoReply, axis: .vertical).lineLimit(2...4)
                    }
                } footer: {
                    Text("Sent once to each buyer who messages you about this listing.", bundle: bundle)
                }
                Section {
                    Toggle(bundle.loc("Hide from friends"), isOn: $viewModel.hideFromFriends)
                } footer: {
                    Text("Your connections won't see this listing.", bundle: bundle)
                }
            }
            .tint(themeManager.theme.primary)
            .navigationTitle(Text("New listing", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ConfirmCancelButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Next")) { showCommunities = true }
                        .disabled(!viewModel.canContinue)
                }
            }
            .navigationDestination(isPresented: $showCommunities) { communityStep }
            .onChange(of: viewModel.pickerItems) { _, _ in
                Task<Void, Never>(name: nil) { await viewModel.loadPicked() }
            }
            .sheet(item: $altTarget) { item in
                AltTextEditorSheet(preview: item.previewImage, isVideo: item.isVideo, initialText: item.altText) { text in
                    viewModel.setAltText(text, for: item.id)
                }
            }
            .task { await viewModel.loadCommunities(token: token) }
        }
    }

    // MARK: Step 1 — photos and videos

    private var mediaSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PhotosPicker(selection: $viewModel.pickerItems, maxSelectionCount: CreateListingViewModel.maxMedia,
                                 matching: .any(of: [.images, .videos])) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 24))
                            Text("Add photos / videos", bundle: bundle)
                                .font(.system(size: 11, weight: .medium))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundColor(themeManager.theme.primary)
                        .frame(width: 96, height: 96)
                        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(viewModel.media) { item in tile(item) }
                    ForEach(0..<viewModel.pendingMediaCount, id: \.self) { _ in
                        MediaLoadingTile(width: 96, height: 96)
                    }
                }
                .padding(.vertical, 4)
            }
        } footer: {
            Text("Up to 10. The first one is the cover.", bundle: bundle)
        }
    }

    private func tile(_ item: PickedPostMedia) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if let preview = item.previewImage {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.black.opacity(0.85))
                }
                if item.isVideo {
                    Image(systemName: "play.circle.fill").font(.system(size: 24)).foregroundColor(.white.opacity(0.92))
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottomLeading) {
                AltTextChip(hasText: !item.altText.isEmpty) { altTarget = item }
            }
            Button { viewModel.removeMedia(item) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .padding(4)
        }
    }

    // MARK: Step 2 — where else it shows

    private var communityStep: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "bag.fill").foregroundColor(themeManager.theme.primary).frame(width: 28)
                    Text("Marketplace", bundle: bundle)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundColor(AppColors.textTertiary(colorScheme))
                }
            } footer: {
                Text("Every listing is in the Marketplace.", bundle: bundle)
            }

            Section {
                if viewModel.isLoadingCommunities {
                    ProgressView().frame(maxWidth: .infinity)
                } else if viewModel.communities.isEmpty {
                    Text("You haven't joined any communities in this mode.", bundle: bundle)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                ForEach(viewModel.communities) { c in
                    let on = viewModel.isSelected(c.id)
                    Button { viewModel.toggle(c.id) } label: {
                        HStack(spacing: 12) {
                            Text(c.iconEmoji).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).foregroundColor(AppColors.textPrimary(colorScheme))
                                if viewModel.waitsForApproval(c) {
                                    Text("Waits for admin approval", bundle: bundle)
                                        .font(.system(size: 12))
                                        .foregroundColor(AppColors.textSecondary(colorScheme))
                                }
                            }
                            Spacer()
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(on ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
                        }
                    }
                    .disabled(!on && viewModel.isFull)
                }
            } header: {
                HStack {
                    Text("Also list in", bundle: bundle)
                    Spacer()
                    Text(String(format: bundle.loc("%lld/%lld selected"), viewModel.selected.count, CreateListingViewModel.maxCommunities))
                }
            } footer: {
                Text("It shows as a post in each community you pick.", bundle: bundle)
            }

            if let error = viewModel.errorMessage {
                Text(error).foregroundColor(AppColors.danger(colorScheme))
            }
        }
        .navigationTitle(Text("List in communities", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(bundle.loc("Publish")) {
                    Task<Void, Never>(name: nil) {
                        if let post = await viewModel.publish(token: token) {
                            onCreated(post)
                            dismiss()
                        }
                    }
                }
                .disabled(viewModel.isPublishing)
            }
        }
    }
}
