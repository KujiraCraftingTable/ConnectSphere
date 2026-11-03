import Foundation
import Observation
import PhotosUI
import SwiftUI

/// The dating profile's fields: 1–6 photos, a short bio, who you're
/// interested in, an age range, a distance, an optional height and kids
/// answer, and where the phone is. Used by the editor and, step by step, by
/// the first-time setup (`DatingSetupViewModel`).
@MainActor
@Observable
final class DatingProfileEditorViewModel {
    static let maxPhotos = 6
    static let maxBio = 500
    /// nil = any distance.
    static let distanceChoices: [Int?] = [5, 10, 25, 50, 100, 250, 500, nil]
    static let heights = Array(140...220)

    var bio: String
    var interestedIn: DatingInterest
    var minAge: Int
    var maxAge: Int
    var maxDistanceKm: Int?
    var heightCm: Int?
    var hasKids: DatingKids?
    /// Only ever from GPS (`DatingLocationProvider`), never typed.
    private(set) var place: PickedPlace?
    private(set) var isLocating = false
    /// The user said no to location, or it's off in iOS: Dating can't be used.
    private(set) var locationBlocked = false
    var pickerItems: [PhotosPickerItem] = []
    var photos: [PickedPostMedia]
    private(set) var isSaving = false
    var errorMessage: String?

    let isNew: Bool
    /// 16–17 only ever meet 16–17, so their range can't go past 17 (and an
    /// adult's can't go under 18).
    let ageBounds: ClosedRange<Int>

    private let repository = DatingRepository()
    private let locationProvider = DatingLocationProvider()
    /// The feed composer's photo loader and uploader (uploads lose their
    /// GPS and camera data on the server).
    private let mediaHelper = CreatePostViewModel()

    init(profile: DatingProfile?, isTeen: Bool) {
        let bounds = isTeen ? 16...17 : 18...99
        ageBounds = bounds
        isNew = profile == nil
        bio = profile?.bio ?? ""
        interestedIn = profile?.interestedIn ?? .everyone
        minAge = min(max(profile?.minAge ?? bounds.lowerBound, bounds.lowerBound), bounds.upperBound)
        maxAge = min(max(profile?.maxAge ?? (isTeen ? 17 : 35), bounds.lowerBound), bounds.upperBound)
        maxDistanceKm = profile == nil ? 50 : profile?.maxDistanceKm
        heightCm = profile?.heightCm
        hasKids = profile?.hasKids
        place = profile.map { PickedPlace(name: $0.city, latitude: $0.latitude, longitude: $0.longitude) }
        photos = PickedPostMedia.remote(profile?.photos ?? [], alts: [])
    }

    var pendingPhotoCount: Int { mediaHelper.pendingMediaCount }

    var canSave: Bool {
        place != nil && !photos.isEmpty && photos.count <= Self.maxPhotos
            && bio.count <= Self.maxBio && minAge <= maxAge && pendingPhotoCount == 0 && !isSaving
    }

    /// Keeps the range valid while either end moves.
    func setMinAge(_ value: Int) {
        minAge = value
        if maxAge < value { maxAge = value }
    }

    func setMaxAge(_ value: Int) {
        maxAge = value
        if minAge > value { minAge = value }
    }

    // MARK: location

    func useCurrentLocation() async {
        errorMessage = nil
        isLocating = true
        defer { isLocating = false }
        switch await locationProvider.currentPlace() {
        case .place(let found):
            place = found
            locationBlocked = false
        case .denied:
            locationBlocked = true
        case .failed:
            errorMessage = Bundle.app.loc("Couldn't get your location")
        }
    }

    /// "Don't allow" in the setup's location step.
    func refuseLocation() { locationBlocked = true }

    // MARK: photos

    func loadPicked() async {
        let loaded = await mediaHelper.loadSelectedMedia(pickerItems, keeping: photos) { [weak self] soFar in
            self?.photos = Array(soFar.prefix(Self.maxPhotos))
        }
        photos = Array(loaded.prefix(Self.maxPhotos))
    }

    func removePhoto(_ item: PickedPostMedia) {
        photos.removeAll { $0.id == item.id }
        if let picker = item.pickerItem { pickerItems.removeAll { $0 == picker } }
    }

    /// Makes a photo the first one, the one shown on the card.
    func makeCover(_ item: PickedPostMedia) {
        guard let i = photos.firstIndex(where: { $0.id == item.id }), i > 0 else { return }
        photos.insert(photos.remove(at: i), at: 0)
    }

    var remainingPhotoSlots: Int { max(0, Self.maxPhotos - photos.filter { $0.pickerItem == nil }.count) }

    // MARK: save

    /// The saved profile, or nil (with `errorMessage` set).
    func save(token: String) async -> DatingProfile? {
        guard let place else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            let urls = try await mediaHelper.uploadMedia(photos)
            let profile = DatingProfile(
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines), interestedIn: interestedIn,
                minAge: minAge, maxAge: maxAge, maxDistanceKm: maxDistanceKm, heightCm: heightCm, hasKids: hasKids,
                city: String(place.name.prefix(200)), latitude: place.latitude, longitude: place.longitude,
                isActive: true, photos: urls)
            return try await repository.save(profile, token: token)
        } catch let upload as MediaUploadError {
            errorMessage = upload.errorDescription
        } catch {
            errorMessage = friendlyError(error)
        }
        return nil
    }
}
