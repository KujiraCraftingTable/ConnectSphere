import SwiftUI

// MARK: - Data Model

struct InterestItem: Identifiable, Hashable {
    let id = UUID()
    let category: String
    let rawInput: String      // specific sub-item, empty if only the category was picked

    var displayText: String {
        rawInput.isEmpty ? category : "\(category) · \(rawInput)"
    }

    /// A stored pick ("Gaming · Roblox") back into its parts.
    init(stored: String) {
        let parts = stored.components(separatedBy: " · ")
        self.init(category: parts[0], rawInput: parts.dropFirst().joined(separator: " · "))
    }

    init(category: String, rawInput: String) {
        self.category = category
        self.rawInput = rawInput
    }
}

// MARK: - InterestPickerView

/// Interests come from the curated catalogue (`InterestCatalogViewModel`),
/// sorted by how many people picked them, with the lifestyle section last.
struct InterestPickerView: View {
    @Binding var selectedInterests: [InterestItem]
    // The auth screen background is fixed light, so this defaults to .light; when embedded
    // in a Form (EditProfile), pass the real colorScheme so chips don't look off in dark mode.
    var colorScheme: ColorScheme = .light
    @Environment(ThemeManager.self) var themeManager
    @Environment(AppState.self) var appState
    @Environment(\.appBundle) var bundle

    @State private var catalog = InterestCatalogViewModel()
    @State private var expanded: Set<String> = []
    @State private var showSubItemSheet = false
    @State private var pendingCategory  = ""
    @State private var subItemInput     = ""
    /// The sheet hugs its content instead of a guessed fixed height.
    @State private var subItemSheetHeight: CGFloat = 220
    @State private var showSuggest = false
    @State private var suggestText = ""

    /// Each category shows this many until "More" is tapped.
    private let collapsedCount = 8

    private var vietnamese: Bool { appState.appLanguage == .vietnamese }
    private var isFull: Bool { selectedInterests.count >= catalog.maxPicks }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !selectedInterests.isEmpty {
                selectedChips
            }
            CatalogSearchField(placeholder: bundle.loc("Search interests"), text: $catalog.query,
                               count: selectedInterests.count, limit: catalog.maxPicks, colorScheme: colorScheme)
            if let error = catalog.loadError {
                HStack(spacing: 10) {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                    Button(bundle.loc("Retry")) { Task { await catalog.load() } }
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            ForEach(catalog.visibleCategories) { category in
                categorySection(category)
            }
            if catalog.canSuggest {
                suggestRow
            }
        }
        .task { await catalog.load() }
        .sheet(isPresented: $showSubItemSheet) {
            subItemSheet
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { subItemSheetHeight = $0 }
                .presentationDetents([.height(subItemSheetHeight)])
                .presentationDragIndicator(.visible)
                // A sheet doesn't inherit the host's forced scheme (onboarding is
                // always light), so without this the field's text came out white
                // on the light background under a dark system appearance.
                .preferredColorScheme(colorScheme)
        }
        .alert(bundle.loc("Suggest an interest"), isPresented: $showSuggest) {
            TextField(bundle.loc("e.g. Pickleball"), text: $suggestText)
            Button(bundle.loc("Cancel"), role: .cancel) {}
            Button(bundle.loc("Send")) {
                let text = suggestText
                Task { await catalog.suggest(text) }
            }
        } message: {
            Text("We review suggestions before adding them to the list.", bundle: bundle)
        }
    }

    // MARK: Selected chips row

    private var selectedChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(selectedInterests) { item in
                CatalogSelectedChip(title: label(for: item)) {
                    selectedInterests.removeAll { $0.id == item.id }
                }
            }
        }
    }

    private func label(for item: InterestItem) -> String {
        let name = catalog.displayName(item.category, vietnamese: vietnamese)
        return item.rawInput.isEmpty ? name : "\(name) · \(item.rawInput)"
    }

    // MARK: Category section

    private func categorySection(_ category: InterestCategory) -> some View {
        let showAll = expanded.contains(category.key) || !catalog.query.isEmpty
        let entries = showAll ? category.entries : Array(category.entries.prefix(collapsedCount))
        return CatalogSection(title: vietnamese ? category.nameVi : category.nameEn, colorScheme: colorScheme) {
            ForEach(entries) { entry in
                entryChip(entry)
            }
            if !showAll && category.entries.count > collapsedCount {
                CatalogMoreButton { expanded.insert(category.key) }
            }
        }
    }

    private func entryChip(_ entry: InterestEntry) -> some View {
        let isSelected = selectedInterests.contains {
            $0.category.caseInsensitiveCompare(entry.nameEn) == .orderedSame && $0.rawInput.isEmpty
        }
        return CatalogChip(title: vietnamese ? entry.nameVi : entry.nameEn, isSelected: isSelected,
                           isDimmed: isFull, colorScheme: colorScheme) {
            handleTap(entry)
        }
    }

    private var suggestRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                suggestText = catalog.query
                showSuggest = true
            } label: {
                Label(bundle.loc("Can't find yours? Suggest it"), systemImage: "plus.bubble")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(themeManager.theme.primary)
            }
            .buttonStyle(.plain)
            if let notice = catalog.suggestNotice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
    }

    // MARK: Sub-item sheet

    private var pendingName: String { catalog.displayName(pendingCategory, vietnamese: vietnamese) }

    private var subItemSheet: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text(pendingName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text(String(format: bundle.loc("Specifically which %@? (optional)"), pendingName.lowercased()))
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            .padding(.top, AppSpacing.xl)

            VStack(alignment: .leading, spacing: 6) {
                TextField(String(format: bundle.loc("e.g. %@"), subItemPlaceholder(pendingCategory)), text: $subItemInput)
                    .font(.system(size: 16))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(AppColors.surface(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
                    .submitLabel(.done)
                    .onSubmit { confirmSubItem() }
                if let error = catalog.specificError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 12) {
                // Skip — add only category
                Button(bundle.loc("Skip")) {
                    addInterest(category: pendingCategory, rawInput: "")
                    showSubItemSheet = false
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(AppColors.surface(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Add with sub-item, once the server has found it
                Button {
                    confirmSubItem()
                } label: {
                    Group {
                        if catalog.isChecking { ProgressView().tint(.white) } else { Text("Add", bundle: bundle) }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(themeManager.theme.primary, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(catalog.isChecking)
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, AppSpacing.lg)
        .frame(maxWidth: .infinity)
        .background(AppColors.base(colorScheme).ignoresSafeArea())
    }

    // MARK: Helpers

    private func handleTap(_ entry: InterestEntry) {
        // Toggle: if this entry is already selected (no sub-item), remove it
        if let idx = selectedInterests.firstIndex(where: {
            $0.category.caseInsensitiveCompare(entry.nameEn) == .orderedSame && $0.rawInput.isEmpty
        }) {
            selectedInterests.remove(at: idx)
            return
        }
        guard !isFull else { return }

        if entry.allowsSpecific {
            pendingCategory = entry.nameEn
            subItemInput    = ""
            catalog.specificError = nil
            showSubItemSheet = true
        } else {
            addInterest(category: entry.nameEn, rawInput: "")
        }
    }

    private func confirmSubItem() {
        let base = pendingCategory, text = subItemInput
        Task {
            guard let pick = await catalog.checkSpecific(base: base, text: text) else { return }
            let item = InterestItem(stored: pick)
            addInterest(category: item.category, rawInput: item.rawInput)
            showSubItemSheet = false
        }
    }

    private func addInterest(category: String, rawInput: String) {
        let item = InterestItem(category: category, rawInput: rawInput)
        // Avoid duplicate display texts
        guard !isFull, !selectedInterests.contains(where: { $0.displayText == item.displayText }) else { return }
        selectedInterests.append(item)
    }

    private func subItemPlaceholder(_ category: String) -> String {
        switch category {
        case "Anime":  return "Kimetsu no Yaiba, Naruto..."
        case "Movies": return "Inception, Interstellar..."
        case "Gaming": return "Minecraft, FIFA..."
        case "Music":  return "BTS, Taylor Swift..."
        case "Books":  return "Harry Potter, Dune..."
        default:       return ""
        }
    }
}

// FlowLayout is defined in Core/UI/FlowLayout.swift
