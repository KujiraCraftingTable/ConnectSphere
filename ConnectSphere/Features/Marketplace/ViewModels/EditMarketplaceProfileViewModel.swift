import Foundation
import Observation
import PhotosUI
import SwiftUI

/// The seller editing their Marketplace identity: name, photo, cover and bio
/// that only show on their listings and seller page. Anything left empty
/// uses their normal profile's.
@MainActor
@Observable
final class EditMarketplaceProfileViewModel {
    static let maxNameLength = 50
    static let maxBioLength = 300

    var name: String
    var bio: String
    /// New photos picked this session.
    private(set) var pickedAvatar: UIImage?
    /// The framed cover from `CoverCropView`, exactly what gets uploaded.
    var pickedCover: UIImage?
    /// The cover as picked, kept so its framing can be adjusted again.
    private(set) var coverOriginal: UIImage?
    /// The seller's own photo URLs; nil means "use my profile's".
    private(set) var avatarUrl: String?
    private(set) var coverUrl: String?
    private(set) var isSaving = false
    var errorMessage: String?

    /// What shows when a field is left empty: the normal profile's.
    let profile: SellerProfile
    private let repository = MarketplaceRepository()
    private let postRepository = PostRepository()

    init(profile: SellerProfile) {
        self.profile = profile
        name = profile.ownDisplayName ?? ""
        bio = profile.ownBio ?? ""
        avatarUrl = profile.ownAvatarUrl
        coverUrl = profile.ownCoverUrl
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBio: String { bio.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canSave: Bool {
        trimmedName.count <= Self.maxNameLength && trimmedBio.count <= Self.maxBioLength && !isSaving
    }

    /// Anything different from what was saved, so leaving asks first.
    var hasChanges: Bool {
        trimmedName != (profile.ownDisplayName ?? "") || trimmedBio != (profile.ownBio ?? "")
            || pickedAvatar != nil || pickedCover != nil
            || avatarUrl != profile.ownAvatarUrl || coverUrl != profile.ownCoverUrl
    }

    var hasOwnAvatar: Bool { pickedAvatar != nil || avatarUrl != nil }
    var hasOwnCover: Bool { pickedCover != nil || coverUrl != nil }

    // MARK: - Photo & cover
    func loadAvatar(from item: PhotosPickerItem) async {
        if let image = await Self.image(from: item) { pickedAvatar = image }
    }

    /// Returns true when a photo was loaded and is ready to be framed.
    func loadCover(from item: PhotosPickerItem) async -> Bool {
        guard let image = await Self.image(from: item) else { return false }
        coverOriginal = image
        return true
    }

    /// Back to the normal profile's photo.
    func useProfileAvatar() { pickedAvatar = nil; avatarUrl = nil }
    func useProfileCover() { pickedCover = nil; coverOriginal = nil; coverUrl = nil }

    // MARK: - Save
    /// Uploads any new photos, then saves. Returns the saved profile, or nil
    /// with `errorMessage` set.
    func save(token: String) async -> SellerProfile? {
        guard canSave else { return nil }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        if let data = pickedAvatar?.jpegData(compressionQuality: 1) {
            guard let url = try? await postRepository.uploadImage(data) else {
                errorMessage = Bundle.app.loc("Couldn't upload avatar, please try again")
                return nil
            }
            avatarUrl = url
            pickedAvatar = nil
        }
        if let data = pickedCover?.jpegData(compressionQuality: 1) {
            guard let url = try? await postRepository.uploadImage(data) else {
                errorMessage = Bundle.app.loc("Couldn't upload cover photo, please try again")
                return nil
            }
            coverUrl = url
            pickedCover = nil
        }
        do {
            return try await repository.updateSellerProfile(name: trimmedName, bio: trimmedBio, avatarUrl: avatarUrl,
                                                            coverUrl: coverUrl, token: token)
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }

    private static func image(from item: PhotosPickerItem) async -> UIImage? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return UIImage(data: data)
    }
}
