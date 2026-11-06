import SwiftUI
import Combine

/// Views one person's stories. Full screen, a progress bar per story,
/// auto-advances after 5 seconds, tap left/right to go back/forward.
/// Your own story additionally has a delete button + list of viewers.
struct StoryViewerView: View {
    @Environment(AppState.self) var appState
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) var dismiss

    let group: StoryGroup
    var onClose: (() -> Void)? = nil

    @State private var viewModel: StoryViewerViewModel

    // Own-story features
    @State private var showViewers = false
    @State private var showDeleteConfirm = false
    @State private var addingToHighlight = false

    private let tick: Double = 0.05
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    init(group: StoryGroup, onClose: (() -> Void)? = nil) {
        self.group = group
        self.onClose = onClose
        _viewModel = State(initialValue: StoryViewerViewModel(stories: group.stories))
    }

    private var isOwn: Bool { viewModel.isOwn }

    /// Timer pauses while the viewers sheet / delete dialog is open
    private var isPaused: Bool { showViewers || showDeleteConfirm || viewModel.isDeleting || addingToHighlight }

    private var currentStory: StoryDTO? { viewModel.currentStory }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Current story's image
            if let story = currentStory, let url = APIConfig.mediaURL(story.imageUrl) {
                RemoteImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Tap zones: left = back, right = forward
            HStack(spacing: 0) {
                Rectangle().fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.previous() }
                Rectangle().fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { if viewModel.next() { close() } }
            }

            // Overlay: progress + header
            VStack(spacing: 10) {
                // Progress segments
                HStack(spacing: 4) {
                    ForEach(viewModel.stories.indices, id: \.self) { i in
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.3))
                                Capsule()
                                    .fill(Color.white)
                                    .frame(width: geo.size.width * viewModel.segmentProgress(i))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                // Header: author + delete (own) + close
                HStack(spacing: 10) {
                    AvatarView(user: group.author, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.author.name)
                            .scaledFont(14, .semibold)
                            .foregroundColor(.white)
                        if let story = currentStory {
                            Text(story.createdAt.timeAgoString)
                                .scaledFont(12)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    // Highlights are Hobby-only.
                    if isOwn && appState.currentMode == .hobby {
                        Button { addingToHighlight = true } label: {
                            Image(systemName: "star.circle")
                                .scaledFont(18, .semibold)
                                .foregroundColor(.white)
                                .padding(8)
                        }
                        .accessibilityLabel(Text(bundle.loc("Add to highlight")))
                    }
                    if isOwn {
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .scaledFont(16, .semibold)
                                .foregroundColor(.white)
                                .padding(8)
                        }
                        .accessibilityLabel(Bundle.app.loc("Delete story"))
                        .confirmationDialog(
                            bundle.loc("Delete this story?"),
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible
                        ) {
                            Button(bundle.loc("Delete"), role: .destructive) {
                                Task { if await viewModel.deleteCurrent() { close() } }
                            }
                            Button(bundle.loc("Cancel"), role: .cancel) {}
                        }
                    }
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(18, .semibold)
                            .foregroundColor(.white)
                            .padding(8)
                    }
                    .accessibilityLabel(Bundle.app.loc("Close"))
                }
                .padding(.horizontal, 12)

                Spacer()

                // Own story: viewers row at the bottom
                if isOwn {
                    Button {
                        showViewers = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "eye.fill")
                                .scaledFont(13)
                            Text("\(viewModel.viewers.count)")
                                .scaledFont(14, .semibold)
                            Text("Viewers", bundle: bundle)
                                .scaledFont(14)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .statusBarHidden()
        .onAppear { viewModel.start(authorId: group.author.id, currentUserId: appState.currentUser?.id) }
        .sheet(isPresented: $addingToHighlight) {
            if let story = currentStory { AddToHighlightSheet(storyId: story.id) }
        }
        .onReceive(timer) { _ in
            guard !isPaused else { return }
            if viewModel.advance(by: tick) { close() }
        }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.height > 60 { close() }
            }
        )
        .sheet(isPresented: $showViewers) {
            viewersSheet
        }
    }

    // MARK: - Viewers sheet

    private var viewersSheet: some View {
        NavigationStack {
            Group {
                if viewModel.viewers.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "eye.slash")
                            .scaledFont(36)
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No views yet", bundle: bundle)
                            .scaledFont(15)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.viewers) { viewer in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color(hex: viewer.avatarColor ?? "#7F5AF0"))
                                Text(String(viewer.displayName.prefix(1)))
                                    .scaledFont(15, .bold)
                                    .foregroundColor(.white)
                                if let url = APIConfig.mediaURL(viewer.avatarUrl) {
                                    RemoteImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        }
                                    }
                                    .clipShape(Circle())
                                }
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())

                            Text(viewer.displayName)
                                .scaledFont(15, .medium)

                            Spacer()

                            Text(viewer.viewedAt.timeAgoString)
                                .scaledFont(12)
                                .foregroundColor(.secondary)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(bundle.loc("Viewers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) { showViewers = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Navigation

    private func close() {
        onClose?()
        dismiss()
    }
}
