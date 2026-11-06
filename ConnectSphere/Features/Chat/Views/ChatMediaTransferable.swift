import SwiftUI
import PhotosUI

// MARK: - Pending media awaiting send

/// A picked image/video held in a composer before the user taps send.
/// Shared by `ChatView`'s full input bar and the floating chat's docked
/// composer (`FloatingChatComposerBar`), both import from `PhotosPicker`
/// through `MediaFileTransferable` below, so the two stay in step.
struct PendingMedia: Identifiable {
    let id = UUID()
    let url: URL
    let image: Image?   // nil for videos / non-image files (shown as a placeholder)
}

// MARK: - Transferable wrapper for photos picker

/// Copies a `PhotosPicker` selection into the temporary directory and hands
/// back its local URL. The shape `ChatViewModel.sendMedia(fileURL:)` expects.
struct MediaFileTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .item) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.copyItem(at: received.file, to: dest)
            return MediaFileTransferable(url: dest)
        }
    }
}
