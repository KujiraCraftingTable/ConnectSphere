import Foundation
import Observation
import Photos

/// Saves photos/videos someone shared (chat, posts) into the Photos library.
/// Uses add-only access, so the app can never read the user's library.
@MainActor
@Observable
final class MediaSaveViewModel {
    // MARK: - Types
    struct Item: Equatable {
        let url: URL
        let isVideo: Bool
    }

    enum Status: Equatable { case idle, saving, saved(count: Int), denied, failed }
    private(set) var status: Status = .idle

    private let repository = MediaDownloadRepository()
    private var resetTask: Task<Void, Never>?

    var isSaving: Bool { status == .saving }

    /// The line shown in the status capsule, or nil when there's nothing to show.
    var message: String? {
        switch status {
        case .idle: return nil
        case .saving: return Bundle.app.loc("Saving…")
        case .saved(let count):
            return count == 1 ? Bundle.app.loc("Saved to Photos")
                              : String(format: Bundle.app.loc("Saved %lld items to Photos"), count)
        case .denied: return Bundle.app.loc("Allow ConnectSphere to add photos in Settings to save")
        case .failed: return Bundle.app.loc("Couldn't save, please try again")
        }
    }

    // MARK: - Saving
    func save(_ items: [Item]) async {
        guard !items.isEmpty, !isSaving else { return }
        resetTask?.cancel()
        status = .saving
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else {
            finish(.denied)
            return
        }
        var files: [URL] = []
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        do {
            for item in items { files.append(try await repository.download(item.url)) }
            let resources = Array(zip(files, items.map(\.isVideo)))
            try await PHPhotoLibrary.shared().performChanges {
                for (file, isVideo) in resources {
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
                }
            }
            finish(.saved(count: items.count))
        } catch {
            #if DEBUG
            print("[MediaSave] failed: \(error)")
            #endif
            finish(.failed)
        }
    }

    /// Shows the result briefly, then clears it.
    private func finish(_ result: Status) {
        status = result
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.status = .idle
        }
    }
}
