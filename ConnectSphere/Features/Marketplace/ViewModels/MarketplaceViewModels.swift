import Foundation
import Observation

/// The Marketplace tab: available listings in your communities for the mode
/// you're in, searchable and filterable by community.
@MainActor
@Observable
final class MarketplaceViewModel {
    private(set) var listings: [Post] = []
    /// Your communities in this mode. The filter chips and where "Sell" posts.
    private(set) var communities: [Community] = []
    private(set) var isLoading = false
    private(set) var canLoadMore = true
    private(set) var errorMessage: String?
    var query = ""
    var communityId: String?
    /// "Yours": only the signed-in user's items (sold ones too) instead of everyone's.
    private(set) var mineOnly = false
    private var sellerId: String?

    private let repository = MarketplaceRepository()
    private let communityRepository = CommunityRepository()
    private var searchTask: Task<Void, Never>?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        // A listing edited, sold or deleted elsewhere (its own page) updates here too.
        observers.append(NotificationCenter.default.addObserver(
            forName: .postUpdated, object: nil, queue: .main
        ) { [weak self] note in
            guard let post = note.userInfo?["post"] as? Post else { return }
            MainActor.assumeIsolated { self?.apply(post) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .postDeleted, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            MainActor.assumeIsolated { self?.listings.removeAll { $0.id == id } }
        })
        // A re-up swaps the item's post for a new one, which sorts first.
        observers.append(NotificationCenter.default.addObserver(
            forName: .listingReupped, object: nil, queue: .main
        ) { [weak self] note in
            guard let oldId = note.userInfo?["oldId"] as? String, let post = note.userInfo?["post"] as? Post else { return }
            MainActor.assumeIsolated {
                guard let self, self.listings.contains(where: { $0.id == oldId }) else { return }
                self.listings.removeAll { $0.id == oldId }
                self.listings.insert(post, at: 0)
            }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func load(mode: AppMode, token: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let mine = communityRepository.fetchMyCommunities(token: token)
            async let page = repository.listings(mode: mode, query: query, communityId: communityId, sellerId: sellerId, offset: 0, token: token)
            let wantedType: CommunityType = mode == .work ? .work : .fandom
            communities = try await mine.filter { $0.type == wantedType }
            listings = try await page
            canLoadMore = listings.count == 30
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func loadMore(mode: AppMode, token: String) async {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let page = try? await repository.listings(mode: mode, query: query, communityId: communityId, sellerId: sellerId,
                                                         offset: listings.count, token: token) else { return }
        listings += page.filter { new in !listings.contains { $0.id == new.id } }
        canLoadMore = page.count == 30
    }

    /// Re-runs the search 300 ms after typing stops.
    func searchSoon(mode: AppMode, token: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await load(mode: mode, token: token)
        }
    }

    /// Switches between everyone's items and just the user's own.
    func setMine(_ on: Bool, mode: AppMode, userId: String?, token: String) async {
        guard on != mineOnly, !on || userId != nil else { return }
        mineOnly = on
        sellerId = on ? userId : nil
        await load(mode: mode, token: token)
    }

    func pickCommunity(_ id: String?, mode: AppMode, token: String) async {
        communityId = id
        await load(mode: mode, token: token)
    }

    /// A new listing from "Sell" shows straight away (unless it's waiting
    /// for the community's approval).
    func added(_ post: Post) {
        guard post.listingData != nil, post.publishStatus != "pending" else { return }
        listings.insert(post, at: 0)
    }

    private func apply(_ post: Post) {
        guard let i = listings.firstIndex(where: { $0.id == post.id }) else { return }
        // Sold listings leave the tab (unless it's "Yours"); they stay on their community's page.
        if post.listingData?.isSold == true && !mineOnly { listings.remove(at: i) } else { listings[i] = post }
    }
}

/// A seller as the Marketplace shows them: their other items for sale in this
/// mode (sold ones last), not their whole profile.
@MainActor
@Observable
final class MarketplaceSellerViewModel {
    /// Starts as the item's author (name and photo), then the full profile
    /// (cover, location) once it loads.
    private(set) var seller: UserProfile
    private(set) var items: [Post] = []
    private(set) var isLoading = false
    private(set) var canLoadMore = true
    var errorMessage: String?

    private let mode: AppMode
    /// The item the page was opened from, not repeated in "other items".
    private let excludedId: String
    /// How many the server has returned, the excluded item included. The next page's offset.
    private var fetched = 0
    private let repository = MarketplaceRepository()

    init(seller: UserProfile, mode: AppMode, excluding postId: String) {
        self.seller = seller
        self.mode = mode
        self.excludedId = postId
    }

    func load(token: String) async {
        isLoading = true
        defer { isLoading = false }
        if let full = try? await ProfileRepository().fetchUser(userId: seller.id, mode: mode.rawValue) { seller = full }
        do {
            let page = try await repository.listings(mode: mode, query: "", communityId: nil, sellerId: seller.id,
                                                     offset: 0, token: token)
            items = page.filter { $0.id != excludedId }
            fetched = page.count
            canLoadMore = page.count == 30
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func loadMore(token: String) async {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let page = try? await repository.listings(mode: mode, query: "", communityId: nil, sellerId: seller.id,
                                                         offset: fetched, token: token) else { return }
        items += page.filter { new in new.id != excludedId && !items.contains { $0.id == new.id } }
        fetched += page.count
        canLoadMore = page.count == 30
    }
}

/// One listing: messaging the seller, and the seller's own edits.
@MainActor
@Observable
final class ListingViewModel {
    private(set) var post: Post
    private(set) var isWorking = false
    private(set) var isOpeningChat = false
    var errorMessage: String?

    private let repository = MarketplaceRepository()

    init(post: Post) { self.post = post }

    var listing: ListingData? { post.listingData }

    func isSeller(_ userId: String?) -> Bool { userId == post.author.id }

    /// Opens the chat with the seller in the listing's mode and sends the
    /// listing into it, so they know what it's about (the seller's
    /// auto-reply follows from the server). The conversation id, or nil.
    func messageSeller(token: String) async -> String? {
        isOpeningChat = true
        defer { isOpeningChat = false }
        let messages = MessageRepository()
        do {
            let conversationId = try await messages.openConversation(otherUserId: post.author.id,
                                                                     mode: post.mode.rawValue, token: token)
            _ = try await messages.sendPost(conversationId: conversationId, postId: post.id, note: "", token: token)
            return conversationId
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }

    var isSaved: Bool { post.isSaved }

    /// Save / unsave the item, shown under Saved → Marketplace. Broadcasts the
    /// new state like a post's bookmark does, so the Saved list updates.
    func toggleSave() async {
        post.isSaved.toggle()
        let repository = PostRepository()
        do {
            if post.isSaved { try await repository.savePost(postId: post.id) }
            else { try await repository.unsavePost(postId: post.id) }
            NotificationCenter.default.post(name: .postUpdated, object: nil, userInfo: ["post": post])
        } catch {
            post.isSaved.toggle()
        }
    }

    func setSold(_ sold: Bool, token: String) async {
        await save(["status": sold ? "sold" : "available"], token: token)
    }

    /// Posts the item again as new, in the communities it was listed in. True when done.
    @discardableResult
    func reup(token: String) async -> Bool {
        guard let id = listing?.id else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let oldId = post.id
            post = try await repository.reup(id: id, token: token)
            NotificationCenter.default.post(name: .listingReupped, object: nil,
                                            userInfo: ["oldId": oldId, "post": post])
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }

    /// Stops the item's auto re-up (it can be set again from Edit listing).
    func cancelAutoReup(token: String) async {
        await save(["clear_auto_reup": true], token: token)
    }

    /// The seller's edits from the edit sheet. True when saved.
    @discardableResult
    func save(_ fields: [String: Any], token: String) async -> Bool {
        guard let id = listing?.id else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            post = try await repository.update(id: id, fields: fields, token: token)
            NotificationCenter.default.post(name: .postUpdated, object: nil, userInfo: ["post": post])
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }

    /// After the admin's Warn or ban sheet closes: true when the listing was taken
    /// down (the server bans the post with the warning), and the Marketplace grids
    /// drop it like a deleted item.
    func wasTakenDown() -> Bool {
        guard case .moderated = HiddenPostsRegistry.shared.kind(for: post.id) else { return false }
        NotificationCenter.default.post(name: .postDeleted, object: nil,
                                        userInfo: ["id": post.id, "authorId": post.author.id])
        return true
    }

    /// Deletes the listing's post. True when gone.
    func delete() async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            try await PostRepository().deletePost(postId: post.id)
            NotificationCenter.default.post(name: .postDeleted, object: nil,
                                            userInfo: ["id": post.id, "authorId": post.author.id])
            return true
        } catch {
            errorMessage = Bundle.app.loc("Couldn't delete post, please try again")
            return false
        }
    }
}

/// "Your items": everything you have for sale in this mode, sold ones last.
@MainActor
@Observable
final class MarketplaceMyItemsViewModel {
    enum Filter { case all, available }

    private(set) var items: [Post] = []
    private(set) var isLoading = false
    private(set) var canLoadMore = true
    var errorMessage: String?
    var filter: Filter = .all

    /// What the screen shows: every item, or only those still for sale.
    var visibleItems: [Post] {
        filter == .all ? items : items.filter { $0.listingData?.isSold != true }
    }

    private let mode: AppMode
    private let sellerId: String
    private let repository = MarketplaceRepository()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(mode: AppMode, sellerId: String) {
        self.mode = mode
        self.sellerId = sellerId
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .postUpdated, object: nil, queue: .main) { [weak self] note in
            guard let post = note.userInfo?["post"] as? Post else { return }
            MainActor.assumeIsolated {
                guard let self, let i = self.items.firstIndex(where: { $0.id == post.id }) else { return }
                self.items[i] = post
            }
        })
        observers.append(center.addObserver(forName: .postDeleted, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            MainActor.assumeIsolated { self?.items.removeAll { $0.id == id } }
        })
        observers.append(center.addObserver(forName: .listingReupped, object: nil, queue: .main) { [weak self] note in
            guard let oldId = note.userInfo?["oldId"] as? String, let post = note.userInfo?["post"] as? Post else { return }
            MainActor.assumeIsolated {
                guard let self, let i = self.items.firstIndex(where: { $0.id == oldId }) else { return }
                self.items[i] = post
            }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func load(token: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await repository.listings(mode: mode, query: "", communityId: nil, sellerId: sellerId,
                                                  offset: 0, token: token)
            canLoadMore = items.count == 30
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func loadMore(token: String) async {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let page = try? await repository.listings(mode: mode, query: "", communityId: nil, sellerId: sellerId,
                                                         offset: items.count, token: token) else { return }
        items += page.filter { new in !items.contains { $0.id == new.id } }
        canLoadMore = page.count == 30
    }
}
