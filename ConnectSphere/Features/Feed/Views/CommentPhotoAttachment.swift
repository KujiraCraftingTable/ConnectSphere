import PhotosUI
import SwiftUI

/// The camera button beside a comment composer's Send: opens the photo
/// library, photos only, no videos and no camera, for one photo per comment.
struct CommentPhotoButton: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle

    let viewModel: CommentViewModel
    @State private var pickedItem: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
            Image(systemName: "camera")
                .scaledFont(19)
                .foregroundColor(themeManager.theme.primary)
        }
        .disabled(viewModel.isSending)
        .accessibilityLabel(Text(bundle.loc("Add a photo")))
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task {
                await viewModel.attachPhoto(item)
                pickedItem = nil
            }
        }
    }
}

/// The picked photo above the composer, with ✕ to drop it before sending.
struct CommentPhotoPreview: View {
    @Environment(\.appBundle) private var bundle

    let viewModel: CommentViewModel

    var body: some View {
        if let photo = viewModel.attachedPhoto {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button { viewModel.removePhoto() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(18)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .accessibilityLabel(Bundle.app.loc("Remove photo"))
                    .offset(x: 6, y: -6)
                    .disabled(viewModel.isSending)
                    .accessibilityLabel(Text(bundle.loc("Remove photo")))
                }
                .overlay {
                    if viewModel.isSending {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A comment's photo inside its bubble: up to 200 pt wide, its own shape;
/// tap to open it full screen in the app's media viewer.
struct CommentPhoto: View {
    @Environment(\.colorScheme) private var colorScheme

    let path: String
    @State private var showsViewer = false

    private static let maxWidth: CGFloat = 200
    private static let maxHeight: CGFloat = 260

    var body: some View {
        if let url = APIConfig.mediaURL(path) {
            RemoteImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                        .frame(maxWidth: Self.maxWidth, maxHeight: Self.maxHeight, alignment: .leading)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppColors.textTertiary(colorScheme).opacity(0.15))
                        .frame(width: Self.maxWidth, height: 140)
                        .overlay {
                            if phase.error == nil { ProgressView() } else { Image(systemName: "photo") }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { showsViewer = true }
            .fullScreenCover(isPresented: $showsViewer) {
                ChatMediaViewerView(items: [ChatMediaViewerItem(id: path, url: url, isVideo: false)])
            }
            .accessibilityAddTraits(.isImage)
        }
    }
}
