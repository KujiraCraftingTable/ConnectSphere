import SwiftUI
import AVFoundation

/// Recording lifecycle for the chat composer's voice messages, modelled on
/// Messenger: record → stop → review (listen back) → send or delete. Sending
/// straight from recording is allowed too. One instance is held by `ChatView`
/// and shared by `VoiceRecorderControl` (the idle mic), `VoiceComposerBar`
/// (the recording/review pill) and `ChatView`'s send button, which calls
/// `finalizeAndSend(onFinish:)`.
@MainActor
@Observable
final class VoiceRecordingSession {
    enum State: Equatable { case idle, recording, reviewing }

    private(set) var state: State = .idle
    /// Seconds recorded so far while recording; the final length in review.
    private(set) var elapsedSeconds: Int = 0
    /// Most recent meter readings (0...1), newest last. Drives the live,
    /// scrolling bars while recording.
    private(set) var liveLevels: [CGFloat] = []
    /// The fixed-length waveform that will be sent, shown during review.
    private(set) var reviewWaveform: [Float] = []
    private(set) var isPlaying = false
    /// Review playback position, 0...1.
    private(set) var playbackProgress: Double = 0
    var showPermissionAlert = false

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var fileURL: URL?
    private var meterTimer: Timer?
    private var playbackTimer: Timer?
    private var powerSamples: [Float] = []

    /// Enough live bars to fill the pill on any iPhone; extras are clipped.
    static let liveLevelCapacity = 60
    /// Fixed sample count the sent waveform is downsampled to. Matches what
    /// `MessageBubble.voiceBubble` renders.
    private static let waveformBarCount = 40
    /// Shorter recordings are treated as an accidental tap and discarded.
    private static let minimumDuration: TimeInterval = 1

    /// The timer's value: elapsed while recording, remaining while playing
    /// back, full length otherwise.
    var displaySeconds: Int {
        guard state == .reviewing, isPlaying else { return elapsedSeconds }
        return Int((Double(elapsedSeconds) * (1 - playbackProgress)).rounded(.up))
    }

    // MARK: - Recording

    func start() {
        guard state == .idle else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
        } catch {
            // No mic hardware / session conflict. Fail silently, same as a no-op tap.
            return
        }
        session.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.beginRecording()
                } else {
                    self.showPermissionAlert = true
                }
            }
        }
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1
        ]
        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.isMeteringEnabled = true
            guard newRecorder.record() else { return }
            recorder = newRecorder
            fileURL = url
            powerSamples = []
            liveLevels = []
            elapsedSeconds = 0
            state = .recording
            startMeterTimer()
        } catch {
            recorder = nil
        }
    }

    /// Stops recording and moves to review. A recording under a second is
    /// discarded instead, almost always a mis-tap on the mic.
    func stop() {
        guard state == .recording, let recorder else { return }
        let length = recorder.currentTime
        recorder.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        self.recorder = nil
        guard length >= Self.minimumDuration else {
            cancel()
            return
        }
        elapsedSeconds = Int(length.rounded())
        reviewWaveform = Self.downsample(powerSamples, to: Self.waveformBarCount)
        playbackProgress = 0
        state = .reviewing
    }

    // MARK: - Review playback

    func togglePlayback() {
        guard state == .reviewing, let fileURL else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
            playbackTimer?.invalidate()
            return
        }
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: fileURL)
            player?.prepareToPlay()
        }
        guard let player else { return }
        if playbackProgress >= 1 { player.currentTime = 0 }
        player.play()
        isPlaying = true
        startPlaybackTimer()
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                if player.isPlaying {
                    self.playbackProgress = player.duration > 0 ? player.currentTime / player.duration : 0
                } else {
                    // Reached the end. Reset so the next tap replays from the start.
                    self.isPlaying = false
                    self.playbackProgress = 0
                    self.playbackTimer?.invalidate()
                }
            }
        }
    }

    // MARK: - Finish

    /// Discards the recording from any state and deletes the file.
    func cancel() {
        let url = fileURL
        recorder?.stop()
        teardown()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Hands the recording to `onFinish` (temp file URL, whole seconds,
    /// 40-point normalized waveform). From review, or straight from
    /// recording. The caller uploads it and deletes the temp file afterwards.
    func finalizeAndSend(onFinish: (URL, Int, [Float]) -> Void) {
        if state == .recording { stop() }
        guard state == .reviewing, let fileURL else { return }
        let duration = elapsedSeconds
        let waveform = reviewWaveform
        teardown()
        onFinish(fileURL, duration, waveform)
    }

    private func teardown() {
        meterTimer?.invalidate()
        meterTimer = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        player?.stop()
        player = nil
        recorder = nil
        fileURL = nil
        isPlaying = false
        playbackProgress = 0
        elapsedSeconds = 0
        liveLevels = []
        reviewWaveform = []
        powerSamples = []
        state = .idle
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder, self.state == .recording else { return }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)
                // dB is nominally -160...0; a linear map over the practical
                // -50...0 speech range is plenty for a waveform sketch.
                let normalized = max(0, min(1, (db + 50) / 50))
                self.powerSamples.append(normalized)
                self.liveLevels.append(CGFloat(normalized))
                if self.liveLevels.count > Self.liveLevelCapacity {
                    self.liveLevels.removeFirst(self.liveLevels.count - Self.liveLevelCapacity)
                }
                self.elapsedSeconds = Int(recorder.currentTime)
            }
        }
    }

    /// Buckets `samples` into exactly `count` evenly-spaced groups, averaging
    /// each group, so a 3-second and a 30-second recording both end up as
    /// the same fixed-length waveform array.
    private static func downsample(_ samples: [Float], to count: Int) -> [Float] {
        guard !samples.isEmpty else { return Array(repeating: Float(0.1), count: count) }
        guard samples.count >= count else {
            // Too few readings to fill every bucket. Stretch by nearest
            // sample instead of leaving trailing zeros.
            return (0..<count).map { i in
                let idx = min(Int(Double(i) / Double(count) * Double(samples.count)), samples.count - 1)
                return samples[idx]
            }
        }
        let bucketSize = Double(samples.count) / Double(count)
        return (0..<count).map { i in
            let start = Int(Double(i) * bucketSize)
            let end = max(start + 1, min(samples.count, Int(Double(i + 1) * bucketSize)))
            let slice = samples[start..<end]
            return slice.isEmpty ? 0 : slice.reduce(0, +) / Float(slice.count)
        }
    }
}

/// The composer's mic button, shown while idle; tapping it starts recording.
struct VoiceRecorderControl: View {
    let session: VoiceRecordingSession
    let tint: Color

    @Environment(\.appBundle) private var bundle

    var body: some View {
        Button {
            session.start()
        } label: {
            Image(systemName: "mic")
                .scaledFont(26)
                .foregroundColor(tint)
                .padding(.bottom, 6)
        }
        .accessibilityLabel(Text("Record voice message", bundle: bundle))
        .alert(Text("Microphone access needed", bundle: bundle), isPresented: Binding(
            get: { session.showPermissionAlert },
            set: { session.showPermissionAlert = $0 }
        )) {
            Button {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            } label: {
                Text("Open Settings", bundle: bundle)
            }
            Button(role: .cancel) {
            } label: {
                Text("Cancel", bundle: bundle)
            }
        } message: {
            Text("Please allow microphone access in Settings to send voice messages.", bundle: bundle)
        }
    }
}

/// Messenger-style voice pill that replaces the text field while recording
/// or reviewing:
///
///     [🗑]  ( ■ │ live bars              │ 0:06 )     recording
///     [🗑]  ( ▶ │ played / unplayed bars │ 0:06 )     review
///
/// Filled with the conversation's own primary color and drawn white-on-tint,
/// so it reads as the composer's single focus and works in light and dark
/// mode without extra tokens. Sending stays with `ChatView`'s send button.
struct VoiceComposerBar: View {
    let session: VoiceRecordingSession
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    var body: some View {
        HStack(spacing: 4) {
            Button {
                session.cancel()
            } label: {
                Image(systemName: "trash")
                    .scaledFont(19, .medium)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Delete recording", bundle: bundle))

            HStack(spacing: 6) {
                primaryControl
                waveform
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .accessibilityHidden(true)
                timer
            }
            .padding(.trailing, 8)
            .background(tint, in: Capsule())
        }
    }

    // MARK: - Pieces

    private var primaryControl: some View {
        Button {
            if session.state == .recording {
                session.stop()
            } else {
                session.togglePlayback()
            }
        } label: {
            Image(systemName: controlIcon)
                .scaledFont(12, .bold)
                .foregroundColor(tint)
                .frame(width: 30, height: 30)
                .background(Color.white, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(controlLabel, bundle: bundle))
    }

    private var timer: some View {
        Text(Self.clock(session.displaySeconds))
            .scaledFont(13, .semibold)
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.22), in: Capsule())
            .accessibilityLabel(Text(Duration.seconds(session.displaySeconds)
                .formatted(.units(allowed: [.minutes, .seconds], width: .wide))))
    }

    /// Recording: the newest levels, right-aligned so bars enter on the right
    /// and scroll left. Review: the 40-bar waveform being sent, filled white
    /// up to the playback position.
    private var waveform: some View {
        let isRecording = session.state == .recording
        let levels: [CGFloat] = isRecording
            ? session.liveLevels
            : session.reviewWaveform.map { CGFloat($0) }
        let progress = session.playbackProgress
        return Canvas { context, size in
            let gap: CGFloat = 2
            if isRecording {
                let barWidth: CGFloat = 3
                let fit = max(1, Int((size.width + gap) / (barWidth + gap)))
                let shown = levels.suffix(fit)
                var x = size.width - barWidth
                for level in shown.reversed() {
                    Self.drawBar(in: &context, x: x, width: barWidth, level: level,
                                 height: size.height, color: .white)
                    x -= barWidth + gap
                }
            } else {
                guard !levels.isEmpty else { return }
                let step = size.width / CGFloat(levels.count)
                let barWidth = max(1.5, step - gap)
                let played = Int((progress * Double(levels.count)).rounded())
                for (i, level) in levels.enumerated() {
                    Self.drawBar(in: &context, x: CGFloat(i) * step, width: barWidth, level: level,
                                 height: size.height,
                                 color: i < played ? .white : .white.opacity(0.45))
                }
            }
        }
    }

    /// `nonisolated`: called from `Canvas`'s renderer, outside the main actor
    /// this project isolates types to by default.
    nonisolated private static func drawBar(in context: inout GraphicsContext, x: CGFloat, width: CGFloat,
                                level: CGFloat, height: CGFloat, color: Color) {
        let barHeight = max(3, level * height)
        let rect = CGRect(x: x, y: (height - barHeight) / 2, width: width, height: barHeight)
        context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color))
    }

    private var controlIcon: String {
        switch session.state {
        case .recording: return "stop.fill"
        default:         return session.isPlaying ? "pause.fill" : "play.fill"
        }
    }

    private var controlLabel: LocalizedStringKey {
        switch session.state {
        case .recording: return "Stop recording"
        default:         return session.isPlaying ? "Pause playback" : "Play recording"
        }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
