import Foundation
import Observation
import PhotosUI
import SwiftUI

/// One listing item's photos (and videos) while it's being created or edited:
/// the picker, what's been loaded, alt text and the upload. An item needs
/// 1–6 (`isReady`).
@MainActor
@Observable
final class ListingPhotosViewModel {
    /// Same cap as the server (`ListingStore.maxItemPhotos`).
    static let maxMedia = 6

    var pickerItems: [PhotosPickerItem] = []
    private(set) var media: [PickedPostMedia]

    /// The feed composer's photo/video loader and uploader.
    private let helper = CreatePostViewModel()

    /// `urls`/`alts`: the photos an existing listing already has.
    init(urls: [String] = [], alts: [String] = []) {
        media = PickedPostMedia.remote(urls, alts: alts)
    }

    var pendingCount: Int { helper.pendingMediaCount }
    var hasPhotos: Bool { !media.isEmpty }
    var isOverLimit: Bool { media.count > Self.maxMedia }
    var isReady: Bool { hasPhotos && !isOverLimit && pendingCount == 0 }

    func loadPicked() async {
        media = await helper.loadSelectedMedia(pickerItems, keeping: media) { [weak self] soFar in
            self?.media = soFar
        }
    }

    func remove(_ item: PickedPostMedia) {
        media.removeAll { $0.id == item.id }
        if let picker = item.pickerItem { pickerItems.removeAll { $0 == picker } }
    }

    func setAltText(_ text: String, for id: PickedPostMedia.ID) {
        if let i = media.firstIndex(where: { $0.id == id }) { media[i].altText = text }
    }

    /// Uploads what's new; the urls in order, and the alts if any was written.
    func upload() async throws -> (urls: [String], alts: [String]?) {
        let urls = try await helper.uploadMedia(media)
        return (urls, media.contains { !$0.altText.isEmpty } ? media.map(\.altText) : nil)
    }
}
