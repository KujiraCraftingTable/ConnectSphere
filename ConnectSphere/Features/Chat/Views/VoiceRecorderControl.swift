import SwiftUI
import AVFoundation

/// Recording lifecycle + state for the chat composer's voice-message flow —
/// owns the `AVAudioRecorder`, live level metering, and pause-aware elapsed
/// time. One instance is created and held by `ChatView` and shared (by
/// reference) between `VoiceRecorderControl` (the mic/pause-resume tap
/// target) and `VoiceRecordingBar` (the transformed row), plus `ChatView`'s
/// own trailing send button — tapping send while recording/paused calls
/// `finalizeAndSend(onFinish:)` the same way it calls `sendPending()` for
/// text/picked media.
@MainActor
@Observable
final class VoiceRecordingSession {
    enum State: Equatable { case idle, recording, paused }

    private(set) var state: State = .idle
    /// Pause-aware — NOT wall-clock time since start (`AVAudioRecorder.
    /// currentTime`'s behavior across a pause isn't something to rely on
    /// without live testing, so this is tracked independently via
    /// `accumulatedSeconds` + `segmentStartedAt`).
    private(set) var elapsedSeconds: Int = 0
    private(set) var currentLevel: CGFloat = 0
    var showPermissionAlert = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var accumulatedSeconds: Int = 0
    private var segmentStartedAt: Date?
    private var powerSamples: [Float] = []

    /// Fixed sample count the waveform is downsampled to on finalize —
    /// matches what `MessageBubble.voiceBubble` expects/renders.
    private static let waveformBarCount = 40
    /// Recordings shorter than this are treated as an accidental tap and
    /// discarded rather than finalized as a near-empty voice message.
    private static let minimumDurationSeconds = 1

    // MARK: - Lifecycle

    func start() {
        guard state == .idle else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
        } catch {
            // No mic hardware / session conflict — fail silently, same as a no-op tap.
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
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1
        ]
        do {
            let newRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            newRecorder.isMeteringEnabled = true
            guard newRecorder.record() else { return }
            recorder = newRecorder
            accumulatedSeconds = 0
            segmentStartedAt = Date()
            powerSamples = []
            elapsedSeconds = 0
            state = .recording
            startMeterTimer()
        } catch {
            recorder = nil
        }
    }

    /// Toggles between recording and paused — resume appends to the SAME
    /// file (no data loss, no new file), per `AVAudioRecorder.record()`'s
    /// documented resume-after-pause behavior.
    func togglePauseResume() {
        guard recorder != nil else { return }
        switch state {
        case .recording:
            if let segmentStartedAt {
                accumulatedSeconds += Int(Date().timeIntervalSince(segmentStartedAt))
            }
            segmentStartedAt = nil
            recorder?.pause()
            state = .paused
        case .paused:
            segmentStartedAt = Date()
            recorder?.record()
            state = .recording
        case .idle:
            break
        }
    }

    /// Discards the in-progress recording entirely — back to `.idle`, no
    /// callback fires. The only way out of recording mode without sending.
    func cancel() {
        guard let recorder else { return }
        let fileURL = recorder.url
        recorder.stop()
        teardown()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Stops and finalizes the recording, invoking `onFinish` with the temp
    /// file URL, integer duration, and a 40-point normalized waveform — same
    /// shape the old tap-to-stop callback delivered. The caller owns
    /// uploading/sending it and cleaning up the temp file afterward. Valid
    /// while `.recording` OR `.paused` — sending doesn't require resuming first.
    func finalizeAndSend(onFinish: (URL, Int, [Float]) -> Void) {
        guard let recorder else { return }
        let fileURL = recorder.url
        if state == .recording, let segmentStartedAt {
            accumulatedSeconds += Int(Date().timeIntervalSince(segmentStartedAt))
        }
        let duration = accumulatedSeconds
        recorder.stop()
        let waveform = Self.downsample(powerSamples, to: Self.waveformBarCount)
        teardown()

        guard duration >= Self.minimumDurationSeconds else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        onFinish(fileURL, duration, waveform)
    }

    private func teardown() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        segmentStartedAt = nil
        accumulatedSeconds = 0
        elapsedSeconds = 0
        currentLevel = 0
        powerSamples = []
        state = .idle
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let recorder = self.recorder, self.state == .recording else { return }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)
                // Normalize dB (nominally -160...0) to a 0.0-1.0 float — a
                // plain linear map over a practical -50...0 speech range is
                // enough here, this only drives a waveform sketch.
                let normalized = max(0, min(1, (db + 50) / 50))
                self.powerSamples.append(normalized)
                self.currentLevel = CGFloat(normalized)
                if let segmentStartedAt = self.segmentStartedAt {
                    self.elapsedSeconds = self.accumulatedSeconds + Int(Date().timeIntervalSince(segmentStartedAt))
                }
            }
        }
    }

    /// Buckets `samples` into exactly `count` evenly-spaced groups, averaging
    /// each group — regardless of how many raw ~100ms readings were
    /// collected, so a 3-second and a 30-second recording both end up as the
    /// same fixed-length waveform array.
    private static func downsample(_ samples: [Float], to count: Int) -> [Float] {
        guard !samples.isEmpty else { return Array(repeating: Float(0.1), count: count) }
        guard samples.count >= count else {
            // Too few raw readings (a very short recording) to fill every
            // bucket — stretch by nearest-sample lookup instead of leaving
            // trailing zeros.
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

/// Mic (idle) / pause-resume (recording or paused) tap target for the chat
/// composer. Positioned before the text field when idle, and after
/// `VoiceRecordingBar` once recording starts — see `ChatView.inputBar`.
struct VoiceRecorderControl: View {
    let session: VoiceRecordingSession
    let tint: Color

    @Environment(\.appBundle) private var bundle

    var body: some View {
        Button {
            switch session.state {
            case .idle:                  session.start()
            case .recording, .paused:    session.togglePauseResume()
            }
        } label: {
            ZStack {
                if session.state == .recording {
                    Circle()
                        .fill(Color.red.opacity(0.22))
                        .frame(width: 34, height: 34)
                        .scaleEffect(1 + session.currentLevel * 0.6)
                        .animation(.easeOut(duration: 0.1), value: session.currentLevel)
                }
                Image(systemName: iconName)
                    .font(.system(size: 22))
                    .foregroundColor(session.state == .idle ? tint : .red)
            }
            .padding(.bottom, 6)
        }
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

    private var iconName: String {
        switch session.state {
        case .idle:      return "mic"
        case .recording: return "pause.fill"
        case .paused:    return "play.fill"
        }
    }
}

/// Replaces the text field while `session.state != .idle` — a live mm:ss
/// timer + a level-reactive pulse (driven by the same power samples behind
/// the mic button's own pulse) + a cancel button, so the row visibly reads
/// as "recording a voice message" instead of looking like a stalled text
/// field. Cancel is the only way to back out without sending.
struct VoiceRecordingBar: View {
    let session: VoiceRecordingSession

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    var body: some View {
        HStack(spacing: 10) {
            Button {
                session.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            .buttonStyle(.plain)

            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(session.state == .recording ? 1 : 0.3)
                .scaleEffect(session.state == .recording ? 1 + session.currentLevel * 0.5 : 1)
                .animation(.easeOut(duration: 0.15), value: session.currentLevel)

            Text(timeString)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .monospacedDigit()

            if session.state == .paused {
                Text("Paused", bundle: bundle)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(AppColors.borderStrong(colorScheme), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }

    private var timeString: String {
        let m = session.elapsedSeconds / 60
        let s = session.elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
