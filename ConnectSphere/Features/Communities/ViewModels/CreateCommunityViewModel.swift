import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

/// Creating a community: the form's data, validation, an optional photo, and
/// the create call. The emoji/colour pickers and warning copy live in the view.
@MainActor
@Observable
final class CreateCommunityViewModel {
    var name = ""
    var description = "" {
        didSet {
            let clamped = CommunityDescription.clamped(description)
            if clamped != description { description = clamped }
        }
    }
    var type: CommunityType = .fandom
    var privacy: CommunityPrivacy = .public
    var selectedEmoji: String
    static let defaultColor = "#7F5AF0"
    var selectedColor = CreateCommunityViewModel.defaultColor
    private(set) var pickedImage: UIImage?
    private(set) var isCreating = false
    private(set) var errorMessage: String?

    private let communityRepository = CommunityRepository()
    private let postRepository = PostRepository()   // owns the image-upload endpoint

    private let defaultEmoji: String

    init(defaultEmoji: String) {
        self.defaultEmoji = defaultEmoji
        selectedEmoji = defaultEmoji
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canCreate: Bool { trimmedName.count >= 3 }

    /// Anything entered, picked or switched away from its default. Closing
    /// would lose it, so Cancel asks. A form still at its defaults just closes.
    var hasChanges: Bool {
        !trimmedName.isEmpty
            || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || pickedImage != nil
            || type != .fandom
            || privacy != .public
            || selectedEmoji != defaultEmoji
            || selectedColor != Self.defaultColor
    }

    /// Same name and type as a community the user can already see.
    func isDuplicateName(among existing: [Community]) -> Bool {
        let lowered = trimmedName.lowercased()
        guard lowered.count >= 3 else { return false }
        return existing.contains { $0.name.lowercased() == lowered && $0.type == type }
    }

    /// The photo as picked, kept so it can be re-framed; `pickedImage` is the framed result.
    private(set) var coverOriginal: UIImage?

    /// Returns true when a photo was loaded and is ready to be framed.
    func loadPhoto(from item: PhotosPickerItem) async -> Bool {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return false }
        coverOriginal = image
        return true
    }

    /// The framed cover from `CoverCropView`. Exactly what gets uploaded.
    func setFramedCover(_ image: UIImage) { pickedImage = image }

    func removePhoto() { pickedImage = nil; coverOriginal = nil }

    /// The photo is uploaded only now, once Create is confirmed. Returns the
    /// new community, or nil with `errorMessage` set.
    func create(token: String?) async -> Community? {
        guard canCreate else { return nil }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        // Communities have a cover photo, not a profile picture.
        var coverUrl: String?
        if let data = pickedImage?.jpegData(compressionQuality: 1) {
            coverUrl = try? await postRepository.uploadImage(data)
            if coverUrl == nil {
                errorMessage = Bundle.app.loc("Couldn't upload photo, please try again")
                return nil
            }
        }
        let descTrimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await communityRepository.createCommunity(
                name:        trimmedName,
                type:        type.rawValue,
                privacy:     privacy.rawValue,
                iconEmoji:   selectedEmoji,
                coverColor:  selectedColor,
                coverUrl:    coverUrl,
                description: descTrimmed.isEmpty ? nil : descTrimmed,
                token:       token ?? "")
        } catch {
            if case APIError.serverError(_, let message) = error { errorMessage = message }
            else { errorMessage = Bundle.app.loc("Could not create community. Please try again.") }
            return nil
        }
    }
}
