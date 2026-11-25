import Foundation
import Observation

// MARK: - Highlights row
/// The row of highlights on a Hobby profile.
@MainActor
@Observable
final class HighlightsViewModel {
    private(set) var highlights: [Highlight] = []
    private(set) var loaded = false
    private let repository = HighlightRepository()

    func load(userId: String, token: String) async {
        highlights = (try? await repository.list(of: userId, token: token)) ?? highlights
        loaded = true
    }

    func replace(_ updated: [Highlight]) { highlights = updated }

    /// Adds one of your stories to a highlight; false (with a message) if refused.
    var errorMessage: String?
    func addStory(_ storyId: String, to highlight: Highlight, token: String) async -> Bool {
        do {
            highlights = try await repository.addItems(to: highlight.id, imageUrls: [], storyIds: [storyId], token: token)
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }
}

// MARK: - Viewer
/// Watching one highlight: a photo every few seconds, tap to skip; the
/// owner can remove the photo, set it as cover, or delete the highlight.
@MainActor
@Observable
final class HighlightViewerViewModel {
    static let secondsPerPhoto: Double = 5

    private(set) var highlight: Highlight
    private(set) var index = 0
    private(set) var elapsed: Double = 0
    private(set) var isWorking = false
    var errorMessage: String?
    private let repository = HighlightRepository()

    init(highlight: Highlight) { self.highlight = highlight }

    var current: Highlight.Item? { highlight.items.indices.contains(index) ? highlight.items[index] : nil }

    // MARK: - Playback
    /// 0…1 for segment `i` (done, current, or not yet).
    func progress(_ i: Int) -> Double {
        i < index ? 1 : i > index ? 0 : min(1, elapsed / Self.secondsPerPhoto)
    }

    /// Advances the clock; true when the last photo has finished.
    func tick(_ dt: Double) -> Bool {
        elapsed += dt
        return elapsed >= Self.secondsPerPhoto ? next() : false
    }

    /// True when there was no next photo (the viewer closes).
    func next() -> Bool {
        guard index + 1 < highlight.items.count else { return true }
        index += 1
        elapsed = 0
        return false
    }

    func previous() {
        if index > 0 { index -= 1 }
        elapsed = 0
    }

    // MARK: - Edits from the viewer
    /// The owner's updated list, or nil (with a message). The highlight is
    /// gone with its last photo.
    func removeCurrent(token: String) async -> [Highlight]? {
        guard let item = current else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let list = try await repository.removeItem(item.id, from: highlight.id, token: token)
            if let updated = list.first(where: { $0.id == highlight.id }) {
                highlight = updated
                index = min(index, updated.items.count - 1)
                elapsed = 0
            }
            return list
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }

    func setCurrentAsCover(token: String) async -> [Highlight]? {
        guard let item = current else { return nil }
        do { return try await repository.setCover(highlight.id, imageUrl: item.imageUrl, token: token) }
        catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }

    func delete(token: String) async -> [Highlight]? {
        isWorking = true
        defer { isWorking = false }
        do { return try await repository.delete(highlight.id, token: token) }
        catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }

    /// After adding photos / renaming elsewhere.
    func updated(_ list: [Highlight]) {
        if let h = list.first(where: { $0.id == highlight.id }) { highlight = h }
    }
}

// MARK: - Editor
/// Making a highlight, or adding photos to / renaming one: a title, photos
/// from the library (uploaded first) and your current Hobby stories.
@MainActor
@Observable
final class HighlightEditorViewModel {
    var title: String
    private(set) var photos: [Data] = []
    var storyIds: Set<String> = []
    private(set) var myStories: [StoryDTO] = []
    private(set) var isSaving = false
    var errorMessage: String?

    let editing: Highlight?
    private let repository = HighlightRepository()

    init(editing: Highlight? = nil, preselectedStory: String? = nil) {
        self.editing = editing
        title = editing?.title ?? ""
        if let preselectedStory { storyIds = [preselectedStory] }
        openedSignature = signature
    }

    /// The form as it opened, to tell whether Cancel would lose anything.
    private var openedSignature: [String] = []
    private var signature: [String] { [title, "\(photos.count)", storyIds.sorted().joined(separator: ",")] }
    var hasChanges: Bool { signature != openedSignature }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var titleTooLong: Bool { trimmedTitle.count > Highlight.titleLimit }
    private var addsPhotos: Bool { !photos.isEmpty || !storyIds.isEmpty }
    private var renames: Bool { editing.map { $0.title != trimmedTitle } ?? false }

    var canSave: Bool {
        !trimmedTitle.isEmpty && !titleTooLong && !isSaving && (editing == nil ? addsPhotos : (addsPhotos || renames))
    }

    func add(_ data: [Data]) { photos += data }
    func removePhoto(at i: Int) { if photos.indices.contains(i) { photos.remove(at: i) } }

    func toggleStory(_ id: String) {
        if storyIds.contains(id) { storyIds.remove(id) } else { storyIds.insert(id) }
    }

    /// Your own stories up now in Hobby mode (they're mode-scoped).
    func loadStories(myId: String) async {
        myStories = ((try? await StoryRepository().fetchStories(mode: AppMode.hobby.rawValue)) ?? [])
            .filter { $0.authorId == myId }
    }

    /// The owner's updated list, or nil (with a message).
    func save(token: String) async -> [Highlight]? {
        guard canSave else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            var uploaded: [String] = []
            for data in photos {
                guard let path = try await PostRepository().uploadImage(data) else {
                    errorMessage = Bundle.app.loc("Couldn't upload a photo, please try again")
                    return nil
                }
                uploaded.append(path)
            }
            let stories = Array(storyIds)
            var list: [Highlight]
            if let editing {
                list = []
                if renames { list = try await repository.rename(editing.id, title: trimmedTitle, token: token) }
                if !uploaded.isEmpty || !stories.isEmpty {
                    list = try await repository.addItems(to: editing.id, imageUrls: uploaded, storyIds: stories, token: token)
                }
            } else {
                list = try await repository.create(title: trimmedTitle, imageUrls: uploaded, storyIds: stories, token: token)
            }
            return list
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }
}
