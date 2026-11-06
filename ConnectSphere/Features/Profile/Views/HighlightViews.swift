import SwiftUI
import PhotosUI
import Combine

/// A Hobby profile's highlights: a row of circles under the card; yours
/// starts with "New".
struct HighlightsRow: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let userId: String
    let isMe: Bool

    @State private var viewModel = HighlightsViewModel()
    @State private var watching: Highlight?
    @State private var creating = false

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        Group {
            if isMe || !viewModel.highlights.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        if isMe {
                            Button { creating = true } label: {
                                bubble(title: bundle.loc("New")) {
                                    Image(systemName: "plus")
                                        .scaledFont(22, .semibold)
                                        .foregroundColor(themeManager.theme.primary)
                                        .frame(width: 64, height: 64)
                                        .background(AppColors.elevated(colorScheme), in: Circle())
                                }
                            }
                            .accessibilityLabel(Bundle.app.loc("New highlight"))
                            .buttonStyle(.plain)
                        }
                        ForEach(viewModel.highlights) { highlight in
                            Button { watching = highlight } label: {
                                bubble(title: highlight.title) { cover(highlight.coverUrl) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, 4)
                }
            }
        }
        .task(id: userId) { await viewModel.load(userId: userId, token: token) }
        .fullScreenCover(item: $watching) { highlight in
            HighlightViewerView(highlight: highlight, isMine: isMe) { viewModel.replace($0) }
        }
        .sheet(isPresented: $creating) {
            HighlightEditorView(editing: nil) { viewModel.replace($0) }
        }
    }

    private func bubble<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            content()
                .padding(3)
                .overlay(Circle().stroke(AppColors.borderDefault(colorScheme), lineWidth: 1.5))
            Text(title)
                .scaledFont(12)
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(1)
                .frame(width: 72)
        }
    }

    private func cover(_ path: String) -> some View {
        RemoteImage(url: APIConfig.mediaURL(path)) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { AppColors.elevated(colorScheme) }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
    }
}

/// One highlight full screen: like a story, a photo every few seconds; tap
/// the left / right to go back / on. The owner can remove the photo, make it
/// the cover, add photos, rename or delete the highlight.
struct HighlightViewerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: HighlightViewerViewModel
    @State private var confirmDelete = false
    @State private var confirmRemove = false
    @State private var editing = false
    let isMine: Bool
    let onChange: ([Highlight]) -> Void

    private let tick = 0.05
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    init(highlight: Highlight, isMine: Bool, onChange: @escaping ([Highlight]) -> Void) {
        _viewModel = State(initialValue: HighlightViewerViewModel(highlight: highlight))
        self.isMine = isMine
        self.onChange = onChange
    }

    private var token: String { appState.authToken ?? "" }
    private var paused: Bool { confirmDelete || confirmRemove || editing || viewModel.isWorking }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item = viewModel.current {
                RemoteImage(url: APIConfig.mediaURL(item.imageUrl)) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else { ProgressView().tint(.white) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { viewModel.previous() }
                Color.clear.contentShape(Rectangle()).onTapGesture { if viewModel.next() { dismiss() } }
            }
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(viewModel.highlight.items.indices, id: \.self) { i in
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.3))
                                Capsule().fill(Color.white).frame(width: geo.size.width * viewModel.progress(i))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                HStack(spacing: 10) {
                    Text(viewModel.highlight.title)
                        .scaledFont(15, .semibold)
                        .foregroundColor(.white)
                    if let item = viewModel.current {
                        Text(item.createdAt.timeAgoString)
                            .scaledFont(12)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Spacer()
                    if isMine { ownerMenu }
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").scaledFont(18, .semibold).foregroundColor(.white).padding(8)
                    }
                    .accessibilityLabel(Text(bundle.loc("Close")))
                }
                .padding(.horizontal, 12)
                Spacer()
                if let error = viewModel.errorMessage {
                    Text(error).scaledFont(13).foregroundColor(.white)
                        .padding(10).background(.black.opacity(0.6), in: Capsule()).padding(.bottom, 24)
                }
            }
        }
        .onReceive(timer) { _ in
            guard !paused else { return }
            if viewModel.tick(tick) { dismiss() }
        }
        .alert(bundle.loc("Remove this photo from the highlight?"), isPresented: $confirmRemove) {
            Button(bundle.loc("Remove"), role: .destructive) {
                Task {
                    guard let list = await viewModel.removeCurrent(token: token) else { return }
                    onChange(list)
                    if !list.contains(where: { $0.id == viewModel.highlight.id }) { dismiss() }
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        }
        .alert(bundle.loc("Delete this highlight?"), isPresented: $confirmDelete) {
            Button(bundle.loc("Delete"), role: .destructive) {
                Task {
                    guard let list = await viewModel.delete(token: token) else { return }
                    onChange(list)
                    dismiss()
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("All its photos will be removed from your profile.", bundle: bundle)
        }
        .sheet(isPresented: $editing) {
            HighlightEditorView(editing: viewModel.highlight) { list in
                onChange(list)
                viewModel.updated(list)
            }
        }
    }

    private var ownerMenu: some View {
        Menu {
            Button { confirmRemove = true } label: { Label(bundle.loc("Remove this photo"), systemImage: "minus.circle") }
            Button {
                Task { if let list = await viewModel.setCurrentAsCover(token: token) { onChange(list) } }
            } label: { Label(bundle.loc("Make cover"), systemImage: "photo.circle") }
            Button { editing = true } label: { Label(bundle.loc("Edit highlight"), systemImage: "pencil") }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label(bundle.loc("Delete highlight"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis").scaledFont(18, .semibold).foregroundColor(.white).padding(8)
        }
        .accessibilityLabel(Text(bundle.loc("More")))
    }
}

/// New highlight, or add photos to / rename one.
struct HighlightEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: HighlightEditorViewModel
    @State private var picked: [PhotosPickerItem] = []
    let onSaved: ([Highlight]) -> Void

    init(editing: Highlight?, preselectedStory: String? = nil, onSaved: @escaping ([Highlight]) -> Void) {
        _viewModel = State(initialValue: HighlightEditorViewModel(editing: editing, preselectedStory: preselectedStory))
        self.onSaved = onSaved
    }

    private var token: String { appState.authToken ?? "" }
    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField(bundle.loc("Title"), text: $viewModel.title)
                        CharacterCounter(count: viewModel.title.count, limit: Highlight.titleLimit)
                    }
                } footer: {
                    if viewModel.titleTooLong {
                        Text(String(format: bundle.loc("Keep it under %lld characters."), Highlight.titleLimit)).foregroundStyle(.red)
                    }
                }
                Section {
                    PhotosPicker(selection: $picked, maxSelectionCount: 20, matching: .images) {
                        Label(bundle.loc("Add photos"), systemImage: "photo.on.rectangle.angled")
                    }
                    if !viewModel.photos.isEmpty {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(Array(viewModel.photos.enumerated()), id: \.offset) { i, data in
                                thumbnail(Image(uiImage: UIImage(data: data) ?? UIImage()), selected: true) {
                                    viewModel.removePhoto(at: i)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("From your photos", bundle: bundle)
                }
                if !viewModel.myStories.isEmpty {
                    Section {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(viewModel.myStories) { story in
                                Button { viewModel.toggleStory(story.id) } label: {
                                    RemoteImage(url: APIConfig.mediaURL(story.imageUrl)) { phase in
                                        if let image = phase.image { image.resizable().scaledToFill() }
                                        else { AppColors.elevated(colorScheme) }
                                    }
                                    .frame(width: 84, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(alignment: .topTrailing) { check(viewModel.storyIds.contains(story.id)) }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("From your stories", bundle: bundle)
                    }
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(bundle.loc(viewModel.editing == nil ? "New highlight" : "Edit highlight"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ConfirmCancelButton(hasChanges: viewModel.hasChanges) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Button(bundle.loc("Save")) {
                            Task {
                                guard let list = await viewModel.save(token: token) else { return }
                                onSaved(list)
                                dismiss()
                            }
                        }
                        .disabled(!viewModel.canSave)
                    }
                }
            }
            .task { await viewModel.loadStories(myId: appState.currentUser?.id ?? "") }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    var loaded: [Data] = []
                    for item in items { if let data = try? await item.loadTransferable(type: Data.self) { loaded.append(data) } }
                    viewModel.add(loaded)
                    picked = []
                }
            }
        }
    }

    private func thumbnail(_ image: Image, selected: Bool, onRemove: @escaping () -> Void) -> some View {
        image.resizable().scaledToFill()
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").scaledFont(18).foregroundStyle(.white, .black.opacity(0.5))
                }
                .accessibilityLabel(Bundle.app.loc("Remove photo"))
                .buttonStyle(.borderless)
                .padding(4)
                .accessibilityLabel(Text(bundle.loc("Remove")))
            }
    }

    private func check(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .scaledFont(20)
            .foregroundStyle(on ? themeManager.theme.primary : .white)
            .shadow(radius: 2)
            .padding(6)
    }
}

/// From your own story: put it in one of your highlights, or a new one.
struct AddToHighlightSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let storyId: String
    @State private var viewModel = HighlightsViewModel()
    @State private var creating = false
    @State private var added: String?

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        NavigationStack {
            List {
                Button { creating = true } label: {
                    Label(bundle.loc("New highlight"), systemImage: "plus.circle.fill")
                }
                ForEach(viewModel.highlights) { highlight in
                    Button {
                        Task {
                            if await viewModel.addStory(storyId, to: highlight, token: token) {
                                added = highlight.title
                                try? await Task.sleep(for: .milliseconds(700))
                                dismiss()
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: APIConfig.mediaURL(highlight.coverUrl)) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                                else { AppColors.elevated(colorScheme) }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                            Text(highlight.title).foregroundStyle(.primary)
                            Spacer()
                            if added == highlight.title { Image(systemName: "checkmark").foregroundStyle(.green) }
                        }
                    }
                }
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red).scaledFont(14)
                }
            }
            .navigationTitle(bundle.loc("Add to highlight"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Cancel")) { dismiss() } }
            }
            .task { await viewModel.load(userId: appState.currentUser?.id ?? "", token: token) }
            .sheet(isPresented: $creating) {
                HighlightEditorView(editing: nil, preselectedStory: storyId) { list in
                    viewModel.replace(list)
                    dismiss()
                }
            }
        }
    }
}
