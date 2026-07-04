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
        if wasPresent {
            user?.postCount = max((user?.postCount ?? 0) - 1, 0)
        }
    }

    func updatePost(_ updated: Post) {
        if let i = posts.firstIndex(where: { $0.id == updated.id }) {
            posts[i] = updated
        }
    }

    func load(userId: String) async {
        isLoading = true
        error = nil
        do {
            async let userResult  = repository.fetchUser(userId: userId)
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
