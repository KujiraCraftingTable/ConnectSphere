import Foundation
import Observation

/// Playing one person's stories: position, per-story progress, viewers and
/// delete for your own. The view owns the timer and dismissal; navigation
/// methods return true when the viewer should close.
@MainActor
@Observable
final class StoryViewerViewModel {
    static let secondsPerStory: Double = 5

    /// A local copy, so a story can be deleted in place.
    private(set) var stories: [StoryDTO]
    private(set) var currentIndex = 0
    /// 0...1 through the current story.
    private(set) var progress: Double = 0
    private(set) var viewers: [StoryViewerDTO] = []
    private(set) var isDeleting = false
    /// The signed-in user's own story: delete + viewer list.
    private(set) var isOwn = false

    private let repository = StoryRepository()

    init(stories: [StoryDTO]) {
        self.stories = stories
    }

    var currentStory: StoryDTO? {
        stories.indices.contains(currentIndex) ? stories[currentIndex] : nil
    }

    func segmentProgress(_ index: Int) -> Double {
        if index < currentIndex { return 1 }
        if index == currentIndex { return min(progress, 1) }
        return 0
    }

    /// First appearance: whose stories these are decides the own-story features.
    func start(authorId: String, currentUserId: String?) {
        isOwn = authorId == currentUserId
        didShowCurrent()
    }

    /// Called when a story comes on screen.
    func didShowCurrent() {
        markCurrentViewed()
        loadViewers()
    }

    /// One timer tick of `seconds`; returns true when the last story ended.
    func advance(by seconds: Double) -> Bool {
        progress += seconds / Self.secondsPerStory
        return progress >= 1 ? next() : false
    }

    /// Returns true when there's no next story (the viewer should close).
    func next() -> Bool {
        guard currentIndex < stories.count - 1 else { return true }
        currentIndex += 1
        progress = 0
        didShowCurrent()
        return false
    }

    /// Restarts the current story if it's under way, otherwise steps back.
    func previous() {
        if progress > 0.15 {
            progress = 0
        } else if currentIndex > 0 {
            currentIndex -= 1
            progress = 0
            loadViewers()
        }
    }

    /// Deletes the current story; returns true when none are left. On failure
    /// the story stays and the user can retry.
    func deleteCurrent() async -> Bool {
        guard let story = currentStory, !isDeleting else { return false }
        isDeleting = true
        defer { isDeleting = false }
        guard (try? await repository.deleteStory(storyId: story.id)) != nil else { return false }
        stories.removeAll { $0.id == story.id }
        if stories.isEmpty { return true }
        currentIndex = min(currentIndex, stories.count - 1)
        progress = 0
        didShowCurrent()
        return false
    }

    /// Only your own story's viewers can be fetched.
    private func loadViewers() {
        guard isOwn, let story = currentStory else { return }
        Task {
            if let list = try? await repository.fetchViewers(storyId: story.id) { viewers = list }
        }
    }

    private func markCurrentViewed() {
        guard let story = currentStory, !story.viewed else { return }
        Task { try? await repository.markViewed(storyId: story.id) }
    }
}
