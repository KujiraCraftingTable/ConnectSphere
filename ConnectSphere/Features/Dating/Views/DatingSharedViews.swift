import PhotosUI
import SwiftUI

/// The dating photos row: add (up to 6), remove, press and hold to show first.
/// Shared by the setup and the editor.
struct DatingPhotoStrip: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var form: DatingProfileEditorViewModel
    var tileSize = CGSize(width: 96, height: 128)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if form.photos.count < DatingProfileEditorViewModel.maxPhotos {
                    PhotosPicker(selection: $form.pickerItems,
                                 maxSelectionCount: form.remainingPhotoSlots, matching: .images) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 24))
                            Text("Add photos", bundle: bundle).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(themeManager.theme.primary)
                        .frame(width: tileSize.width, height: tileSize.height)
                        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(themeManager.theme.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    }
                }
                ForEach(form.photos) { item in tile(item) }
                ForEach(0..<form.pendingPhotoCount, id: \.self) { _ in
                    MediaLoadingTile(width: tileSize.width, height: tileSize.height)
                }
            }
            .padding(.vertical, 4)
        }
        .onChange(of: form.pickerItems) { _, _ in
            Task<Void, Never>(name: nil) { await form.loadPicked() }
        }
    }

    private func tile(_ item: PickedPostMedia) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let preview = item.previewImage {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else {
                    AsyncImage(url: APIConfig.mediaURL(item.remoteURL)) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { AppColors.elevated(colorScheme) }
                    }
                }
            }
            .frame(width: tileSize.width, height: tileSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Button { form.removePhoto(item) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel(Text("Remove photo", bundle: bundle))
        }
        .contextMenu {
            Button { form.makeCover(item) } label: {
                Label(bundle.loc("Show first"), systemImage: "star")
            }
        }
    }
}

/// Dating can't be used without the phone's location: it's what stops people
/// pretending to be somewhere else to look at, or follow, people there.
struct DatingLocationRequiredView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    var isWorking = false
    let onTryAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Label {
                Text("Location is required for Dating", bundle: bundle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            } icon: {
                Image(systemName: "location.slash.fill").foregroundColor(AppColors.danger(colorScheme))
            }
            Text("For everyone's safety, Dating only works with your phone's real location — so nobody can pretend to be nearby to watch or follow people. Others only see your district and city, never where exactly you are.",
                 bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppSpacing.md) {
                Button(bundle.loc("Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                Button(action: onTryAgain) {
                    if isWorking { ProgressView() } else { Text("Try again", bundle: bundle) }
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
            .tint(themeManager.theme.primary)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.danger(colorScheme).opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}
