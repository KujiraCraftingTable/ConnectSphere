import AVFoundation
import Observation

/// One video in the full-screen viewer: play/pause, hold-for-2×, progress and
/// seeking. The viewer keeps one per video so the progress bar (drawn in the
/// viewer's overlay) and the page (where the gestures are) share it.
@MainActor
@Observable
final class VideoPlaybackViewModel {
    let url: URL
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    /// Held down on an edge: plays at 2× until released.
    private(set) var isFast = false
    private(set) var currentSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    /// While the bar is dragged, the time observer doesn't move it back.
    private(set) var isScrubbing = false

    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    nonisolated(unsafe) private var observedPlayer: AVPlayer?

    init(url: URL) { self.url = url }

    var progress: Double { durationSeconds > 0 ? min(max(currentSeconds / durationSeconds, 0), 1) : 0 }

    /// The page became the one on screen.
    func activate() {
        if player == nil {
            let player = AVPlayer(url: url)
            self.player = player
            observedPlayer = player
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                          queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, !self.isScrubbing else { return }
                    self.currentSeconds = time.seconds
                    if let d = self.player?.currentItem?.duration.seconds, d.isFinite { self.durationSeconds = d }
                }
            }
            // Loops at the end, like Facebook and TikTok.
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let player = self.player else { return }
                    player.seek(to: .zero)
                    if self.isPlaying { player.rate = self.isFast ? 2 : 1 }
                }
            }
        }
        play()
    }

    /// Swiped away or the viewer closed.
    func deactivate() {
        player?.pause()
        isPlaying = false
        isFast = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    private func play() {
        player?.rate = isFast ? 2 : 1
        isPlaying = true
    }

    private func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Press and hold an edge: 2× while held; letting go returns to normal
    /// speed (or stays paused if it was paused).
    func setFast(_ fast: Bool) {
        isFast = fast
        if fast {
            player?.rate = 2
        } else if isPlaying {
            player?.rate = 1
        } else {
            player?.pause()
        }
    }

    func beginScrubbing() { isScrubbing = true }

    /// `fraction` of the way through, 0...1.
    func scrub(to fraction: Double) {
        guard durationSeconds > 0 else { return }
        currentSeconds = min(max(fraction, 0), 1) * durationSeconds
    }

    func endScrubbing() {
        let target = CMTime(seconds: currentSeconds, preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.isScrubbing = false }
        }
    }

    deinit {
        if let timeObserver { observedPlayer?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// "0:12" or "1:02:03".
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
