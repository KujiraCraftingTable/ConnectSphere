import Foundation
import Observation

/// Reposting a post to your own wall with an optional message.
@MainActor
@Observable
final class SharePostViewModel {
    var comment = ""
    private(set) var isSharing = false
    private(set) var shareFailed = false

    private let repository = PostRepository()

    /// Returns true on success. Sharing a share points at the original —
    /// the backend resolves that.
    func share(postId: String, mode: AppMode) async -> Bool {
        isSharing = true
        shareFailed = false
        defer { isSharing = false }
        do {
            _ = try await repository.sharePost(postId: postId,
                                               content: comment.trimmingCharacters(in: .whitespaces),
                                               mode: mode)
            return true
        } catch {
            shareFailed = true
            return false
        }
    }
}
