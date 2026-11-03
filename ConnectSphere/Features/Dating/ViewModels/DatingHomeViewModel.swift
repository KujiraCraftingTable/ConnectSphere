import Foundation
import Observation

/// The Dating space: whether it's open to this account, the people to like
/// or pass, who liked you, and your matches. The server decides the age
/// gate; this only shows what it answers.
@MainActor
@Observable
final class DatingHomeViewModel {
    enum Tab: Hashable { case discover, likesYou, matches }

    private(set) var status: DatingStatus?
    private(set) var isLoading = false
    private(set) var deck: [DatingCard] = []
    private(set) var likers: [DatingLiker] = []
    private(set) var matches: [DatingMatch] = []
    private(set) var isLoadingDeck = false
    var tab: Tab = .discover
    var errorMessage: String?

    /// Set when a like made a new match — the "It's a match" moment.
    var newMatch: NewMatch?

    struct NewMatch: Identifiable {
        let person: DatingCard
        let conversationId: String?
        var id: String { person.id }
    }

    /// The first load failed (e.g. the server can't be reached) — the screen
    /// offers Retry instead of a blank page.
    private(set) var loadFailed = false
    /// Location is off for the app: Discover can't be used until it's back.
    private(set) var locationBlocked = false

    private let repository = DatingRepository()
    private let locationProvider = DatingLocationProvider()

    var profile: DatingProfile? { status?.profile }
    var isLocked: Bool { status?.isLocked ?? false }
    var needsProfile: Bool { status.map { !$0.isLocked && $0.profile == nil } ?? false }

    func load(token: String) async {
        isLoading = status == nil
        defer { isLoading = false }
        do {
            status = try await repository.status(token: token)
            loadFailed = false
        } catch {
            if status == nil { loadFailed = true } else { errorMessage = friendlyError(error) }
            return
        }
        guard profile != nil else { return }
        await refreshAll(token: token)
        await refreshLocation(token: token)
    }

    /// Sends the phone's position each time Dating opens; a move of under a
    /// kilometre isn't worth a write. With location off, Discover is shut.
    func refreshLocation(token: String) async {
        switch await locationProvider.currentPlace() {
        case .denied:
            locationBlocked = true
        case .failed:
            break
        case .place(let here):
            locationBlocked = false
            guard let saved = profile,
                  DatingLocationProvider.distanceKm(here, (saved.latitude, saved.longitude)) >= 1 else { return }
            do {
                try await repository.updateLocation(city: here.name, latitude: here.latitude,
                                                    longitude: here.longitude, token: token)
                status?.profile?.city = here.name
                status?.profile?.latitude = here.latitude
                status?.profile?.longitude = here.longitude
                await refreshDeck(token: token)
            } catch {
                errorMessage = friendlyError(error)
            }
        }
    }

    func refreshAll(token: String) async {
        async let deckTask: Void = refreshDeck(token: token)
        async let likesTask: Void = refreshLikes(token: token)
        async let matchesTask: Void = refreshMatches(token: token)
        _ = await (deckTask, likesTask, matchesTask)
    }

    func refreshDeck(token: String) async {
        isLoadingDeck = true
        defer { isLoadingDeck = false }
        do { deck = try await repository.browse(token: token) } catch { errorMessage = friendlyError(error) }
    }

    func refreshLikes(token: String) async {
        do { likers = try await repository.likesYou(token: token) } catch { errorMessage = friendlyError(error) }
    }

    func refreshMatches(token: String) async {
        do { matches = try await repository.matches(token: token) } catch { errorMessage = friendlyError(error) }
    }

    /// After the editor saved: the profile is on, so everything is fetched again.
    func profileSaved(_ saved: DatingProfile, token: String) async {
        status?.profile = saved
        locationBlocked = false
        await refreshAll(token: token)
    }

    // MARK: like / pass

    /// Takes the person off the deck (or Likes you) straight away and puts
    /// them back if the server refuses.
    func respond(to card: DatingCard, liked: Bool, token: String) async {
        let deckIndex = deck.firstIndex(of: card)
        let likerIndex = likers.firstIndex { $0.card.id == card.id }
        let removedLiker = likerIndex.map { likers[$0] }
        if let deckIndex { deck.remove(at: deckIndex) }
        if let likerIndex { likers.remove(at: likerIndex) }
        do {
            let result = try await repository.respond(to: card.id, liked: liked, token: token)
            if result.isNew {
                newMatch = NewMatch(person: card, conversationId: result.conversationId)
                NotificationCenter.default.post(name: .datingMatchesChanged, object: nil)
                await refreshMatches(token: token)
            }
            if deck.isEmpty { await refreshDeck(token: token) }
        } catch {
            if let deckIndex { deck.insert(card, at: min(deckIndex, deck.count)) }
            if let likerIndex, let removedLiker { likers.insert(removedLiker, at: min(likerIndex, likers.count)) }
            errorMessage = friendlyError(error)
        }
    }

    // MARK: matches

    func unmatch(_ match: DatingMatch, token: String) async {
        do {
            try await repository.unmatch(match.id, token: token)
            matches.removeAll { $0.id == match.id }
            NotificationCenter.default.post(name: .datingMatchesChanged, object: nil)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    // MARK: profile

    /// "Take a break" hides you from Discover and Likes you; matches stay.
    func setActive(_ active: Bool, token: String) async {
        guard profile != nil else { return }
        do {
            try await repository.setActive(active, token: token)
            status?.profile?.isActive = active
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Deletes the profile with every like and match. True when it's gone.
    func deleteProfile(token: String) async -> Bool {
        do {
            try await repository.deleteProfile(token: token)
            status?.profile = nil
            deck = []; likers = []; matches = []
            NotificationCenter.default.post(name: .datingMatchesChanged, object: nil)
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }
}
