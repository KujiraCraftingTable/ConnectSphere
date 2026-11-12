import Foundation
import Observation

/// The CV saved on a Work profile (server migration 131). Yours to add,
/// replace or remove; someone else's only reaches a verified HR.
@MainActor
@Observable
final class ProfileCVViewModel {
    private(set) var cvPath: String?
    private(set) var loaded = false
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    static let limit = 10 * 1024 * 1024
    private let repository = JobsRepository()

    func load(userId: String, isMe: Bool, token: String) async {
        do {
            cvPath = isMe ? try await repository.myCV(token: token)
                          : try await repository.profileCV(userId: userId, token: token)
        } catch {
            // Someone else's: a 404 means none, or you aren't a verified HR.
            cvPath = nil
        }
        loaded = true
    }

    /// Uploads the picked PDF and saves it on your profile.
    func attach(at url: URL, token: String) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = Bundle.app.loc("Couldn't read that file.")
            return
        }
        guard data.count <= Self.limit else {
            errorMessage = Bundle.app.loc("The CV must be 10 MB or smaller.")
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let path = try await repository.uploadCV(data, fileName: url.lastPathComponent, token: token)
            try await repository.saveMyCV(path, token: token)
            cvPath = path
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func remove(token: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await repository.removeMyCV(token: token)
            cvPath = nil
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}
