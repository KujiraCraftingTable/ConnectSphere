import SwiftUI

/// Work skills from the curated catalogue (`SkillCatalogViewModel`): search,
/// "Suggested for you" from the job title (as LinkedIn does), categories with
/// the most-held skills first, and "suggest it" for a missing one.
struct SkillPickerView: View {
    @Binding var skills: [String]
    var limit = SkillList.profileLimit
    /// Drives "Suggested for you"; empty shows none.
    var jobTitle = ""
    /// Onboarding's fixed-light screens pass `.light`, like InterestPickerView.
    var colorScheme: ColorScheme
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle

    @State private var catalog = SkillCatalogViewModel()
    @State private var expanded: Set<String> = []
    @State private var showSuggest = false
    @State private var suggestText = ""

    /// Each category shows this many until "More" is tapped.
    private let collapsedCount = 8

    private var vietnamese: Bool { appState.appLanguage == .vietnamese }
    private var isFull: Bool { skills.count >= limit }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !skills.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(skills, id: \.self) { skill in
                        CatalogSelectedChip(title: catalog.displayName(skill, vietnamese: vietnamese)) {
                            skills.removeAll { $0 == skill }
                        }
                    }
                }
            }
            CatalogSearchField(placeholder: bundle.loc("Search skills"), text: $catalog.query,
                               count: skills.count, limit: limit, colorScheme: colorScheme)
            if let error = catalog.loadError {
                HStack(spacing: 10) {
                    Text(error)
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                    Button(bundle.loc("Retry")) { Task { await catalog.load(jobTitle: jobTitle) } }
                        .scaledFont(13, .semibold)
                        .buttonStyle(.borderless)
                }
            }
            let suggestions = catalog.suggested.filter { !isPicked($0) }
            if catalog.query.isEmpty && !suggestions.isEmpty {
                CatalogSection(title: bundle.loc("Suggested for you"), colorScheme: colorScheme) {
                    ForEach(suggestions, id: \.self) { name in
                        CatalogChip(title: catalog.displayName(name, vietnamese: vietnamese), isSelected: false,
                                    isDimmed: isFull, colorScheme: colorScheme) { toggle(name) }
                    }
                }
            }
            ForEach(catalog.visibleCategories) { category in
                categorySection(category)
            }
            if catalog.canSuggest {
                suggestRow
            }
        }
        // A short pause so typing a job title doesn't refetch on every key.
        .task(id: jobTitle) {
            if !catalog.categories.isEmpty { try? await Task.sleep(for: .milliseconds(600)) }
            guard !Task.isCancelled else { return }
            await catalog.load(jobTitle: jobTitle)
        }
        .alert(bundle.loc("Suggest a skill"), isPresented: $showSuggest) {
            TextField(bundle.loc("e.g. Webflow"), text: $suggestText)
            Button(bundle.loc("Cancel"), role: .cancel) {}
            Button(bundle.loc("Send")) {
                let text = suggestText
                Task { await catalog.suggest(text) }
            }
        } message: {
            Text("We review suggestions before adding them to the list.", bundle: bundle)
        }
    }

    private func categorySection(_ category: SkillCategory) -> some View {
        let showAll = expanded.contains(category.key) || !catalog.query.isEmpty
        let entries = showAll ? category.entries : Array(category.entries.prefix(collapsedCount))
        return CatalogSection(title: vietnamese ? category.nameVi : category.nameEn, colorScheme: colorScheme) {
            ForEach(entries) { entry in
                CatalogChip(title: vietnamese ? entry.nameVi : entry.nameEn, isSelected: isPicked(entry.nameEn),
                            isDimmed: isFull, colorScheme: colorScheme) { toggle(entry.nameEn) }
            }
            if !showAll && category.entries.count > collapsedCount {
                CatalogMoreButton { expanded.insert(category.key) }
            }
        }
    }

    private var suggestRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                suggestText = catalog.query
                showSuggest = true
            } label: {
                Label(bundle.loc("Can't find yours? Suggest it"), systemImage: "plus.bubble")
                    .scaledFont(13, .medium)
            }
            .buttonStyle(.borderless)
            if let notice = catalog.suggestNotice {
                Text(notice)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
    }

    private func isPicked(_ name: String) -> Bool {
        skills.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func toggle(_ name: String) {
        if isPicked(name) {
            skills.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        } else if !isFull {
            skills.append(name)
        }
    }
}
