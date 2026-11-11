import Foundation
import Observation
import UIKit
import PhotosUI
import SwiftUI

/// Admins/moderators: cover photo, name, about, privacy and post approval.
@MainActor
@Observable
final class EditCommunityViewModel {
    var name: String
    var about: String {
        didSet {
            let clamped = CommunityDescription.clamped(about)
            if clamped != about { about = clamped }
        }
    }
    var privacy: CommunityPrivacy
    var requirePostApproval: Bool
    private(set) var pickedCover: UIImage?
    private(set) var isSaving = false
    var errorMessage: String?

    let original: Community
    private let repository = CommunityRepository()
    private let postRepository = PostRepository()

    init(community: Community) {
        original = community
        name = community.name
        about = community.description ?? ""
        privacy = community.privacy
        requirePostApproval = community.requirePostApproval
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Has anything been changed from the community as it is now? Cancel only asks then.
    var hasChanges: Bool {
        trimmedName != original.name || about != (original.description ?? "") || privacy != original.privacy
            || requirePostApproval != original.requirePostApproval || pickedCover != nil
    }

    var nameProblem: String? {
        guard (3...100).contains(trimmedName.count) else { return Bundle.app.loc("Community name must be 3-100 characters") }
        return takenName == trimmedName.lowercased() ? Bundle.app.loc("A community with this name already exists") : nil
    }

    /// The last name (lowercased) found taken, by the live check or a refused save.
    private var takenName: String?

    /// Checks the typed name with the server; the view calls it after a short
    /// pause in typing. The community's own name is always fine.
    func checkName(token: String) async {
        let candidate = trimmedName
        guard (3...100).contains(candidate.count),
              candidate.caseInsensitiveCompare(original.name) != .orderedSame else { return }
        guard let available = try? await repository.isNameAvailable(candidate, except: original.id, token: token),
              candidate == trimmedName else { return }
        if !available { takenName = candidate.lowercased() }
        else if takenName == candidate.lowercased() { takenName = nil }
    }

    /// Shows the existing cover unless a new one was picked.
    var showsExistingCover: Bool { pickedCover == nil && original.coverUrl != nil }

    func loadCover(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        pickedCover = image
    }

    /// The saved community, or nil with `errorMessage` set.
    func save(token: String) async -> Community? {
        guard nameProblem == nil, !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        var coverUrl: String?
        if let data = pickedCover?.jpegData(compressionQuality: 0.9) {
            coverUrl = try? await postRepository.uploadImage(data)
            guard coverUrl != nil else {
                errorMessage = Bundle.app.loc("Couldn't upload photo, please try again")
                return nil
            }
        }
        do {
            return try await repository.updateCommunity(
                communityId: original.id,
                name: trimmedName == original.name ? nil : trimmedName,
                description: about == (original.description ?? "") ? nil : about,
                privacy: privacy == original.privacy ? nil : privacy.rawValue,
                coverUrl: coverUrl,
                requirePostApproval: requirePostApproval == original.requirePostApproval ? nil : requirePostApproval,
                token: token)
        } catch {
            if case APIError.serverError(409, _) = error {
                takenName = trimmedName.lowercased()
            } else {
                errorMessage = friendlyError(error)
            }
            return nil
        }
    }
}
