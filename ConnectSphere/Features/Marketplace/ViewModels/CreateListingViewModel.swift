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
    // Step 1 — the item. The description is the post's text; the photos and
    // videos its media.
    var title = ""
    /// Whole VND as typed; empty or 0 = free.
    var price = ""
    var condition: ListingCondition = .good
    /// Where the item is, picked on the map.
    var place: PickedPlace?
    var details = ""
    var autoReplyOn = true
    var autoReply = Bundle.app.loc("Hi! Yes, it's still available.")
    var hideFromFriends = false
    var pickerItems: [PhotosPickerItem] = []
    var media: [PickedPostMedia] = []

    // Step 2 — where else it shows.
    private(set) var communities: [Community] = []
    private(set) var selected: [String] = []
    private(set) var isLoadingCommunities = false

    private(set) var isPublishing = false
    var errorMessage: String?

    static let maxCommunities = 5
    static let maxMedia = 10

    private let mode: AppMode
    private let repository = MarketplaceRepository()
    private let communityRepository = CommunityRepository()
    /// The feed composer's photo/video loader and uploader.
    private let mediaHelper = CreatePostViewModel()

    /// `preselected`: communities already ticked in step 2 (selling from a
    /// community's own composer).
    init(mode: AppMode, preselected: [String] = []) {
        self.mode = mode
        self.selected = Array(preselected.prefix(Self.maxCommunities))
    }

    var priceValue: Int64? {
        let digits = price.filter(\.isNumber)
        return digits.isEmpty ? 0 : Int64(digits)
    }

    var pendingMediaCount: Int { mediaHelper.pendingMediaCount }

    var canContinue: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.count <= 100 && priceValue != nil
            && details.count <= 2000 && autoReply.count <= 500 && pendingMediaCount == 0
    }

    // MARK: media

    func loadPicked() async {
        media = await mediaHelper.loadSelectedMedia(pickerItems, keeping: media) { [weak self] soFar in
            self?.media = soFar
        }
    }

    func removeMedia(_ item: PickedPostMedia) {
        media.removeAll { $0.id == item.id }
        if let picker = item.pickerItem { pickerItems.removeAll { $0 == picker } }
    }

    func setAltText(_ text: String, for id: PickedPostMedia.ID) {
        if let i = media.firstIndex(where: { $0.id == id }) { media[i].altText = text }
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
            let urls = try await mediaHelper.uploadMedia(media)
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
            var fields: [String: Any] = [
                "content": details.trimmingCharacters(in: .whitespacesAndNewlines),
                "mode": mode.rawValue,
                "listingData": listing,
                "community_ids": selected,
            ]
            if !urls.isEmpty { fields["image_urls"] = urls }
            if media.contains(where: { !$0.altText.isEmpty }) { fields["image_alts"] = media.map(\.altText) }
            return try await repository.create(fields: fields, token: token)
        } catch let upload as MediaUploadError {
            errorMessage = upload.errorDescription
        } catch {
            errorMessage = friendlyError(error)
        }
        return nil
    }
}
