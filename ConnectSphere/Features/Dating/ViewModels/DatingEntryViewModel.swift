import Foundation
import Observation

/// Whether the account menu shows Dating at all. Only accounts aged 16 or
/// older see it; the server decides from the real age (the profile's own age
/// can be hidden when the birthday is private), and keeps refusing under-16s
/// on every Dating request regardless.
@MainActor
@Observable
final class DatingEntryViewModel {
    private(set) var isAvailable = false
    private let repository = DatingRepository()

    func load(token: String) async {
        isAvailable = (try? await repository.status(token: token))?.isLocked == false
    }
}
