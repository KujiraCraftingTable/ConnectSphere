import Foundation
import Observation

/// One item in the sell or edit form: its own title, price, condition and
/// photos. `itemId` is the server's id when editing an item already listed,
/// so it keeps its sold state.
@MainActor
@Observable
final class ListingItemDraft: Identifiable {
    let id = UUID()
    let itemId: String?
    var title: String
    /// Whole đồng, shown grouped ("150.000"); empty or 0 = free.
    var price: String
    var condition: ListingCondition
    let photos: ListingPhotosViewModel

    init(item: ListingItem? = nil) {
        itemId = item?.id
        title = item?.title ?? ""
        price = item.map { $0.price > 0 ? ListingPrice.grouped($0.price) : "" } ?? ""
        condition = item?.condition ?? .good
        photos = ListingPhotosViewModel(urls: item?.imageUrls ?? [], alts: item?.imageAlts ?? [])
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isValid: Bool {
        !trimmedTitle.isEmpty && trimmedTitle.count <= 100 && ListingPrice.value(price) != nil && photos.isReady
    }

    var isEmpty: Bool { trimmedTitle.isEmpty && price.isEmpty && !photos.hasPhotos }

    var signature: String {
        [title, price, condition.rawValue, photos.media.map { $0.id.uuidString }.joined(separator: ",")]
            .joined(separator: "|")
    }

    /// Uploads its new photos; the item as the server takes it.
    func body() async throws -> [String: Any] {
        let uploaded = try await photos.upload()
        var body: [String: Any] = [
            "title": trimmedTitle,
            "price": ListingPrice.value(price) ?? 0,
            "condition": condition.rawValue,
            "image_urls": uploaded.urls,
        ]
        if let alts = uploaded.alts { body["image_alts"] = alts }
        if let itemId { body["id"] = itemId }
        return body
    }
}

/// The list of items being sold in one listing (1–20), shared by the sell
/// form and Edit listing.
@MainActor
@Observable
final class ListingItemsViewModel {
    /// Same cap as the server (`ListingStore.maxItems`).
    static let maxItems = 20

    private(set) var drafts: [ListingItemDraft]
    private var openedSignature = ""

    init(items: [ListingItem] = []) {
        drafts = items.isEmpty ? [ListingItemDraft()] : items.map { ListingItemDraft(item: $0) }
        openedSignature = signature
    }

    var hasSeveral: Bool { drafts.count > 1 }
    var canAdd: Bool { drafts.count < Self.maxItems }
    var isValid: Bool { drafts.allSatisfy(\.isValid) }
    var hasEntries: Bool { drafts.contains { !$0.isEmpty } }
    var hasChanges: Bool { signature != openedSignature }

    private var signature: String { drafts.map(\.signature).joined(separator: "#") }

    func add() {
        guard canAdd else { return }
        drafts.append(ListingItemDraft())
    }

    func remove(_ id: ListingItemDraft.ID) {
        guard hasSeveral else { return }
        drafts.removeAll { $0.id == id }
    }

    /// Uploads every item's new photos, in order; the `items` the server takes.
    func upload() async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for draft in drafts { out.append(try await draft.body()) }
        return out
    }
}
