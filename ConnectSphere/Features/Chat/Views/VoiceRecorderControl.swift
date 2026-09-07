import SwiftUI
import AVFoundation

/// Tap-to-start / tap-to-stop mic button for the chat composer (per the
/// product decision: NOT press-and-hold). Owns the whole recording
/// lifecycle: mic permission, an `AVAudioRecorder` writing AAC-in-`.m4a` to
/// a temp file, and a live power-level sample used both to animate a small
/// level indicator while recording and — downsampled to a fixed 40-point
/// array on stop — as the `voiceWaveform` sent with the message. Waveform
/// samples are captured once here, client-side, so every viewer later
/// renders the identical shape (see `MessageBubble.voiceBubble`) with no
/// server-side audio analysis.
struct VoiceRecorderControl: View {
    let tint: Color
    /// Called once recording stops with a usable result: the temp file URL,
    /// integer duration in seconds, and a 40-point normalized (0.0-1.0)
    /// waveform. The caller (`ChatView`) owns uploading/sending it and
    /// cleaning up the temp file afterward.
    let onFinishRecording: (URL, Int, [Float]) -> Void

    @Environment(\.appBundle) private var bundle
    @State private var isRecording = false
    @State private var recorder: AVAudioRecorder?
    @State private var meterTimer: Timer?
    @State private var recordingStartedAt: Date?
    @State private var powerSamples: [Float] = []
    @State private var currentLevel: CGFloat = 0
    @State private var showPermissionAlert = false

    /// Fixed sample count the waveform is downsampled to on stop — matches
    /// what `MessageBubble.voiceBubble` expects/renders.
    private static let waveformBarCount = 40
    /// Recordings shorter than this are treated as an accidental tap and
    /// discarded rather than sent as a near-empty voice message.
    private static let minimumDurationSeconds = 1

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            ZStack {
                if isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.22))
                        .frame(width: 34, height: 34)
                        .scaleEffect(1 + currentLevel * 0.6)
                        .animation(.easeOut(duration: 0.1), value: currentLevel)
                }
                Image(systemName: isRecording ? "stop.circle.fill" : "mic")
                    .font(.system(size: 22))
                    .foregroundColor(isRecording ? .red : tint)
            }
            .padding(.bottom, 6)
        }
        .alert(Text("Microphone access needed", bundle: bundle), isPresented: $showPermissionAlert) {
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

    // MARK: - Recording lifecycle

    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
        } catch {
            // No mic hardware / session conflict — fail silently, same as a no-op tap.
            return
        }
        session.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    beginRecording()
                } else {
                    showPermissionAlert = true
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
            recordingStartedAt = Date()
            powerSamples = []
            isRecording = true
            startMeterTimer()
        } catch {
            recorder = nil
        }
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let recorder else { return }
            recorder.updateMeters()
            let db = recorder.averagePower(forChannel: 0)
            // Normalize dB (nominally -160...0) to a 0.0-1.0 float. A plain
            // linear map over a practical -50...0 speech range is enough
            // here — this only drives a waveform sketch, not a scientific
            // loudness measurement, so anything quieter than -50dB just
            // floors to 0.
            let normalized = max(0, min(1, (db + 50) / 50))
            powerSamples.append(normalized)
            currentLevel = CGFloat(normalized)
        }
    }

    private func stopRecording() {
        guard let recorder else { return }
        let fileURL = recorder.url
        let duration = Int(recordingStartedAt.map { Date().timeIntervalSince($0) } ?? recorder.currentTime)
        recorder.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        isRecording = false
        currentLevel = 0
        let waveform = Self.downsample(powerSamples, to: Self.waveformBarCount)
        self.recorder = nil
        powerSamples = []

        guard duration >= Self.minimumDurationSeconds else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        onFinishRecording(fileURL, duration, waveform)
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
