import SwiftUI
import PhotosUI

/// The photo strip of the sell and edit forms: add, remove, alt text.
struct ListingPhotosSection: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var photos: ListingPhotosViewModel
    @State private var altTarget: PickedPostMedia?

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PhotosPicker(selection: $photos.pickerItems, maxSelectionCount: ListingPhotosViewModel.maxMedia,
                                 matching: .any(of: [.images, .videos])) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 24))
                            Text("Add photos / videos", bundle: bundle)
                                .font(.system(size: 11, weight: .medium))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundColor(themeManager.theme.primary)
                        .frame(width: 96, height: 96)
                        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(photos.media) { item in tile(item) }
                    ForEach(0..<photos.pendingCount, id: \.self) { _ in
                        MediaLoadingTile(width: 96, height: 96)
                    }
                }
                .padding(.vertical, 4)
            }
        } footer: {
            if photos.hasPhotos {
                Text("Up to 10. The first one is the cover.", bundle: bundle)
            } else {
                Text("Add at least one photo.", bundle: bundle)
                    .foregroundColor(AppColors.danger(colorScheme))
            }
        }
        .onChange(of: photos.pickerItems) { _, _ in
            Task<Void, Never>(name: nil) { await photos.loadPicked() }
        }
        .sheet(item: $altTarget) { item in
            AltTextEditorSheet(preview: item.previewImage, isVideo: item.isVideo, initialText: item.altText) { text in
                photos.setAltText(text, for: item.id)
            }
        }
    }

    private func tile(_ item: PickedPostMedia) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if let preview = item.previewImage {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else if let remote = item.remoteURL, !item.isVideo {
                    AsyncImage(url: APIConfig.mediaURL(remote)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(AppColors.elevated(colorScheme))
                    }
                } else {
                    Rectangle().fill(Color.black.opacity(0.85))
                }
                if item.isVideo {
                    Image(systemName: "play.circle.fill").font(.system(size: 24)).foregroundColor(.white.opacity(0.92))
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottomLeading) {
                AltTextChip(hasText: !item.altText.isEmpty) { altTarget = item }
            }
            Button { photos.remove(item) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .padding(4)
        }
    }
}

/// The price box: digits grouped as you type, with "đ" always at its right edge.
struct ListingPriceField: View {
    @Environment(\.colorScheme) private var colorScheme
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .keyboardType(.numberPad)
                // Regrouped after each keystroke ("1000" → "1.000"); a TextField
                // ignores a value rewritten inside its own binding's setter.
                .onChange(of: text) { _, new in
                    let grouped = ListingPrice.formatted(new)
                    if grouped != new { text = grouped }
                }
            Text(verbatim: "đ")
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .accessibilityHidden(true)
        }
    }
}

/// "Auto re-up": post the item again as new every 1, 3 or 7 days at a set hour
/// (Vietnam time), for the sell form and Edit listing.
struct AutoReupSection: View {
    @Environment(\.appBundle) private var bundle
    @Binding var isOn: Bool
    @Binding var days: Int
    @Binding var hour: Int

    var body: some View {
        Section {
            Toggle(bundle.loc("Auto re-up"), isOn: $isOn)
            if isOn {
                Picker(bundle.loc("Every"), selection: $days) {
                    ForEach(ListingData.autoReupDays, id: \.self) { Text(ListingData.dayLabel($0, bundle: bundle)).tag($0) }
                }
                Picker(bundle.loc("At"), selection: $hour) {
                    ForEach(ListingData.autoReupHours, id: \.self) { Text(ListingData.hourLabel($0)).tag($0) }
                }
            }
        } footer: {
            Text("Posts it again as new on this schedule, in Vietnam time. You can cancel any time.", bundle: bundle)
        }
    }
}
