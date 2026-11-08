import Foundation
import Observation

/// Why a post in a list was swapped for its "Hidden, Undo" card.
enum HiddenKind: Equatable {
    case hidden
    case lessLikeThis
    case hiddenAuthor(name: String, authorId: String)
    case blocked(name: String, authorId: String)
    /// The official account warned or banned over this post, which took it
    /// down. Nothing to undo: it's reversed only by an appeal.
    case moderated(banned: Bool)
}

/// Posts the person hid, said they aren't interested in, or hid/blocked the
/// author of, kept for as long as the app runs. A card in a lazy list is
/// rebuilt when it scrolls away, so this can't live in the card: it has to
/// outlive it for the Undo card to still be there when they scroll back.
/// A feed refresh clears it. The server no longer sends those posts.
@MainActor
@Observable
final class HiddenPostsRegistry {
    static let shared = HiddenPostsRegistry()

    private(set) var entries: [String: HiddenKind] = [:]

    func kind(for postId: String) -> HiddenKind? { entries[postId] }
    func set(_ kind: HiddenKind, for postId: String) { entries[postId] = kind }
    func remove(_ postId: String) { entries[postId] = nil }
    func clear() { if !entries.isEmpty { entries = [:] } }
}
