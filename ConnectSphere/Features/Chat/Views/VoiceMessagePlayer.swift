import SwiftUI
import AVFoundation

/// A voice message's player: play/pause, a waveform that fills as it plays,
/// and the duration. The waveform's bar heights come straight from
/// `message.voiceWaveform` — the samples were captured once at record time
/// and sent with the message, so every viewer sees the same shape and no
/// audio is re-analysed here; only the played/unplayed colour split follows
/// local playback.
///
/// Shared by the full chat (`MessageBubble`, which draws the bubble around
/// it) and the floating window. The floating window plays one sound at a
/// time: it passes `isActive`, and a player that loses it stops.
struct VoiceMessagePlayer: View {
    @Environment(\.colorScheme) private var colorScheme

    let message: Message
    let isOwn: Bool
    let accent: Color
    var compact = false
    /// `nil` = play independently (full chat). Otherwise this player may only
    /// keep playing while it's `true`.
    var isActive: Bool? = nil
    var onStart: (() -> Void)? = nil

    /// Matches the fixed ~40-point sample count `VoiceRecorderControl`
    /// captures client-side at record time.
    private static let waveformBarCount = 40

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var progressTimer: Timer?

    var body: some View {
        // The duration gets its own line at the bottom right rather than
        // sharing the row: beside the waveform it was squeezed to a few
        // points and wrapped one character per line.
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: compact ? 7 : 10) {
                Button(action: toggle) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: compact ? 24 : 30))
                        .foregroundColor(isOwn ? .white : accent)
                }
                .buttonStyle(.plain)

                waveform
            }

            Text(durationLabel)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(isOwn ? .white.opacity(0.85) : AppColors.textSecondary(colorScheme))
        }
        .onChange(of: isActive) { _, active in
            if active == false, isPlaying { stop() }
        }
        .onDisappear { stop() }
    }

    private var waveform: some View {
        // Empty/missing waveform (e.g. a malformed or very old row) renders a
        // flat placeholder row instead of crashing on an empty array index.
        let samples: [Float] = {
            guard let w = message.voiceWaveform, !w.isEmpty else {
                return Array(repeating: Float(0.15), count: Self.waveformBarCount)
            }
            return w
        }()
        let playedBars = Int(progress * Double(samples.count))
        let activeColor = isOwn ? Color.white : accent
        let mutedColor = isOwn ? Color.white.opacity(0.4) : AppColors.textTertiary(colorScheme)

        // Bars are spread across whatever width is left beside the play
        // button, instead of a fixed 40 × (2pt + 2pt gap) that could crowd
        // out its neighbours.
        return Canvas { context, size in
            let step = size.width / CGFloat(samples.count)
            let barWidth = max(1.5, step - 2)
            for (index, sample) in samples.enumerated() {
                let barHeight = max(3, CGFloat(sample) * size.height)
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - barHeight) / 2,
                                  width: barWidth, height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(index < playedBars ? activeColor : mutedColor))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 20 : 26)
        .accessibilityHidden(true)
    }

    private var durationLabel: String {
        let seconds = message.voiceDurationSeconds ?? 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func toggle() {
        if isPlaying {
            stop()
            return
        }
        guard let url = message.absoluteMediaURL() else { return }
        onStart?()

        // AVAudioPlayer needs local data/a file URL, so fetch the remote
        // audio into memory first, then decode it on the main thread.
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data else { return }
            DispatchQueue.main.async {
                do {
                    let player = try AVAudioPlayer(data: data)
                    player.prepareToPlay()
                    self.player = player
                    player.play()
                    self.isPlaying = true
                    self.startProgressTimer()
                } catch {
                    self.isPlaying = false
                }
            }
        }.resume()
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let player = self.player else { return }
            if player.isPlaying {
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            } else {
                self.stop()
            }
        }
    }

    private func stop() {
        player?.stop()
        progressTimer?.invalidate()
        progressTimer = nil
        isPlaying = false
        progress = 0
    }
}
