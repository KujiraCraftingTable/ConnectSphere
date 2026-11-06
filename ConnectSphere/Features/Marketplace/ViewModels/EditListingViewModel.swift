import Foundation
import Observation

/// The seller's "Edit listing" form: details, photos and price.
@MainActor
@Observable
final class EditListingViewModel {
    var title: String
    /// Whole đồng, shown grouped ("150.000"); empty or 0 = free.
    var price: String
    var condition: ListingCondition
    var place: PickedPlace?
    var autoReplyOn: Bool
    var autoReply: String
    var hideFromFriends: Bool
    var autoReupOn: Bool
    var autoReupDays: Int
    var autoReupHour: Int
    /// Whether the listing already had a schedule. Turning it off then has to be sent.
    private let hadAutoReup: Bool
    let photos: ListingPhotosViewModel
    private(set) var isSaving = false
    var errorMessage: String?

    /// Every field as it was when the form opened.
    private var openedSignature: [String] = []
    private var signature: [String] {
        [title, price, condition.rawValue, place.map { "\($0.name)|\($0.latitude)|\($0.longitude)" } ?? "",
         "\(autoReplyOn)", autoReply, "\(hideFromFriends)", "\(autoReupOn)", "\(autoReupDays)", "\(autoReupHour)",
         photos.media.map { $0.id.uuidString }.joined(separator: ",")]
    }
    /// Has anything been changed since the form opened? Cancel only asks then.
    var hasChanges: Bool { signature != openedSignature }

    init(post: Post, listing: ListingData) {
        title = listing.title
        price = listing.price > 0 ? ListingPrice.grouped(listing.price) : ""
        condition = listing.condition
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
        photos = ListingPhotosViewModel(urls: post.displayImageUrls, alts: post.displayImageAlts)
        openedSignature = signature
    }



    var isValid: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.count <= 100 && ListingPrice.value(price) != nil
            && autoReply.count <= 500 && photos.isReady
    }

    /// Uploads any new photos and builds the PATCH body; nil (with `errorMessage`) if that fails.
    func fields() async -> [String: Any]? {
        isSaving = true
        defer { isSaving = false }
        do {
            let uploaded = try await photos.upload()
            var fields: [String: Any] = [
                "title": title, "price": ListingPrice.value(price) ?? 0, "condition": condition.rawValue,
                "location": place.map { String($0.name.prefix(150)) } ?? "",
                "auto_reply": autoReplyOn ? autoReply : "",
                "hide_from_friends": hideFromFriends,
                "image_urls": uploaded.urls,
                "image_alts": uploaded.alts ?? uploaded.urls.map { _ in "" },
            ]
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
