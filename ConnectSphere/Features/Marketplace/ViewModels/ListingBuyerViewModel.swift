import Foundation
import Observation

/// The seller picking a buyer from their chats, to put units of an item on
/// deposit for them or to confirm their deposit as sold (which sends that
/// buyer a review card). A sale can only come from a deposit, so every review
/// card is a real buyer's delivered order.
@MainActor
@Observable
final class ListingBuyerViewModel {
    enum Mode: Equatable {
        /// `− [n] +`: how many units are held for the picked buyer.
        case deposit(ListingItem)
        /// Confirm the picked buyer's deposit on this item as sold.
        case confirm(ListingItem)
        /// Confirm every deposit the ticked buyers have in this listing.
        case confirmAll
    }

    /// One chat the seller can pick, with the buyer's deposit (on this item,
    /// or across the listing for `.confirmAll`).
    struct Buyer: Identifiable, Equatable {
        let id: String
        let conversationId: String
        let name: String
        let username: String
        let avatarColor: String
        let avatarUrl: String?
        let deposit: Int
    }

    let mode: Mode
    private(set) var buyers: [Buyer] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var query = ""
    var selected: Buyer?
    /// `.confirmAll`: the buyers ticked, by id.
    private(set) var checked: Set<String> = []
    /// The deposit being typed or stepped for the picked buyer.
    var amount = 0

    private let listing: ListingData
    private let messages = MessageRepository()
    private let repository = MarketplaceRepository()

    init(mode: Mode, listing: ListingData) {
        self.mode = mode
        self.listing = listing
    }

    var item: ListingItem? {
        switch mode {
        case .deposit(let item), .confirm(let item): return item
        case .confirmAll: return nil
        }
    }

    /// Search by name or @username.
    var shown: [Buyer] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return buyers }
        let bare = q.hasPrefix("@") ? String(q.dropFirst()) : q
        return buyers.filter { $0.name.lowercased().contains(q) || $0.username.lowercased().contains(bare) }
    }

    /// The most the picked buyer can have on deposit: what they hold plus the free units.
    var maxAmount: Int { (selected?.deposit ?? 0) + (item?.remaining ?? 0) }

    var canSave: Bool {
        guard !isSaving else { return false }
        if case .confirmAll = mode { return !checked.isEmpty }
        guard let selected else { return false }
        if case .deposit = mode { return amount != selected.deposit && (0...maxAmount).contains(amount) }
        return selected.deposit > 0
    }

    var allowsSeveral: Bool { mode == .confirmAll }

    // MARK: - Picking buyers
    func isPicked(_ buyer: Buyer) -> Bool { allowsSeveral ? checked.contains(buyer.id) : selected == buyer }

    func pick(_ buyer: Buyer) {
        if allowsSeveral {
            if checked.remove(buyer.id) == nil { checked.insert(buyer.id) }
            return
        }
        selected = buyer
        amount = buyer.deposit
    }

    /// The most allowed, when the typed deposit is over it; shown in red under the box.
    var amountLimitWarning: Int? {
        guard case .deposit = mode, selected != nil, amount > maxAmount else { return nil }
        return maxAmount
    }

    /// What the seller confirms before saving: a deposit changes what other
    /// buyers can still get, and a sale is final and sends a review card.
    var saveConfirmation: String? {
        if case .confirmAll = mode {
            let ticked = buyers.filter { checked.contains($0.id) }
            if ticked.count == 1 {
                return String(format: Bundle.app.loc("Mark all of %@'s deposits as sold and send review cards? This can't be undone."),
                              ticked[0].name)
            }
            return String(format: Bundle.app.loc("Mark all deposits from %lld buyers as sold and send review cards? This can't be undone."),
                          ticked.count)
        }
        guard let selected else { return nil }
        switch mode {
        case .confirm:
            return String(format: Bundle.app.loc("Mark %lld as sold to %@ and send a review card? This can't be undone."),
                          selected.deposit, selected.name)
        case .confirmAll, .deposit:
            break
        }
        if selected.deposit == 0 {
            return String(format: Bundle.app.loc("Put %lld on deposit for %@?"), amount, selected.name)
        }
        if amount == 0 {
            return String(format: Bundle.app.loc("Remove %@'s deposit of %lld?"), selected.name, selected.deposit)
        }
        return String(format: Bundle.app.loc("Change %@'s deposit from %lld to %lld?"),
                      selected.name, selected.deposit, amount)
    }

    /// Each deposit the seller holds for a buyer on the items this sheet is about.
    private var deposits: [String: (conversationId: String, quantity: Int)] {
        var out: [String: (conversationId: String, quantity: Int)] = [:]
        let items = item.map { [$0] } ?? listing.items
        for deposit in items.flatMap(\.deposits) {
            let had = out[deposit.buyerId]?.quantity ?? 0
            out[deposit.buyerId] = (deposit.conversationId, had + deposit.quantity)
        }
        return out
    }

    // MARK: - Load & save
    /// 1-on-1 Hobby chats that aren't archived (deleted ones aren't returned);
    /// for confirming, only buyers who have a deposit.
    func load(token: String) async {
        isLoading = true
        defer { isLoading = false }
        let held = deposits
        do {
            let chats = try await messages.fetchConversations(mode: AppMode.hobby.rawValue, token: token)
            buyers = chats.compactMap { chat -> Buyer? in
                guard !chat.isGroup, !chat.isArchived, !chat.isOfficialPeer,
                      case let .direct(otherUserId, username, name, avatarColor, avatarUrl, _, nickname) = chat.peer else {
                    return nil
                }
                let id = otherUserId.lowercased()
                return Buyer(id: id, conversationId: chat.id.lowercased(), name: nickname ?? name, username: username,
                             avatarColor: avatarColor, avatarUrl: avatarUrl, deposit: held[id]?.quantity ?? 0)
            }
            if case .deposit = mode { return }
            buyers = buyers.filter { $0.deposit > 0 }
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Returns the updated post when it went through.
    func save(token: String) async -> Post? {
        guard canSave else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            switch mode {
            case .deposit(let item):
                guard let selected else { return nil }
                return try await repository.setDeposit(listingId: listing.id, itemId: item.id,
                                                       conversationId: selected.conversationId, quantity: amount, token: token)
            case .confirm(let item):
                guard let selected else { return nil }
                return try await repository.confirmSale(listingId: listing.id, itemId: item.id, buyerIds: [selected.id],
                                                        token: token)
            case .confirmAll:
                return try await repository.confirmSale(listingId: listing.id, itemId: nil, buyerIds: Array(checked),
                                                        token: token)
            }
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }
}
