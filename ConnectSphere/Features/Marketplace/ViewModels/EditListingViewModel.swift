import Foundation
import Observation

/// The seller's "Edit listing" form: the headline, the items (each with its
/// photos and price) and the listing's own settings.
@MainActor
@Observable
final class EditListingViewModel {
    /// The headline, shown once there are several items.
    var headline: String
    /// The description, exactly as the seller writes it.
    var details: String
    let items: ListingItemsViewModel
    var place: PickedPlace?
    var autoReplyOn: Bool
    var autoReply: String
    var hideFromFriends: Bool
    var autoReupOn: Bool
    var autoReupDays: Int
    var autoReupHour: Int
    /// Whether the listing already had a schedule. Turning it off then has to be sent.
    private let hadAutoReup: Bool

    /// A community in the "Also list in" checklist.
    struct CommunityChoice: Identifiable {
        let id: String
        let name: String
        let waitsForApproval: Bool
    }
    private let mode: AppMode
    /// Where it's listed (or waiting) as the form opened.
    private let listedIn: [ListingData.ListedIn]
    private let openedCommunities: [String]
    private(set) var selectedCommunities: [String]
    private(set) var communityChoices: [CommunityChoice] = []
    private(set) var isLoadingCommunities = false
    private let communityRepository = CommunityRepository()
    private(set) var isSaving = false
    var errorMessage: String?

    /// Every field as it was when the form opened.
    private var openedSignature: [String] = []
    private var signature: [String] {
        [headline, details, place.map { "\($0.name)|\($0.latitude)|\($0.longitude)" } ?? "",
         "\(autoReplyOn)", autoReply, "\(hideFromFriends)", "\(autoReupOn)", "\(autoReupDays)", "\(autoReupHour)",
         selectedCommunities.sorted().joined(separator: ",")]
    }
    /// Has anything been changed since the form opened? Cancel only asks then.
    var hasChanges: Bool { signature != openedSignature || items.hasChanges }

    init(listing: ListingData, mode: AppMode, description: String) {
        self.mode = mode
        listedIn = listing.communities
        openedCommunities = listing.communities.map(\.id)
        selectedCommunities = openedCommunities
        headline = listing.title
        details = description
        items = ListingItemsViewModel(items: listing.items)
        place = listing.latitude.flatMap { lat in
            listing.longitude.map { PickedPlace(name: listing.location ?? listing.title, latitude: lat, longitude: $0) }
        }
        autoReplyOn = listing.hasAutoReply
        autoReply = listing.autoReply ?? Bundle.app.loc("Hi! Yes, it's still available.")
        hideFromFriends = listing.hideFromFriends
        hadAutoReup = listing.autoReup != nil
        autoReupOn = listing.autoReup != nil
        autoReupDays = listing.autoReup?.days ?? 3
        autoReupHour = listing.autoReup?.hour ?? 9
        openedSignature = signature
    }

    // MARK: communities

    /// Your communities for this mode, plus any it's in that you've since left
    /// (unticking takes it out; it can't be ticked again from here).
    func loadCommunities(token: String) async {
        isLoadingCommunities = true
        defer { isLoadingCommunities = false }
        // Communities are Hobby-only (migration 127).
        let mine = mode == .hobby
            ? ((try? await communityRepository.fetchMyCommunities(token: token)) ?? []).filter { $0.type == .fandom }
            : []
        var choices = mine.map {
            CommunityChoice(id: $0.id, name: $0.name,
                            waitsForApproval: $0.requirePostApproval && $0.role != .admin && $0.role != .moderator)
        }
        for l in listedIn where !choices.contains(where: { $0.id == l.id }) {
            choices.append(CommunityChoice(id: l.id, name: l.name, waitsForApproval: false))
        }
        communityChoices = choices
    }

    func isSelected(_ id: String) -> Bool { selectedCommunities.contains(id) }

    var isCommunitiesFull: Bool { selectedCommunities.count >= CreateListingViewModel.maxCommunities }

    func toggleCommunity(_ id: String) {
        if let i = selectedCommunities.firstIndex(of: id) { selectedCommunities.remove(at: i) }
        else if !isCommunitiesFull { selectedCommunities.append(id) }
    }

    /// Under the name: still waiting for the admins, or will wait once ticked.
    func note(for choice: CommunityChoice) -> String? {
        if listedIn.contains(where: { $0.id == choice.id && $0.isPending }) { return Bundle.app.loc("Waiting for admin approval") }
        if !openedCommunities.contains(choice.id) && choice.waitsForApproval { return Bundle.app.loc("Waits for admin approval") }
        return nil
    }

    private var trimmedHeadline: String { headline.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isValid: Bool {
        let headlineOK = !items.hasSeveral || (!trimmedHeadline.isEmpty && trimmedHeadline.count <= 100)
        return headlineOK && items.isValid && details.count <= 2000 && autoReply.count <= 500
    }

    /// Uploads any new photos and builds the PATCH body; nil (with `errorMessage`) if that fails.
    /// With one item, that item's title is the headline.
    func fields() async -> [String: Any]? {
        isSaving = true
        defer { isSaving = false }
        do {
            let itemBodies = try await items.upload()
            var fields: [String: Any] = [
                "title": items.hasSeveral ? trimmedHeadline : (itemBodies.first?["title"] as? String ?? trimmedHeadline),
                "items": itemBodies,
                "content": details.trimmingCharacters(in: .whitespacesAndNewlines),
                "content_format": PostRepository.contentFormat,
                "location": place.map { String($0.name.prefix(150)) } ?? "",
                "auto_reply": autoReplyOn ? autoReply : "",
                "hide_from_friends": hideFromFriends,
            ]
            if selectedCommunities.sorted() != openedCommunities.sorted() {
                fields["community_ids"] = selectedCommunities
            }
            if autoReupOn {
                fields["auto_reup"] = ["every_days": autoReupDays, "hour": autoReupHour]
            } else if hadAutoReup {
                fields["clear_auto_reup"] = true
            }
            if let place {
                fields["latitude"] = place.latitude
                fields["longitude"] = place.longitude
            } else {
                fields["clear_coordinates"] = true
            }
            return fields
        } catch let upload as MediaUploadError {
            errorMessage = upload.errorDescription
        } catch {
            errorMessage = friendlyError(error)
        }
        return nil
    }
}
