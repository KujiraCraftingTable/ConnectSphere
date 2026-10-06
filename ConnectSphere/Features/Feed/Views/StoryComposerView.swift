import SwiftUI
import PhotosUI

/// Story composer — presented full-screen from `StoriesRow`'s "+"/empty-avatar
/// tap. Up to 4 photos arranged in a collage, each independently
/// pinch-to-zoom + drag-to-pan; every photo count (1-4) offers 2 alternate
/// layout templates, picked via `layoutPicker`'s swatches (see
/// `frameRects(count:variant:ratios:in:)` for exactly what each looks like). Any
/// number of styled text overlays can be added (drag to reposition, pinch to
/// resize, drag to the bottom trash zone to delete).
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
    /// Which of the 2 layout templates for the current photo count is
    /// active — reset to `.a` whenever a fresh set of photos is picked.
    @State private var layoutVariant: LayoutVariant = .a
    /// Adjustable divider positions, as a fraction (0...1) of the canvas
    /// width/height — which slot means what depends on the current
    /// (frames.count, layoutVariant) shape, see `frameRects`/`dividers`.
    /// Reset to even whenever a fresh set of photos is picked or the
    /// layout variant changes (a different shape's dividers mean something
    /// different, so a carried-over value would be meaningless).
    @State private var ratios: [CGFloat] = [0.5, 0.5]
    @State private var textLayers: [TextLayerState] = []
    /// Which layer the text-editor sheet is currently editing — always the
    /// one "Aa" just created; the sheet never re-opens an existing layer.
    @State private var editingTextLayerID: UUID?
    @State private var showTextEditor = false
    @State private var showPicker = false
    @State private var replacingFrameIndex: Int?
    @State private var replacementItem: PhotosPickerItem?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var viewModel = StoryComposerViewModel()
    /// Drag-to-delete: while any text is being dragged, a trash icon shows
    /// at the bottom of the canvas; dropping the text near it deletes it.
    @State private var isDraggingText = false
    @State private var isNearTrash = false


    /// Design-time canvas size the collage is laid out and rendered at —
    /// roughly a 9:16 story frame. `ImageRenderer`'s `scale` (see `post()`)
    /// is what actually determines the exported resolution, not this.
    private let canvasSize = CGSize(width: 360, height: 640)

    /// Bottom-center drop zone a dragged text is deleted by releasing near.
    private let trashPoint = CGPoint(x: 180, y: 600)
    private let trashRadius: CGFloat = 36

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer(minLength: 0)
                canvasArea
                layoutPicker
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
                            addTextLayer()
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
                        if viewModel.isPosting {
                            ProgressView().tint(.white)
                        } else {
                            Text("Post", bundle: bundle).bold().foregroundColor(.white)
                        }
                    }
                    .disabled(frames.isEmpty || viewModel.isPosting)
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

    /// Two small tappable previews of the current photo count's two layout
    /// templates — hidden until at least one photo is picked (no layout to
    /// choose between before then).
    @ViewBuilder
    private var layoutPicker: some View {
        if !frames.isEmpty {
            HStack(spacing: 16) {
                layoutSwatch(.a)
                layoutSwatch(.b)
            }
        }
    }

    private func layoutSwatch(_ variant: LayoutVariant) -> some View {
        let previewSize = CGSize(width: 36, height: 64)
        let rects = Self.frameRects(count: frames.count, variant: variant, ratios: [0.5, 0.5], in: previewSize)
        let isSelected = layoutVariant == variant
        return ZStack {
            ForEach(rects.indices, id: \.self) { i in
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                    .frame(width: rects[i].width, height: rects[i].height)
                    .position(x: rects[i].midX, y: rects[i].midY)
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .padding(4)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? themeManager.theme.primary : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            layoutVariant = variant
            ratios = [0.5, 0.5]
        }
    }

    /// The pure visual content — collage frames + text overlay, nothing
    /// else. This is exactly what gets flattened into the posted image (see
    /// `post()`), so it must never contain editing-only chrome.
    private var composedContent: some View {
        let rects = Self.frameRects(count: frames.count, variant: layoutVariant, ratios: ratios, in: canvasSize)
        return ZStack {
            Color.black
            ForEach(frames.indices, id: \.self) { i in
                EditableFrame(frame: $frames[i], rect: rects[i], onDoubleTap: { replacingFrameIndex = i })
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 1.5))
            }
            ForEach(textLayers.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { layer in
                EditableText(
                    state: binding(for: layer.id),
                    onDragMove: { textDragMoved(to: $0) },
                    onDragEnd: { textDragEnded(layer.id, at: $0) }
                )
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    /// What's actually shown on screen while editing: `composedContent` plus
    /// the per-frame "replace photo" button — UI-only chrome, deliberately
    /// layered on top rather than baked into `composedContent`, since that's
    /// the exact view `post()` renders to produce the uploaded image.
    private var canvas: some View {
        let rects = Self.frameRects(count: frames.count, variant: layoutVariant, ratios: ratios, in: canvasSize)
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
            // Draggable lines between frames — pure editing chrome, kept out
            // of `composedContent` like everything else on this layer.
            ForEach(Self.dividers(count: frames.count, variant: layoutVariant, ratios: ratios, in: canvasSize)) { divider in
                DividerHandle(
                    divider: divider,
                    ratios: $ratios,
                    axisLength: divider.isHorizontal ? canvasSize.height : canvasSize.width
                )
            }
            // Drag-to-delete target — shown only while a text layer is
            // actively being dragged, never part of the exported image.
            if isDraggingText {
                Image(systemName: isNearTrash ? "trash.circle.fill" : "trash.circle")
                    .font(.system(size: isNearTrash ? 40 : 32))
                    .foregroundColor(isNearTrash ? .red : .white.opacity(0.85))
                    .position(trashPoint)
                    .animation(.easeInOut(duration: 0.15), value: isNearTrash)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    /// Two alternative collage templates per photo count, picked via
    /// `layoutPicker`'s swatches:
    ///  1 photo — `.a` full-bleed edge-to-edge, `.b` inset/"framed" with a margin.
    ///  2 photos — `.a` stacked halves, `.b` side-by-side halves.
    ///  3 photos — `.a` one large top + two small bottom, `.b` one large left + two small right.
    ///  4 photos — `.a` even 2×2 grid, `.b` one large top + three small bottom columns.
    /// Every split is a fraction from `ratios` rather than a fixed half, so
    /// dragging a divider (see `dividers`/`DividerHandle`) actually resizes
    /// the frames on either side of it. The one exception is `(4, .b)`'s
    /// three bottom columns, which stay equal-width — a disclosed scope
    /// trim so this doesn't need a third ratio slot.
    static func frameRects(count: Int, variant: LayoutVariant, ratios: [CGFloat], in size: CGSize) -> [CGRect] {
        let r0 = ratios.count > 0 ? ratios[0] : 0.5
        let r1 = ratios.count > 1 ? ratios[1] : 0.5
        switch (count, variant) {
        case (0, _):
            return []

        case (1, .a):
            return [CGRect(origin: .zero, size: size)]
        case (1, .b):
            let inset: CGFloat = 24
            return [CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)]

        case (2, .a):
            let h = size.height * r0
            return [
                CGRect(x: 0, y: 0, width: size.width, height: h),
                CGRect(x: 0, y: h, width: size.width, height: size.height - h),
            ]
        case (2, .b):
            let w = size.width * r0
            return [
                CGRect(x: 0, y: 0, width: w, height: size.height),
                CGRect(x: w, y: 0, width: size.width - w, height: size.height),
            ]

        case (3, .a):
            let topH = size.height * r0
            let halfW = size.width * r1
            return [
                CGRect(x: 0, y: 0, width: size.width, height: topH),
                CGRect(x: 0, y: topH, width: halfW, height: size.height - topH),
                CGRect(x: halfW, y: topH, width: size.width - halfW, height: size.height - topH),
            ]
        case (3, .b):
            let leftW = size.width * r0
            let halfH = size.height * r1
            return [
                CGRect(x: 0, y: 0, width: leftW, height: size.height),
                CGRect(x: leftW, y: 0, width: size.width - leftW, height: halfH),
                CGRect(x: leftW, y: halfH, width: size.width - leftW, height: size.height - halfH),
            ]

        case (4, .a):
            let w = size.width * r0
            let h = size.height * r1
            return [
                CGRect(x: 0, y: 0, width: w, height: h),
                CGRect(x: w, y: 0, width: size.width - w, height: h),
                CGRect(x: 0, y: h, width: w, height: size.height - h),
                CGRect(x: w, y: h, width: size.width - w, height: size.height - h),
            ]
        default: // (4, .b)
            let topH = size.height * r0
            let thirdW = size.width / 3
            return [
                CGRect(x: 0, y: 0, width: size.width, height: topH),
                CGRect(x: 0, y: topH, width: thirdW, height: size.height - topH),
                CGRect(x: thirdW, y: topH, width: thirdW, height: size.height - topH),
                CGRect(x: thirdW * 2, y: topH, width: size.width - thirdW * 2, height: size.height - topH),
            ]
        }
    }

    /// One draggable divider between two adjacent frames.
    struct FrameDivider: Identifiable {
        /// `ratioIndex` is always unique within one `dividers(...)` call
        /// (at most 2 dividers per shape, one per ratio slot).
        var id: Int { ratioIndex }
        let ratioIndex: Int
        /// `true` = a horizontal line (dragged vertically, up/down);
        /// `false` = a vertical line (dragged horizontally, left/right).
        let isHorizontal: Bool
        /// Generous draggable hit area, centered on the actual line.
        let hitRect: CGRect
    }

    /// The divider(s) for the current shape, positioned from the same
    /// `rects` `frameRects` just computed for it (a divider always sits
    /// exactly on the shared boundary between two of those rects). Mirrors
    /// `frameRects`'s own switch — see its doc comment for what each shape
    /// looks like.
    static func dividers(count: Int, variant: LayoutVariant, ratios: [CGFloat], in size: CGSize) -> [FrameDivider] {
        let r0 = ratios.count > 0 ? ratios[0] : 0.5
        let r1 = ratios.count > 1 ? ratios[1] : 0.5
        let thickness: CGFloat = 28
        switch (count, variant) {
        case (2, .a):
            let y = size.height * r0
            return [FrameDivider(ratioIndex: 0, isHorizontal: true,
                                  hitRect: CGRect(x: 0, y: y - thickness / 2, width: size.width, height: thickness))]
        case (2, .b):
            let x = size.width * r0
            return [FrameDivider(ratioIndex: 0, isHorizontal: false,
                                  hitRect: CGRect(x: x - thickness / 2, y: 0, width: thickness, height: size.height))]
        case (3, .a):
            let topH = size.height * r0
            let x = size.width * r1
            return [
                FrameDivider(ratioIndex: 0, isHorizontal: true,
                             hitRect: CGRect(x: 0, y: topH - thickness / 2, width: size.width, height: thickness)),
                FrameDivider(ratioIndex: 1, isHorizontal: false,
                             hitRect: CGRect(x: x - thickness / 2, y: topH, width: thickness, height: size.height - topH)),
            ]
        case (3, .b):
            let leftW = size.width * r0
            let y = size.height * r1
            return [
                FrameDivider(ratioIndex: 0, isHorizontal: false,
                             hitRect: CGRect(x: leftW - thickness / 2, y: 0, width: thickness, height: size.height)),
                FrameDivider(ratioIndex: 1, isHorizontal: true,
                             hitRect: CGRect(x: leftW, y: y - thickness / 2, width: size.width - leftW, height: thickness)),
            ]
        case (4, .a):
            let x = size.width * r0
            let y = size.height * r1
            return [
                FrameDivider(ratioIndex: 0, isHorizontal: false,
                             hitRect: CGRect(x: x - thickness / 2, y: 0, width: thickness, height: size.height)),
                FrameDivider(ratioIndex: 1, isHorizontal: true,
                             hitRect: CGRect(x: 0, y: y - thickness / 2, width: size.width, height: thickness)),
            ]
        case (4, .b):
            let topH = size.height * r0
            return [FrameDivider(ratioIndex: 0, isHorizontal: true,
                                  hitRect: CGRect(x: 0, y: topH - thickness / 2, width: size.width, height: thickness))]
        default: // (0, _), (1, .a), (1, .b) — nothing to divide
            return []
        }
    }

    // MARK: - Text editor sheet

    /// The layer "Aa" just created and opened the sheet for. Falls back to a
    /// throwaway, harmlessly-discarded binding if somehow no id is set (the
    /// sheet is only ever shown right after `addTextLayer()` sets one).
    private var editingBinding: Binding<TextLayerState> {
        binding(for: editingTextLayerID ?? UUID())
    }

    private var textEditorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(bundle.loc("Add text..."), text: editingBinding.text, axis: .vertical)
                }
                Section(bundle.loc("Color")) {
                    colorSwatchRow
                }
                Section(bundle.loc("Font")) {
                    Picker(bundle.loc("Font"), selection: editingBinding.fontDesign) {
                        Text(bundle.loc("Default")).tag(Font.Design.default)
                        Text(bundle.loc("Serif")).tag(Font.Design.serif)
                        Text(bundle.loc("Rounded")).tag(Font.Design.rounded)
                        Text(bundle.loc("Monospaced")).tag(Font.Design.monospaced)
                    }
                    .pickerStyle(.segmented)
                }
                Section(bundle.loc("Size")) {
                    Slider(value: editingBinding.fontSize, in: 16...64)
                }
                Section {
                    Toggle(bundle.loc("Background highlight"), isOn: editingBinding.hasBackground)
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
                        .overlay(Circle().stroke(Color.gray, lineWidth: colors[i] == editingBinding.wrappedValue.color ? 3 : 1))
                        .onTapGesture { editingBinding.wrappedValue.color = colors[i] }
                }
                ColorPicker("", selection: editingBinding.color).labelsHidden()
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Text layers

    /// A binding to one specific layer by id — used both by the editor
    /// sheet (bound to whichever layer "Aa" just created) and by each
    /// `EditableText` on the canvas.
    private func binding(for id: UUID) -> Binding<TextLayerState> {
        Binding(
            get: { textLayers.first { $0.id == id } ?? TextLayerState() },
            set: { newValue in
                if let i = textLayers.firstIndex(where: { $0.id == id }) {
                    textLayers[i] = newValue
                }
            }
        )
    }

    /// "Aa" always creates a brand-new text layer and opens the editor for
    /// it — never re-opens an existing one. Staggers the default position
    /// slightly per existing layer so new texts don't land exactly on top
    /// of earlier ones.
    private func addTextLayer() {
        var layer = TextLayerState()
        // Spawn well within the region still visible above the `.medium`
        // text-editor sheet (which covers roughly the bottom half of the
        // screen) so the user can actually see what they're typing/styling
        // as they do it. The previous version accumulated +40pt of Y per
        // existing layer, which could push a 3rd/4th text down behind the
        // sheet entirely — a small horizontal-only stagger still keeps
        // several never-yet-repositioned texts from landing in the exact
        // same spot, without risking that.
        let stagger = CGFloat(textLayers.count % 4) * 24 - 36
        layer.position = CGPoint(x: canvasSize.width / 2 + stagger, y: canvasSize.height * 0.22)
        textLayers.append(layer)
        editingTextLayerID = layer.id
        showTextEditor = true
    }

    private func textDragMoved(to point: CGPoint) {
        isDraggingText = true
        isNearTrash = distance(point, trashPoint) < trashRadius
    }

    /// Drop near the trash zone deletes the layer; otherwise its position
    /// commits to where it was dropped.
    private func textDragEnded(_ id: UUID, at point: CGPoint) {
        isDraggingText = false
        isNearTrash = false
        if distance(point, trashPoint) < trashRadius {
            textLayers.removeAll { $0.id == id }
        } else if let i = textLayers.firstIndex(where: { $0.id == id }) {
            textLayers[i].position = point
        }
    }

    // MARK: - Picking

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        frames = await viewModel.loadImages(from: items).map { ComposerFrame(image: $0) }
        layoutVariant = .a
        ratios = [0.5, 0.5]
        pickerItems = []
    }

    private func loadReplacement(_ item: PhotosPickerItem, at index: Int) async {
        defer { replacingFrameIndex = nil; replacementItem = nil }
        guard let image = await viewModel.loadImage(from: item),
              frames.indices.contains(index) else { return }
        frames[index] = ComposerFrame(image: image)
    }

    // MARK: - Compositing + posting (the render needs the view; the upload doesn't)

    private func post() async {
        guard !frames.isEmpty, !viewModel.isPosting else { return }

        // `composedContent`, not `canvas` — the latter also includes the
        // per-frame "replace photo" buttons, which must never end up baked
        // into the actual posted image.
        let renderer = ImageRenderer(content: composedContent)
        // Render at a real resolution, not screen points — the canvas is a
        // fixed design-time size (`canvasSize`), so a flat 1x render would
        // look soft once viewed full-screen in `StoryViewerView`.
        renderer.scale = 3
        guard let jpeg = renderer.uiImage?.jpegData(compressionQuality: 0.9),
              await viewModel.publish(jpeg: jpeg, mode: mode) else { return }
        onPosted()
        dismiss()
    }
}

// MARK: - Frame model + editable view

/// Two alternate collage templates exist for every photo count (1-4) — see
/// `StoryComposerView.frameRects(count:variant:ratios:in:)` for what each looks
/// like at each count.
enum LayoutVariant: CaseIterable {
    case a, b
}

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
    /// Double-tapping the photo also opens the replace-photo picker — a
    /// second, more discoverable-by-feel path to the same flow the corner
    /// button triggers. Reported up rather than handled locally since
    /// `replacingFrameIndex` lives on the parent (`StoryComposerView`), not
    /// this single frame.
    var onDoubleTap: () -> Void = {}

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
            .onTapGesture(count: 2, perform: onDoubleTap)
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

/// The draggable line between two adjacent frames — a thin visible line
/// plus a much more generous invisible hit area, both centered on
/// `divider.hitRect`. Drags by translation-from-drag-start (like
/// `EditableFrame`'s own pan/zoom) rather than `DragGesture`'s `location`,
/// which is relative to this view's own small local frame, not the canvas —
/// translation is coordinate-space-agnostic, so it stays correct regardless
/// of where the hit rect sits.
private struct DividerHandle: View {
    let divider: StoryComposerView.FrameDivider
    @Binding var ratios: [CGFloat]
    /// The canvas dimension (width or height) this divider's ratio is a
    /// fraction of.
    let axisLength: CGFloat

    @State private var startRatio: CGFloat = 0

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.001))
            Rectangle()
                .fill(Color.white.opacity(0.6))
                .frame(width: divider.isHorizontal ? nil : 2, height: divider.isHorizontal ? 2 : nil)
        }
        .frame(width: divider.hitRect.width, height: divider.hitRect.height)
        .contentShape(Rectangle())
        .position(x: divider.hitRect.midX, y: divider.hitRect.midY)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation == .zero { startRatio = ratios[divider.ratioIndex] }
                    let delta = divider.isHorizontal ? value.translation.height : value.translation.width
                    ratios[divider.ratioIndex] = min(max(startRatio + delta / axisLength, 0.15), 0.85)
                }
        )
    }
}

// MARK: - Text overlay model + editable view

struct TextLayerState: Identifiable {
    let id = UUID()
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
    /// Live absolute position while dragging — lets the parent track
    /// proximity to the trash zone and show/highlight its icon.
    var onDragMove: (CGPoint) -> Void = { _ in }
    /// Final absolute position on release — the parent decides whether to
    /// commit it as the new position or delete this layer entirely (a
    /// single-layer `Binding` can't remove itself from the array it lives
    /// in, so that decision has to live one level up).
    var onDragEnd: (CGPoint) -> Void = { _ in }

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
                    .onChanged { value in
                        state.dragOffset = value.translation
                        onDragMove(CGPoint(x: state.position.x + value.translation.width,
                                            y: state.position.y + value.translation.height))
                    }
                    .onEnded { value in
                        let finalPoint = CGPoint(x: state.position.x + value.translation.width,
                                                  y: state.position.y + value.translation.height)
                        state.dragOffset = .zero
                        onDragEnd(finalPoint)
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in state.scale = max(state.lastScale * value, 0.5) }
                    .onEnded { _ in state.lastScale = state.scale }
            )
    }
}
