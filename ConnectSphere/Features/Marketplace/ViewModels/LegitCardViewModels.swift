import Foundation
import Observation

extension Notification.Name {
    /// A buyer sent their review from a legit card; `object` is the card id.
    static let legitCardReviewed = Notification.Name("legitCardReviewed")
}

/// A legit card in a chat: loaded as the viewer (its seller or its buyer),
/// and the buyer's one review from it.
@MainActor
@Observable
final class ChatLegitCardViewModel {
    private(set) var card: LegitCard?
    private(set) var unavailable = false
    private(set) var isSending = false
    var errorMessage: String?

    /// 0–5; the buyer picks it in the review sheet.
    var rating = 5
    var comment = ""

    private let repository = MarketplaceRepository()

    var canSubmit: Bool {
        !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    func load(id: String, token: String) async {
        do {
            card = try await repository.legitCard(id: id, token: token)
        } catch {
            unavailable = true
        }
    }

    func isBuyer(_ userId: String?) -> Bool { card?.buyerId == userId?.lowercased() }

    /// Returns whether the review went through.
    func submit(token: String) async -> Bool {
        guard let card, canSubmit else { return false }
        isSending = true
        defer { isSending = false }
        do {
            self.card = try await repository.reviewLegitCard(
                id: card.id, rating: rating,
                comment: comment.trimmingCharacters(in: .whitespacesAndNewlines), token: token)
            // The card in the chat is a different view; it reloads on this.
            NotificationCenter.default.post(name: .legitCardReviewed, object: card.id)
            return true
        } catch {
            errorMessage = friendlyError(error)
            // Expired or already used meanwhile: show the card as it is now.
            await load(id: card.id, token: token)
            return false
        }
    }
}

/// Loads the seller behind a reviewed card for their Marketplace page.
@MainActor
@Observable
final class LegitSellerPageViewModel {
    private(set) var seller: UserProfile?
    private(set) var failed = false
    private let repository = ProfileRepository()

    func load(sellerId: String) async {
        guard seller == nil else { return }
        do {
            seller = try await repository.fetchUser(userId: sellerId, mode: AppMode.hobby.rawValue)
        } catch {
            failed = true
        }
    }
}
