import SwiftUI

// MARK: - Data Model

struct InterestItem: Identifiable, Hashable {
    let id = UUID()
    let category: String
    let rawInput: String      // specific sub-item, empty if only the category was picked

    var displayText: String {
        rawInput.isEmpty ? category : "\(category) · \(rawInput)"
    }
}

// MARK: - Constants

private let popularCategories: [String] = [
    "Coffee", "Travel", "Fitness", "Photography",
    "Cooking", "Art", "Sports", "Reading",
    "Music", "Anime", "Movies", "Gaming", "Books",
]

// Categories that allow entering a specific sub-item
private let categoriesWithSubItem = Set(["Anime", "Movies", "Gaming", "Music", "Books"])

// Icon for each category
private let categoryIcons: [String: String] = [
    "Coffee":      "cup.and.saucer.fill",
    "Travel":      "airplane",
    "Fitness":     "figure.run",
    "Photography": "camera.fill",
    "Cooking":     "fork.knife",
    "Art":         "paintpalette.fill",
    "Sports":      "sportscourt.fill",
    "Reading":     "book.fill",
    "Music":       "music.note",
    "Anime":       "tv.fill",
    "Movies":      "film.fill",
    "Gaming":      "gamecontroller.fill",
    "Books":       "books.vertical.fill",
]

// MARK: - InterestPickerView

struct InterestPickerView: View {
    @Binding var selectedInterests: [InterestItem]
    // The auth screen background is fixed light, so this defaults to .light; when embedded
    // in a Form (EditProfile), pass the real colorScheme so chips don't look off in dark mode.
    var colorScheme: ColorScheme = .light
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle

    @State private var showSubItemSheet = false
    @State private var pendingCategory  = ""
    @State private var subItemInput     = ""
    /// The sheet hugs its content instead of a guessed fixed height.
    @State private var subItemSheetHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // ── Selected chips ──────────────────────────────────────────────
            if !selectedInterests.isEmpty {
                selectedChips
            }

            // ── Popular chips ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("Popular", bundle: bundle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .textCase(.uppercase)
                    .kerning(0.6)
                FlowLayout(spacing: 8) {
                    ForEach(popularCategories, id: \.self) { cat in
                        categoryChip(cat)
                    }
                }
            }
        }
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
    }

    // MARK: Selected chips row

    private var selectedChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(selectedInterests) { item in
                HStack(spacing: 5) {
                    Text(item.displayText)
                        .font(.system(size: 13, weight: .medium))
                    Button {
                        selectedInterests.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(themeManager.theme.primary))
            }
        }
    }

    // MARK: Category chip

    private func categoryChip(_ category: String) -> some View {
        let isSelected = selectedInterests.contains { $0.category == category && $0.rawInput.isEmpty }

        return Button {
            handleTap(category)
        } label: {
            HStack(spacing: 5) {
                if let icon = categoryIcons[category] {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(category)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : AppColors.textPrimary(colorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected
                    ? AnyShapeStyle(themeManager.theme.primary)
                    : AnyShapeStyle(colorScheme == .dark
                        ? Color.white.opacity(0.1)
                        : Color.black.opacity(0.06)))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Sub-item sheet

    private var subItemSheet: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text(pendingCategory)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text(String(format: bundle.loc("Specifically which %@? (optional)"), pendingCategory.lowercased()))
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            .padding(.top, AppSpacing.xl)

            TextField(String(format: bundle.loc("e.g. %@"), subItemPlaceholder(pendingCategory)), text: $subItemInput)
                .font(.system(size: 16))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(AppColors.surface(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
                .padding(.horizontal, 20)
                .submitLabel(.done)
                .onSubmit { confirmSubItem() }

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

                // Add with sub-item
                Button(bundle.loc("Add")) {
                    confirmSubItem()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(themeManager.theme.primary, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, AppSpacing.lg)
        .frame(maxWidth: .infinity)
        .background(AppColors.base(colorScheme).ignoresSafeArea())
    }

    // MARK: Helpers

    private func handleTap(_ category: String) {
        // Toggle: if this category is already selected (no sub-item), remove it
        if let idx = selectedInterests.firstIndex(where: { $0.category == category && $0.rawInput.isEmpty }) {
            selectedInterests.remove(at: idx)
            return
        }

        if categoriesWithSubItem.contains(category) {
            pendingCategory = category
            subItemInput    = ""
            showSubItemSheet = true
        } else {
            addInterest(category: category, rawInput: "")
        }
    }

    private func confirmSubItem() {
        addInterest(category: pendingCategory, rawInput: subItemInput.trimmingCharacters(in: .whitespaces))
        showSubItemSheet = false
    }

    private func addInterest(category: String, rawInput: String) {
        // Avoid duplicate display texts
        guard !selectedInterests.contains(where: { $0.displayText == InterestItem(category: category, rawInput: rawInput).displayText }) else { return }
        selectedInterests.append(InterestItem(category: category, rawInput: rawInput))
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
