import SwiftUI

/// Settings → Muted words. One list per mode (Hobby / Work), each word muted
/// for a chosen time; the list can be copied to the other mode.
struct MutedWordsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel = MutedWordsViewModel()
    @State private var mode: AppMode = .hobby
    @State private var draft = ""
    @State private var duration: MuteDuration = .forever
    @State private var showCopyConfirm = false
    @FocusState private var fieldFocused: Bool

    private var otherMode: AppMode { mode == .hobby ? .work : .hobby }
    private var words: [MutedWord] { viewModel.words(for: mode) }
    private var canAdd: Bool { MutedWordsViewModel.cleaned(draft) != nil && !viewModel.isAdding }

    var body: some View {
        List {
            Section {
                Picker("", selection: $mode) {
                    Label(bundle.loc("Hobby"), systemImage: AppMode.hobby.glyph).tag(AppMode.hobby)
                    Label(bundle.loc("Work"), systemImage: AppMode.work.glyph).tag(AppMode.work)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                addRow
            } footer: {
                Text("Posts, community posts and comments with these words are hidden. Accents and capitals don't matter, and only whole words count.", bundle: bundle)
            }

            Section {
                if words.isEmpty {
                    Text(mode == .hobby ? "No muted words in Hobby mode." : "No muted words in Work mode.", bundle: bundle)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                } else {
                    ForEach(words) { word in
                        wordRow(word)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await viewModel.delete(word, mode: mode) }
                                } label: {
                                    Label(bundle.loc("Unmute word"), systemImage: "speaker.wave.2.fill")
                                }
                            }
                    }
                }
            } header: {
                if !words.isEmpty {
                    Text(String(format: bundle.loc("%lld muted"), words.count))
                }
            }

            if !words.isEmpty {
                Section {
                    Button { showCopyConfirm = true } label: {
                        HStack {
                            Label(bundle.loc(otherMode == .work ? "Copy to Work mode" : "Copy to Hobby mode"),
                                  systemImage: "doc.on.doc")
                                .labelStyle(.titleAndIcon)
                            Spacer()
                            if viewModel.isCopying { ProgressView() }
                        }
                        .foregroundColor(themeManager.theme.primary)
                    }
                    .disabled(viewModel.isCopying)
                } footer: {
                    if let notice = viewModel.notice { Text(notice) }
                }
            }
        }
        .listStyle(.insetGrouped)
        // The grouped list's default top inset and section gaps left a wide
        // band above the picker; it sits right under the title instead.
        .contentMargins(.top, 8, for: .scrollContent)
        .listSectionSpacing(16)
        .scrollContentBackground(.hidden)
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Muted words"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            mode = appState.currentMode
            await viewModel.load(mode)
        }
        .onChange(of: mode) { _, new in
            viewModel.notice = nil
            if !viewModel.loadedModes.contains(new) { Task { await viewModel.load(new) } }
        }
        .refreshable { await viewModel.load(mode) }
        .confirmationDialog(bundle.loc(otherMode == .work ? "Copy to Work mode?" : "Copy to Hobby mode?"),
                            isPresented: $showCopyConfirm, titleVisibility: .visible) {
            Button(bundle.loc("Copy")) { Task { await viewModel.copy(from: mode) } }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("Words already muted there are kept as they are.", bundle: bundle)
        }
        .alert(bundle.loc("Error"), isPresented: Binding(
            get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        } message: {
            Text(viewModel.error ?? "")
        }
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            TextField(bundle.loc("Word or phrase"), text: $draft)
                .focused($fieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(add)
                .onChange(of: draft) { _, new in
                    if new.count > MutedWordsViewModel.maxLength { draft = String(new.prefix(MutedWordsViewModel.maxLength)) }
                }
            Menu {
                Picker("", selection: $duration) {
                    ForEach(MuteDuration.allCases) { Text(bundle.loc($0.label)).tag($0) }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(bundle.loc(duration.label))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .fixedSize()
            }
            Button(action: add) {
                if viewModel.isAdding {
                    ProgressView()
                } else {
                    Text("Mute word", bundle: bundle).font(.system(size: 14, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(themeManager.theme.primary)
            .disabled(!canAdd)
        }
    }

    private func wordRow(_ word: MutedWord) -> some View {
        HStack {
            Text(word.word)
                .font(.system(size: 16))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer()
            Text(remainingText(word.remaining()))
                .font(.system(size: 13))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
    }

    private func remainingText(_ remaining: MutedWord.Remaining) -> String {
        switch remaining {
        case .forever: return bundle.loc("Forever")
        case .days(let n): return String(format: bundle.loc("%lld days left"), n)
        case .hours(let n): return String(format: bundle.loc("%lld hours left"), n)
        case .underAnHour: return bundle.loc("Less than an hour left")
        }
    }

    private func add() {
        guard canAdd else { return }
        let text = draft
        Task {
            if await viewModel.add(text, duration: duration, mode: mode) {
                draft = ""
                fieldFocused = true
            }
        }
    }
}
