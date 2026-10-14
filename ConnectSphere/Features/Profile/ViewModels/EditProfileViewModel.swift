import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

/// Editing the current mode's persona: fields, avatar, and a framed cover.
/// Saves via PATCH /api/users/me.
@MainActor
@Observable
final class EditProfileViewModel {
    var displayName = "" {
        didSet { if displayName.count > DisplayNameRules.maxLength { displayName = DisplayNameRules.capped(displayName) } }
    }
    var bio = ""
    var jobTitle = ""
    var company = ""
    var location = ""
    var email = ""
    /// "yyyy-MM-dd", the same format onboarding uses; empty = not set.
    var dob = ""
    var dobVisibility = "private"
    var selectedInterests: [InterestItem] = []
    /// Comma-separated, the same as onboarding.
    /// Added one at a time in a SkillTagField.
    var skills: [String] = []

    /// New avatar picked this session (nil = keep the current one).
    private(set) var pickedImage: UIImage?
    /// The framed cover from `CoverCropView` — exactly what gets uploaded.
    var pickedCover: UIImage?
    /// The cover as picked, kept until Save so its framing can be adjusted again.
    private(set) var coverOriginal: UIImage?

    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let profileRepository = ProfileRepository()
    private let postRepository = PostRepository()   // owns the image-upload endpoint

    private static let dobFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var canSave: Bool { !isSaving && !displayName.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The date picker's value; an unset dob shows 20 years ago.
    var dobDate: Date {
        get { Self.dobFormatter.date(from: dob) ?? Calendar.current.date(byAdding: .year, value: -20, to: Date())! }
        set { dob = Self.dobFormatter.string(from: newValue) }
    }

    func load(from user: UserProfile?) {
        guard let user else { return }
        displayName = user.name
        bio         = user.bio
        jobTitle    = user.jobTitle ?? ""
        company     = user.company ?? ""
        location    = user.location ?? ""
        email       = user.email ?? ""
        skills      = user.skills
        // The backend returns dob as "yyyy-MM-dd" or a full ISO timestamp (a
        // Postgres DATE in JSON) — the first 10 characters are yyyy-MM-dd either
        // way. Older accounts may have none: leave it blank.
        dob           = String((user.dob ?? "").prefix(10))
        dobVisibility = user.dobVisibility ?? "private"
        // Reverse-parse displayText "Anime · Dandadan" → category + rawInput.
        selectedInterests = user.interests.map { text in
            let parts = text.components(separatedBy: " · ")
            return InterestItem(category: parts[0],
                                rawInput: parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : "")
        }
    }

    func loadAvatar(from item: PhotosPickerItem) async {
        if let image = await Self.image(from: item) { pickedImage = image }
    }

    /// Returns true when a photo was loaded and is ready to be framed.
    func loadCover(from item: PhotosPickerItem) async -> Bool {
        guard let image = await Self.image(from: item) else { return false }
        coverOriginal = image
        return true
    }

    /// Uploads any new avatar/cover first, then saves every field. Returns the
    /// updated profile, or nil with `errorMessage` set.
    func save(mode: AppMode) async -> UserProfile? {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        var avatarUrl: String?
        if let data = pickedImage?.jpegData(compressionQuality: 1) {
            avatarUrl = try? await postRepository.uploadImage(data)
            if avatarUrl == nil {
                errorMessage = Bundle.app.loc("Couldn't upload avatar, please try again")
                return nil
            }
        }
        var coverUrl: String?
        if let data = pickedCover?.jpegData(compressionQuality: 1) {
            coverUrl = try? await postRepository.uploadImage(data)
            if coverUrl == nil {
                errorMessage = Bundle.app.loc("Couldn't upload cover photo, please try again")
                return nil
            }
        }

        // Both arrays are sent in full (they were pre-loaded, so untouched entries
        // survive): the backend makes each list exactly what's sent.
        let update = ProfileRepository.ProfileUpdate(
            mode:           mode.rawValue,   // edits this mode's persona
            display_name:   displayName.trimmingCharacters(in: .whitespaces),
            bio:            bio.trimmingCharacters(in: .whitespaces),
            location:       location.trimmingCharacters(in: .whitespaces),
            dob:            dob.isEmpty ? nil : dob,
            dob_visibility: dobVisibility,
            job_title:      jobTitle.trimmingCharacters(in: .whitespaces),
            company:        company.trimmingCharacters(in: .whitespaces),
            avatar_url:     avatarUrl,
            cover_url:      coverUrl,
            interests:      selectedInterests.map { $0.displayText },
            skills:         skills,
            email:          email.trimmingCharacters(in: .whitespaces))
        do {
            return try await profileRepository.updateProfile(update)
        } catch {
            errorMessage = Bundle.app.loc("Couldn't save profile, please try again")
            return nil
        }
    }

    private static func image(from item: PhotosPickerItem) async -> UIImage? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return UIImage(data: data)
    }
}
