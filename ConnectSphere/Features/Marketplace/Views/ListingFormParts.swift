import SwiftUI
import PhotosUI

// MARK: - Items section
/// What's for sale in the sell and edit forms: the headline (asked for once
/// there are several items), the description, then a section per item
/// (photos, title, price, condition) and "Add another item". The description
/// comes before the items: it's the seller's own voice, and with many items it
/// would otherwise sit far down the form.
struct ListingItemsSection: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let items: ListingItemsViewModel
    @Binding var headline: String
    @Binding var description: String

    var body: some View {
        if items.hasSeveral {
            Section {
                TextField(bundle.loc("e.g. Shelf clear-out, 7 sets"), text: $headline)
            } header: {
                Text(bundle.loc("Listing title") + " *")
            } footer: {
                Text("Shown on the Marketplace card. Your description stays exactly as you write it.", bundle: bundle)
            }
        }
        Section {
            MarkdownTextEditor(text: $description, placeholder: bundle.loc("Describe what you're selling…"),
                               minHeight: 80, maxHeight: 200)
        } header: {
            Text("Description", bundle: bundle)
        }
        ForEach(Array(items.drafts.enumerated()), id: \.element.id) { index, draft in
            ListingItemSection(draft: draft, number: index + 1, showsNumber: items.hasSeveral,
                               onRemove: items.hasSeveral ? { withAnimation { items.remove(draft.id) } } : nil)
        }
        Section {
            Button {
                withAnimation { items.add() }
            } label: {
                Label(bundle.loc("Add another item"), systemImage: "plus.circle.fill")
                    .foregroundColor(items.canAdd ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
            }
            .disabled(!items.canAdd)
        } footer: {
            Text(String(format: bundle.loc("Selling several things? Add each with its own photos and price, up to %lld."),
                        ListingItemsViewModel.maxItems))
        }
    }
}

// MARK: - Item section
/// One item of the form.
private struct ListingItemSection: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var draft: ListingItemDraft
    let number: Int
    let showsNumber: Bool
    let onRemove: (() -> Void)?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                ListingPhotosStrip(photos: draft.photos)
                // Always shown, right under the photos, so the seller picks the
                // cover on purpose (it leads the Marketplace card and the post).
                Label(bundle.loc("The first photo is the cover: it's shown first on the Marketplace card and in posts."),
                      systemImage: "star.square.on.square")
                    .labelStyle(.titleAndIcon)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(bundle.loc("What are you selling?") + " *", text: $draft.title)
            ListingPriceField(placeholder: bundle.loc("Price (0 = free)"), text: $draft.price)
            Picker(bundle.loc("Condition"), selection: $draft.condition) {
                ForEach(ListingCondition.allCases, id: \.self) { Text(bundle.loc($0.label)).tag($0) }
            }
            // Typed for big stacks (30 of a card), − and + for small changes.
            HStack {
                Text(bundle.loc("Quantity") + " *")
                Spacer()
                QuantityStepper(value: $draft.quantity,
                                range: draft.minQuantity...max(draft.minQuantity, draft.maxQuantity),
                                isInvalid: !draft.quantityIsValid)
            }
        } header: {
            HStack {
                if showsNumber {
                    Text(String(format: bundle.loc("Item %lld"), number))
                } else {
                    Text("Listing details", bundle: bundle)
                }
                Spacer()
                if let onRemove {
                    Button(role: .destructive, action: onRemove) {
                        Label(bundle.loc("Remove"), systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .foregroundColor(AppColors.danger(colorScheme))
                    .accessibilityLabel(Text(String(format: bundle.loc("Remove item %lld"), number)))
                }
            }
        } footer: {
            if !draft.quantityIsValid {
                Text(draft.quantity > draft.maxQuantity && draft.listedQuantity != nil
                     ? bundle.loc("You can't raise the quantity. Post a new listing to sell more.")
                     : draft.soldCount > 1
                     ? String(format: bundle.loc("%lld are sold or on deposit, so the quantity can't be less."), draft.soldCount)
                     : String(format: bundle.loc("Quantity must be 1–%lld."), ListingItemDraft.maxQuantity))
                    .foregroundColor(AppColors.danger(colorScheme))
            } else if draft.photos.isOverLimit {
                Text(String(format: bundle.loc("Up to %lld photos per item."), ListingPhotosViewModel.maxMedia))
                    .foregroundColor(AppColors.danger(colorScheme))
            } else if draft.photos.hasPhotos {
                Text(String(format: bundle.loc("Up to %lld photos per item."), ListingPhotosViewModel.maxMedia))
            } else {
                Text("Add at least one photo.", bundle: bundle)
                    .foregroundColor(AppColors.danger(colorScheme))
            }
        }
    }
}

// MARK: - Photo strip
/// One item's photo strip: add, remove, alt text.
struct ListingPhotosStrip: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var photos: ListingPhotosViewModel
    @State private var altTarget: PickedPostMedia?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PhotosPicker(selection: $photos.pickerItems, maxSelectionCount: ListingPhotosViewModel.maxMedia,
                             matching: .any(of: [.images, .videos])) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 24))
                        Text(bundle.loc("Add photos / videos") + " *")
                            .font(.system(size: 11, weight: .medium))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(themeManager.theme.primary)
                    .frame(width: 96, height: 96)
                    .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.borderless)
                ForEach(photos.media) { item in tile(item) }
                ForEach(0..<photos.pendingCount, id: \.self) { _ in
                    MediaLoadingTile(width: 96, height: 96)
                }
            }
            .padding(.vertical, 4)
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

// MARK: - Price field
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

// MARK: - Auto re-up
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

// MARK: - Also list in
/// A community in the "Also list in" checklist.
struct ListingCommunityOption: Identifiable {
    let id: String
    let name: String
    /// "Waits for admin approval" and the like, under the name.
    let note: String?
}

/// The "Also list in" rows, A to Z (ticked ones first), with a search once there
/// are more than 5. Inside Edit listing it shares the form with other fields, so
/// it shows 5 and "See more"; the Sell form's own step shows every community. The ticked ones stay
/// on top whatever's typed, so they can always be unticked. At the limit the
/// others can't be ticked until one is unticked.
struct ListingCommunityList: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let options: [ListingCommunityOption]
    let isSelected: (String) -> Bool
    let isFull: Bool
    let toggle: (String) -> Void
    var collapses = true

    @State private var query = ""
    @State private var showsAll = false

    private static let shownRows = 5

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var matching: [ListingCommunityOption] {
        let sorted = options.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let ticked = sorted.filter { isSelected($0.id) }
        let others = sorted.filter { !isSelected($0.id) }
            .filter { trimmedQuery.isEmpty || $0.name.localizedStandardContains(trimmedQuery) }
        return ticked + others
    }

    /// While searching every match shows; otherwise 5 until "See more".
    private var isCollapsed: Bool { collapses && !showsAll && trimmedQuery.isEmpty && matching.count > Self.shownRows }

    private var visible: [ListingCommunityOption] {
        isCollapsed ? Array(matching.prefix(Self.shownRows)) : matching
    }

    var body: some View {
        if options.count > 5 {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(AppColors.textTertiary(colorScheme))
                TextField(bundle.loc("Search your communities"), text: $query)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(AppColors.textTertiary(colorScheme))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear", bundle: bundle))
                }
            }
        }
        ForEach(visible) { option in
            let on = isSelected(option.id)
            ListingCommunityRow(name: option.name, note: option.note, isOn: on) { toggle(option.id) }
                .disabled(!on && isFull)
        }
        if isCollapsed {
            Button(String(format: bundle.loc("See more (%lld)"), matching.count - Self.shownRows)) { showsAll = true }
        } else if showsAll && trimmedQuery.isEmpty && matching.count > Self.shownRows {
            Button(bundle.loc("Show less")) { showsAll = false }
        }
        if !trimmedQuery.isEmpty && !options.contains(where: { !isSelected($0.id) && $0.name.localizedStandardContains(trimmedQuery) }) {
            Text("No communities match.", bundle: bundle)
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }
}

/// One community in "Also list in": tick it to list there, untick to leave.
struct ListingCommunityRow: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let name: String
    /// "Waits for admin approval" and the like, under the name.
    let note: String?
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundColor(AppColors.textPrimary(colorScheme))
                    if let note {
                        Text(note).scaledFont(12).foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isOn ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
            }
            // Greyed out at 5/5, so it reads as "untick one first".
            .opacity(isEnabled ? 1 : 0.4)
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
