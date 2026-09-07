import SwiftUI
import Combine

/// Views one person's stories — full screen, a progress bar per story,
/// auto-advances after 5 seconds, tap left/right to go back/forward.
/// Your own story additionally has a delete button + list of viewers.
struct StoryViewerView: View {
    @Environment(AppState.self) var appState
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) var dismiss

    let group: StoryGroup
    var onClose: (() -> Void)? = nil

    /// Local copy so a story can be deleted in place without touching group (a let)
    @State private var stories: [StoryDTO]
    @State private var currentIndex = 0
    @State private var progress: Double = 0   // 0...1 of the current story

    // Own-story features
    @State private var viewers: [StoryViewerDTO] = []
    @State private var showViewers = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    private let storyRepo = StoryRepository()
    private let secondsPerStory: Double = 5
    private let tick: Double = 0.05
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    init(group: StoryGroup, onClose: (() -> Void)? = nil) {
        self.group = group
        self.onClose = onClose
        _stories = State(initialValue: group.stories)
    }

    private var isOwn: Bool { group.author.id == appState.currentUser?.id }

    /// Timer pauses while the viewers sheet / delete dialog is open
    private var isPaused: Bool { showViewers || showDeleteConfirm || isDeleting }

    private var currentStory: StoryDTO? {
        stories.indices.contains(currentIndex) ? stories[currentIndex] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Current story's image
            if let story = currentStory, let url = URL(string: story.imageUrl) {
                AsyncImage(url: url) { phase in
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
                    .onTapGesture { goPrevious() }
                Rectangle().fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { goNext() }
            }

            // Overlay: progress + header
            VStack(spacing: 10) {
                // Progress segments
                HStack(spacing: 4) {
                    ForEach(stories.indices, id: \.self) { i in
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.3))
                                Capsule()
                                    .fill(Color.white)
                                    .frame(width: geo.size.width * segmentProgress(i))
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        if let story = currentStory {
                            Text(story.createdAt.timeAgoString)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    if isOwn {
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(8)
                        }
                    }
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(8)
                    }
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
                                .font(.system(size: 13))
                            Text("\(viewers.count)")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Viewers", bundle: bundle)
                                .font(.system(size: 14))
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
        .onAppear {
            markCurrentViewed()
            loadViewers()
        }
        .onReceive(timer) { _ in
            guard !isPaused else { return }
            progress += tick / secondsPerStory
            if progress >= 1 { goNext() }
        }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.height > 60 { close() }
            }
        )
        .confirmationDialog(
            bundle.loc("Delete this story?"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(bundle.loc("Delete"), role: .destructive) {
                Task { await deleteCurrentStory() }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $showViewers) {
            viewersSheet
        }
    }

    // MARK: - Viewers sheet

    private var viewersSheet: some View {
        NavigationStack {
            Group {
                if viewers.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No views yet", bundle: bundle)
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewers) { viewer in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color(hex: viewer.avatarColor ?? "#7F5AF0"))
                                Text(String(viewer.displayName.prefix(1)))
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                if let urlStr = viewer.avatarUrl, let url = URL(string: urlStr) {
                                    AsyncImage(url: url) { phase in
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
                                .font(.system(size: 15, weight: .medium))

                            Spacer()

                            Text(viewer.viewedAt.timeAgoString)
                                .font(.system(size: 12))
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

    // MARK: - Own-story actions

    /// Deletes the currently displayed story; closes the viewer when no stories remain
    private func deleteCurrentStory() async {
        guard let story = currentStory, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await storyRepo.deleteStory(storyId: story.id)
            stories.removeAll { $0.id == story.id }
            if stories.isEmpty {
                close()
            } else {
                currentIndex = min(currentIndex, stories.count - 1)
                progress = 0
                markCurrentViewed()
                loadViewers()
            }
        } catch {
            // Leave the story as-is; the user can retry
        }
    }

    /// Fetches the viewer list for the current story (only works for your own story)
    private func loadViewers() {
        guard isOwn, let story = currentStory else { return }
        Task {
            if let list = try? await storyRepo.fetchViewers(storyId: story.id) {
                viewers = list
            }
        }
    }

    // MARK: - Navigation

    private func segmentProgress(_ index: Int) -> Double {
        if index < currentIndex { return 1 }
        if index == currentIndex { return min(progress, 1) }
        return 0
    }

    private func goNext() {
        if currentIndex < stories.count - 1 {
            currentIndex += 1
            progress = 0
            markCurrentViewed()
            loadViewers()
        } else {
            close()
        }
    }

    private func goPrevious() {
        if progress > 0.15 {
            progress = 0
        } else if currentIndex > 0 {
            currentIndex -= 1
            progress = 0
            loadViewers()
        }
    }

    private func close() {
        onClose?()
        dismiss()
    }

    private func markCurrentViewed() {
        guard let story = currentStory, !story.viewed else { return }
        Task { try? await storyRepo.markViewed(storyId: story.id) }
    }
}
