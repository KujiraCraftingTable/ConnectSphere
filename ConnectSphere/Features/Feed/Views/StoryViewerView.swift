import SwiftUI
import Combine

/// Xem stories của một người — full screen, thanh progress từng tin,
/// tự chuyển sau 5 giây, chạm trái/phải để lùi/tới.
struct StoryViewerView: View {
    @Environment(\.dismiss) var dismiss

    let group: StoryGroup
    var onClose: (() -> Void)? = nil

    @State private var currentIndex = 0
    @State private var progress: Double = 0   // 0...1 của story hiện tại

    private let storyRepo = StoryRepository()
    private let secondsPerStory: Double = 5
    private let tick: Double = 0.05
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var currentStory: StoryDTO? {
        group.stories.indices.contains(currentIndex) ? group.stories[currentIndex] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Ảnh story hiện tại
            if let story = currentStory, let url = URL(string: story.imageUrl) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Vùng chạm: trái = lùi, phải = tới
            HStack(spacing: 0) {
                Rectangle().fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { goPrevious() }
                Rectangle().fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { goNext() }
            }

            // Overlay: progress + header
            VStack(spacing: 10) {
                // Progress segments
                HStack(spacing: 4) {
                    ForEach(group.stories.indices, id: \.self) { i in
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.3))
                                Capsule()
                                    .fill(Color.white)
                                    .frame(width: geo.size.width * segmentProgress(i))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                // Header: author + close
                HStack(spacing: 10) {
                    AvatarView(user: group.author, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.author.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        if let story = currentStory {
                            Text(story.createdAt.timeAgoString)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(8)
                    }
                }
                .padding(.horizontal, 12)

                Spacer()
            }
        }
        .statusBarHidden()
        .onAppear { markCurrentViewed() }
        .onReceive(timer) { _ in
            progress += tick / secondsPerStory
            if progress >= 1 { goNext() }
        }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.height > 60 { close() }
            }
        )
    }

    // MARK: - Navigation

    private func segmentProgress(_ index: Int) -> Double {
        if index < currentIndex { return 1 }
        if index == currentIndex { return min(progress, 1) }
        return 0
    }

    private func goNext() {
        if currentIndex < group.stories.count - 1 {
            currentIndex += 1
            progress = 0
            markCurrentViewed()
        } else {
            close()
        }
    }

    private func goPrevious() {
        if progress > 0.15 {
            progress = 0
        } else if currentIndex > 0 {
            currentIndex -= 1
            progress = 0
        }
    }

    private func close() {
        onClose?()
        dismiss()
    }

    private func markCurrentViewed() {
        guard let story = currentStory, !story.viewed else { return }
        Task { try? await storyRepo.markViewed(storyId: story.id) }
    }
}
