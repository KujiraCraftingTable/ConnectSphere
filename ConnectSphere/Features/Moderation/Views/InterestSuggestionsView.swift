import SwiftUI

/// Admin tools › Interest suggestions: interests people asked to add to the
/// picker, most-requested first. Tap one to add it to the catalog or reject it.
struct InterestSuggestionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = InterestSuggestionsViewModel()
    @State private var reviewing: InterestSuggestion?

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        List {
            ForEach(viewModel.suggestions) { s in
                Button { reviewing = s } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.text).scaledFont(15, .semibold)
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                            Text(s.lastAt.dayMonthYear)
                                .scaledFont(12).foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                        Spacer()
                        Text(String(format: bundle.loc("%d people"), s.count))
                            .scaledFont(13, .medium).foregroundColor(AppColors.textSecondary(colorScheme))
                        Image(systemName: "chevron.right").scaledFont(12)
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.suggestions.isEmpty {
                ProgressView()
            } else if !viewModel.isLoading && viewModel.suggestions.isEmpty {
                EmptyStateView(systemImage: "sparkles", title: bundle.loc("No suggestions waiting"))
            }
        }
        .navigationTitle(bundle.loc("Interest suggestions"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(token: token) }
        .refreshable { await viewModel.load(token: token) }
        .sheet(item: $reviewing) { s in
            InterestSuggestionReviewSheet(suggestion: s, viewModel: viewModel, token: token)
        }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}

/// One suggestion: its English and Vietnamese names (pre-filled with what was
/// typed) and a category, then Add to catalog or Reject.
private struct InterestSuggestionReviewSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    let suggestion: InterestSuggestion
    let viewModel: InterestSuggestionsViewModel
    let token: String

    @State private var nameEn: String
    @State private var nameVi: String
    @State private var category = ""
    @State private var allowsSpecific = false
    @State private var confirmReject = false

    init(suggestion: InterestSuggestion, viewModel: InterestSuggestionsViewModel, token: String) {
        self.suggestion = suggestion
        self.viewModel = viewModel
        self.token = token
        _nameEn = State(initialValue: suggestion.text)
        _nameVi = State(initialValue: suggestion.text)
    }

    private var isBusy: Bool { viewModel.processing.contains(suggestion.id) }
    private var canAdd: Bool {
        !nameEn.trimmingCharacters(in: .whitespaces).isEmpty
            && !nameVi.trimmingCharacters(in: .whitespaces).isEmpty
            && !category.isEmpty && !isBusy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(String(format: bundle.loc("Suggested by %d people"), suggestion.count))
                } header: {
                    Text(suggestion.text)
                }
                Section(bundle.loc("Name")) {
                    TextField(bundle.loc("English"), text: $nameEn)
                    TextField(bundle.loc("Vietnamese"), text: $nameVi)
                }
                Section {
                    Picker(bundle.loc("Category"), selection: $category) {
                        Text(bundle.loc("Choose…")).tag("")
                        ForEach(viewModel.categories) { c in
                            Text(appState.appLanguage == .vietnamese ? c.nameVi : c.nameEn).tag(c.key)
                        }
                    }
                    Toggle(bundle.loc("Allows a specific item (e.g. Gaming · Roblox)"), isOn: $allowsSpecific)
                }
                Section {
                    Button(bundle.loc("Add to catalog")) {
                        Task {
                            if await viewModel.approve(suggestion, nameEn: nameEn, nameVi: nameVi, category: category,
                                                       allowsSpecific: allowsSpecific, token: token) { dismiss() }
                        }
                    }
                    .disabled(!canAdd)
                    Button(bundle.loc("Reject"), role: .destructive) { confirmReject = true }
                        .disabled(isBusy)
                }
            }
            .navigationTitle(bundle.loc("Review suggestion"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
            }
            .alert(bundle.loc("Reject this suggestion?"), isPresented: $confirmReject) {
                Button(bundle.loc("Reject"), role: .destructive) {
                    Task { if await viewModel.reject(suggestion, token: token) { dismiss() } }
                }
                Button(bundle.loc("Cancel"), role: .cancel) {}
            }
        }
    }
}
