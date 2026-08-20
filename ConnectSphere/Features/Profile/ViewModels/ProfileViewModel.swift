import Foundation
import Observation

@MainActor
@Observable
class ProfileViewModel {
    var user: UserProfile?
    var posts: [Post] = []
    var isLoading = false
    var error: String?

    private let repository = ProfileRepository()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .postDeleted, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            self?.removePost(id: id)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .postUpdated, object: nil, queue: .main
        ) { [weak self] note in
            guard let post = note.userInfo?["post"] as? Post else { return }
            self?.updatePost(post)
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func removePost(id: String) {
        let wasPresent = posts.contains { $0.id == id }
        posts.removeAll { $0.id == id }
        // Read postCount into a local BEFORE the `user?.postCount = ...` assignment:
        // reading and writing `user?.postCount` in the same optional-chained
        // assignment statement triggers a Swift exclusivity-access crash
        // (overlapping getter/setter access on the @Observable `user` property).
        if wasPresent, let currentCount = user?.postCount {
            user?.postCount = max(currentCount - 1, 0)
        }
    }

    func updatePost(_ updated: Post) {
        if let i = posts.firstIndex(where: { $0.id == updated.id }) {
            posts[i] = updated
        }
    }

    func load(userId: String, mode: String? = nil) async {
        isLoading = true
        error = nil
        do {
            async let userResult  = repository.fetchUser(userId: userId, mode: mode)
            async let postsResult = repository.fetchPosts(authorId: userId)
            let (u, p) = try await (userResult, postsResult)
            user  = u
            posts = p
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
