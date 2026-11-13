import Foundation
import Observation

/// People hidden from the Messages people row in the current mode, and unhiding them.
@MainActor
@Observable
final class HiddenContactsViewModel {
    private(set) var contacts: [HiddenContact] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    var actionError: String?

    private let repository = MessageRepository()

    func load(mode: String, token: String) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            contacts = try await repository.fetchHiddenContacts(mode: mode, token: token)
        } catch {
            loadError = friendlyError(error)
        }
    }

    /// No confirmation: the row leaves at once and comes back if the server
    /// refuses. Returns true once it's done, so the view can show its toast.
    func unhide(_ contact: HiddenContact, mode: String, token: String) async -> Bool {
        guard let index = contacts.firstIndex(of: contact) else { return false }
        contacts.remove(at: index)
        do {
            try await repository.setContactHidden(userId: contact.id, hidden: false, mode: mode, token: token)
        } catch {
            contacts.insert(contact, at: min(index, contacts.count))
            actionError = friendlyError(error)
            return false
        }
        NotificationCenter.default.post(name: .hiddenContactsChanged, object: nil,
                                        userInfo: ["userId": contact.id, "mode": mode, "hidden": false])
        return true
    }
}
