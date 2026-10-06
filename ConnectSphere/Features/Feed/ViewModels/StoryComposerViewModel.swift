import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

/// Data side of the story composer: loading picked photos and publishing the
/// flattened canvas. The canvas itself (frames, layout, text layers) is view
/// state, and only the view can render it to an image.
@MainActor
@Observable
final class StoryComposerViewModel {
    /// A collage holds up to this many photos.
    static let maxPhotos = 4

    private(set) var isPosting = false

    private let storyRepository = StoryRepository()
    private let postRepository = PostRepository()   // owns the image-upload endpoint

    /// The images of the first `maxPhotos` picks that could be loaded, in order.
    func loadImages(from items: [PhotosPickerItem]) async -> [UIImage] {
        var images: [UIImage] = []
        for item in items.prefix(Self.maxPhotos) {
            if let image = await loadImage(from: item) { images.append(image) }
        }
        return images
    }

    func loadImage(from item: PhotosPickerItem) async -> UIImage? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return UIImage(data: data)
    }

    /// Uploads the flattened story and creates it. Returns true on success.
    func publish(jpeg: Data, mode: String) async -> Bool {
        guard !isPosting else { return false }
        isPosting = true
        defer { isPosting = false }
        guard let imageUrl = try? await postRepository.uploadImage(jpeg),
              (try? await storyRepository.createStory(imageUrl: imageUrl, mode: mode)) != nil
        else { return false }
        return true
    }
}
