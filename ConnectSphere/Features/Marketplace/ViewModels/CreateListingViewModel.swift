import Foundation
import Observation
import PhotosUI
import SwiftUI

/// "Sell" in the Marketplace: what's for sale (step 1), then which of your
/// communities to also list it in, up to 5 (step 2). With none picked it's
/// in the Marketplace only.
@MainActor
@Observable
final class CreateListingViewModel {
    // Step 1, the item. The description is the post's text; the photos and
    // videos its media.
    var title = ""
    /// Whole VND, shown grouped ("150.000"); empty or 0 = free.
    var price = ""
    var condition: ListingCondition = .good
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
    let photos = ListingPhotosViewModel()

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

    var priceValue: Int64? { ListingPrice.value(price) }

    /// Anything entered, closing the form would lose it, so Cancel asks.
    var hasChanges: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !price.isEmpty
            || !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || place != nil || photos.hasPhotos
    }



    var canContinue: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.count <= 100 && priceValue != nil
            && details.count <= 2000 && autoReply.count <= 500 && photos.isReady
    }

    // MARK: communities

    /// Your communities for this listing's mode (work ones for Work).
    func loadCommunities(token: String) async {
        isLoadingCommunities = true
        defer { isLoadingCommunities = false }
        let wanted: CommunityType = mode == .work ? .work : .fandom
        communities = ((try? await communityRepository.fetchMyCommunities(token: token)) ?? []).filter { $0.type == wanted }
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
            let uploaded = try await photos.upload()
            var listing: [String: Any] = [
                "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                "price": priceValue ?? 0,
                "condition": condition.rawValue,
                "hideFromFriends": hideFromFriends,
            ]
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
                "image_urls": uploaded.urls,
            ]
            if let alts = uploaded.alts { fields["image_alts"] = alts }
            return try await repository.create(fields: fields, token: token)
        } catch let upload as MediaUploadError {
            errorMessage = upload.errorDescription
        } catch {
            errorMessage = friendlyError(error)
        }
        return nil
    }
}
