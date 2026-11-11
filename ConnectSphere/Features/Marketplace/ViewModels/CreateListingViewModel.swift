import Foundation
import Observation
import PhotosUI
import SwiftUI

/// "Sell" in the Marketplace: what's for sale, one item or several (step 1),
/// then which of your communities to also list it in, up to 5 (step 2). With
/// none picked it's in the Marketplace only.
@MainActor
@Observable
final class CreateListingViewModel {
    // Step 1, what's for sale. The description is the post's text, written
    // however the seller likes; each item has its own photos.
    /// The listing's headline, asked for once there are several items.
    var headline = ""
    let items = ListingItemsViewModel()
    /// Where the item is, picked on the map.
    var place: PickedPlace?
    var details = ""
    var autoReplyOn = true
    var autoReply = Bundle.app.loc("Hi! Yes, it's still available.")
    var hideFromFriends = false
    /// Re-up automatically on a schedule (Vietnam time).
    var autoReupOn = false
    var autoReupDays = 3
    var autoReupHour = 9

    // Step 2, where else it shows.
    private(set) var communities: [Community] = []
    private(set) var selected: [String] = []
    private(set) var isLoadingCommunities = false

    private(set) var isPublishing = false
    var errorMessage: String?

    static let maxCommunities = 5

    private let mode: AppMode
    private let repository = MarketplaceRepository()
    private let communityRepository = CommunityRepository()

    /// `preselected`: communities already ticked in step 2 (selling from a
    /// community's own composer).
    init(mode: AppMode, preselected: [String] = []) {
        self.mode = mode
        self.selected = Array(preselected.prefix(Self.maxCommunities))
    }

    private var trimmedHeadline: String { headline.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Anything entered, closing the form would lose it, so Cancel asks.
    var hasChanges: Bool {
        !trimmedHeadline.isEmpty || items.hasEntries
            || !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || place != nil
    }

    var canContinue: Bool {
        let headlineOK = !items.hasSeveral || (!trimmedHeadline.isEmpty && trimmedHeadline.count <= 100)
        return headlineOK && items.isValid && details.count <= 2000 && autoReply.count <= 500
    }

    // MARK: communities

    /// Your communities, Hobby only: Work mode has none (migration 127).
    func loadCommunities(token: String) async {
        guard mode == .hobby else { communities = []; return }
        isLoadingCommunities = true
        defer { isLoadingCommunities = false }
        communities = ((try? await communityRepository.fetchMyCommunities(token: token)) ?? []).filter { $0.type == .fandom }
    }

    func isSelected(_ id: String) -> Bool { selected.contains(id) }

    var isFull: Bool { selected.count >= Self.maxCommunities }

    func toggle(_ id: String) {
        if let i = selected.firstIndex(of: id) { selected.remove(at: i) }
        else if !isFull { selected.append(id) }
    }

    /// Whether this community holds members' posts for its admins first.
    func waitsForApproval(_ c: Community) -> Bool {
        c.requirePostApproval && c.role != .admin && c.role != .moderator
    }

    // MARK: publish

    /// The new listing, or nil (with `errorMessage` set).
    func publish(token: String) async -> Post? {
        isPublishing = true
        defer { isPublishing = false }
        do {
            var listing: [String: Any] = [
                "items": try await items.upload(),
                "hideFromFriends": hideFromFriends,
            ]
            // One item is its own headline.
            if items.hasSeveral { listing["title"] = trimmedHeadline }
            if let place {
                listing["location"] = String(place.name.prefix(150))
                listing["latitude"] = place.latitude
                listing["longitude"] = place.longitude
            }
            let reply = autoReply.trimmingCharacters(in: .whitespacesAndNewlines)
            if autoReplyOn && !reply.isEmpty { listing["autoReply"] = reply }
            if autoReupOn { listing["autoReup"] = ["every_days": autoReupDays, "hour": autoReupHour] }
            var fields: [String: Any] = [
                "content": details.trimmingCharacters(in: .whitespacesAndNewlines),
                "mode": mode.rawValue,
                "listingData": listing,
                "community_ids": selected,
            ]
            return try await repository.create(fields: fields, token: token)
        } catch let upload as MediaUploadError {
            errorMessage = upload.errorDescription
        } catch {
            errorMessage = friendlyError(error)
        }
        return nil
    }
}
