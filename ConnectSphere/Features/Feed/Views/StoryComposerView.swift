import SwiftUI
import PhotosUI

/// Story composer — presented full-screen from `StoriesRow`'s "+"/empty-avatar
/// tap. Up to 4 photos arranged in an adaptive collage (1 = full-bleed, 2 =
/// stacked halves, 3 = one large + two small, 4 = even 2×2 grid), each
/// independently pinch-to-zoom + drag-to-pan, plus one optional styled text
/// overlay (drag to reposition, pinch to resize).
///
/// "Post" flattens the exact on-screen canvas into a single `UIImage` via
/// `ImageRenderer` and uploads it through the same pipeline a plain
/// single-photo story always used (`PostRepository.uploadImage` →
/// `StoryRepository.createStory`) — the server never knows a collage or text
/// overlay was involved; it just gets one JPEG, same as before this feature.
struct StoryComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle

    let mode: String
    /// Called after a successful post, so the caller can reload its list.
    var onPosted: () -> Void

    @State private var frames: [ComposerFrame] = []
    @State private var textLayer = TextLayerState()
    @State private var showTextEditor = false
    @State private var showPicker = false
    @State private var replacingFrameIndex: Int?
    @State private var replacementItem: PhotosPickerItem?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isPosting = false

    private let storyRepo = StoryRepository()
    private let postRepo = PostRepository()

    /// Design-time canvas size the collage is laid out and rendered at —
    /// roughly a 9:16 story frame. `ImageRenderer`'s `scale` (see `post()`)
    /// is what actually determines the exported resolution, not this.
    private let canvasSize = CGSize(width: 360, height: 640)

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer(minLength: 0)
                canvasArea
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .principal) {
                    if !frames.isEmpty {
                        Button {
                            showTextEditor = true
                        } label: {
                            Text("Aa")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.18), in: Capsule())
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await post() }
                    } label: {
                        if isPosting {
                            ProgressView().tint(.white)
                        } else {
                            Text("Post", bundle: bundle).bold().foregroundColor(.white)
                        }
                    }
                    .disabled(frames.isEmpty || isPosting)
                }
            }
        }
        .preferredColorScheme(.dark)
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPicked(items) }
        }
        .photosPicker(isPresented: Binding(
            get: { replacingFrameIndex != nil },
            set: { if !$0 { replacingFrameIndex = nil } }
        ), selection: $replacementItem, matching: .images)
        .onChange(of: replacementItem) { _, item in
            guard let item, let index = replacingFrameIndex else { return }
            Task { await loadReplacement(item, at: index) }
        }
        .sheet(isPresented: $showTextEditor) {
            textEditorSheet
        }
        .task {
            // The composer IS the new "+" flow — open the picker immediately
            // on first appearance, matching the old instant-picker behavior.
            if frames.isEmpty { showPicker = true }
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasArea: some View {
        if frames.isEmpty {
            emptyCanvasPlaceholder
        } else {
            canvas
        }
    }

    private var emptyCanvasPlaceholder: some View {
        Button {
            showPicker = true
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 40))
                Text("Choose up to 4 photos", bundle: bundle)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.7))
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    /// The pure visual content — collage frames + text overlay, nothing
    /// else. This is exactly what gets flattened into the posted image (see
    /// `post()`), so it must never contain editing-only chrome.
    private var composedContent: some View {
        let rects = Self.frameRects(count: frames.count, in: canvasSize)
        return ZStack {
            Color.black
            ForEach(frames.indices, id: \.self) { i in
                EditableFrame(frame: $frames[i], rect: rects[i])
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 1.5))
            }
            if !textLayer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EditableText(state: $textLayer)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    /// What's actually shown on screen while editing: `composedContent` plus
    /// the per-frame "replace photo" button — UI-only chrome, deliberately
    /// layered on top rather than baked into `composedContent`, since that's
    /// the exact view `post()` renders to produce the uploaded image.
    private var canvas: some View {
        let rects = Self.frameRects(count: frames.count, in: canvasSize)
        return ZStack {
            composedContent
            ForEach(frames.indices, id: \.self) { i in
                Button {
                    replacingFrameIndex = i
                } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
                .position(x: rects[i].minX + 22, y: rects[i].minY + 22)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    /// Adaptive collage layout: 1 = full-bleed, 2 = stacked halves, 3 = one
    /// large top + two small bottom, 4 = even 2×2 grid.
    static func frameRects(count: Int, in size: CGSize) -> [CGRect] {
        switch count {
        case 0:
            return []
        case 1:
            return [CGRect(origin: .zero, size: size)]
        case 2:
            let h = size.height / 2
            return [
                CGRect(x: 0, y: 0, width: size.width, height: h),
                CGRect(x: 0, y: h, width: size.width, height: size.height - h),
            ]
        case 3:
            let topH = size.height / 2
            let halfW = size.width / 2
            return [
                CGRect(x: 0, y: 0, width: size.width, height: topH),
                CGRect(x: 0, y: topH, width: halfW, height: size.height - topH),
                CGRect(x: halfW, y: topH, width: size.width - halfW, height: size.height - topH),
            ]
        default: // 4
            let halfW = size.width / 2
            let halfH = size.height / 2
            return [
                CGRect(x: 0, y: 0, width: halfW, height: halfH),
                CGRect(x: halfW, y: 0, width: size.width - halfW, height: halfH),
                CGRect(x: 0, y: halfH, width: halfW, height: size.height - halfH),
                CGRect(x: halfW, y: halfH, width: size.width - halfW, height: size.height - halfH),
            ]
        }
    }

    // MARK: - Text editor sheet

    private var textEditorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(bundle.loc("Add text..."), text: $textLayer.text, axis: .vertical)
                }
                Section(bundle.loc("Color")) {
                    colorSwatchRow
                }
                Section(bundle.loc("Font")) {
                    Picker(bundle.loc("Font"), selection: $textLayer.fontDesign) {
                        Text(bundle.loc("Default")).tag(Font.Design.default)
                        Text(bundle.loc("Serif")).tag(Font.Design.serif)
                        Text(bundle.loc("Rounded")).tag(Font.Design.rounded)
                        Text(bundle.loc("Monospaced")).tag(Font.Design.monospaced)
                    }
                    .pickerStyle(.segmented)
                }
                Section(bundle.loc("Size")) {
                    Slider(value: $textLayer.fontSize, in: 16...64)
                }
                Section {
                    Toggle(bundle.loc("Background highlight"), isOn: $textLayer.hasBackground)
                }
            }
            .navigationTitle(bundle.loc("Add text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) { showTextEditor = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var colorSwatchRow: some View {
        let colors: [Color] = [.white, .black, .red, .orange, .yellow, .green, .blue, .purple, .pink]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(colors.indices, id: \.self) { i in
                    Circle()
                        .fill(colors[i])
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(Color.gray, lineWidth: colors[i] == textLayer.color ? 3 : 1))
                        .onTapGesture { textLayer.color = colors[i] }
                }
                ColorPicker("", selection: $textLayer.color).labelsHidden()
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Picking

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        var newFrames: [ComposerFrame] = []
        for item in items.prefix(4) {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                newFrames.append(ComposerFrame(image: image))
            }
        }
        frames = newFrames
        pickerItems = []
    }

    private func loadReplacement(_ item: PhotosPickerItem, at index: Int) async {
        defer { replacingFrameIndex = nil; replacementItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              frames.indices.contains(index) else { return }
        frames[index] = ComposerFrame(image: image)
    }

    // MARK: - Compositing + posting

    private func post() async {
        guard !frames.isEmpty, !isPosting else { return }
        isPosting = true
        defer { isPosting = false }

        // `composedContent`, not `canvas` — the latter also includes the
        // per-frame "replace photo" buttons, which must never end up baked
        // into the actual posted image.
        let renderer = ImageRenderer(content: composedContent)
        // Render at a real resolution, not screen points — the canvas is a
        // fixed design-time size (`canvasSize`), so a flat 1x render would
        // look soft once viewed full-screen in `StoryViewerView`.
        renderer.scale = 3
        guard let flattened = renderer.uiImage,
              let jpeg = flattened.jpegData(compressionQuality: 0.9),
              let imageUrl = try? await postRepo.uploadImage(jpeg) else { return }

        guard (try? await storyRepo.createStory(imageUrl: imageUrl, mode: mode)) != nil else { return }
        onPosted()
        dismiss()
    }
}

// MARK: - Frame model + editable view

struct ComposerFrame: Identifiable {
    let id = UUID()
    var image: UIImage
    var scale: CGFloat = 1
    var lastScale: CGFloat = 1
    var offset: CGSize = .zero
    var lastOffset: CGSize = .zero
}

/// One collage slot: its photo always fills the slot (`scaledToFill`), then
/// pinch zooms in further and drag repositions within it — the photo can
/// never be zoomed below "just covers the frame", matching how a normal
/// story/collage editor behaves (no gaps ever show at the frame's edges).
private struct EditableFrame: View {
    @Binding var frame: ComposerFrame
    let rect: CGRect

    var body: some View {
        Image(uiImage: frame.image)
            .resizable()
            .scaledToFill()
            .frame(width: rect.width, height: rect.height)
            .scaleEffect(frame.scale)
            .offset(frame.offset)
            .frame(width: rect.width, height: rect.height)
            .clipped()
            .contentShape(Rectangle())
            .position(x: rect.midX, y: rect.midY)
            .gesture(magnification)
            .simultaneousGesture(pan)
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                frame.scale = max(frame.lastScale * value, 1)
            }
            .onEnded { _ in frame.lastScale = frame.scale }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                frame.offset = CGSize(
                    width: frame.lastOffset.width + value.translation.width,
                    height: frame.lastOffset.height + value.translation.height)
            }
            .onEnded { _ in frame.lastOffset = frame.offset }
    }
}

// MARK: - Text overlay model + editable view

struct TextLayerState {
    var text: String = ""
    var color: Color = .white
    var fontDesign: Font.Design = .default
    var fontSize: CGFloat = 32
    var hasBackground: Bool = false
    var position = CGPoint(x: 180, y: 320)
    var scale: CGFloat = 1
    var lastScale: CGFloat = 1
    var dragOffset: CGSize = .zero
}

private struct EditableText: View {
    @Binding var state: TextLayerState

    var body: some View {
        Text(state.text)
            .font(.system(size: state.fontSize, weight: .bold, design: state.fontDesign))
            .foregroundColor(state.color)
            .padding(state.hasBackground ? 10 : 0)
            .background {
                if state.hasBackground {
                    Capsule().fill(Color.black.opacity(0.55))
                }
            }
            .scaleEffect(state.scale)
            .position(x: state.position.x + state.dragOffset.width,
                      y: state.position.y + state.dragOffset.height)
            .gesture(
                DragGesture()
                    .onChanged { value in state.dragOffset = value.translation }
                    .onEnded { value in
                        state.position.x += value.translation.width
                        state.position.y += value.translation.height
                        state.dragOffset = .zero
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in state.scale = max(state.lastScale * value, 0.5) }
                    .onEnded { _ in state.lastScale = state.scale }
            )
    }
}
