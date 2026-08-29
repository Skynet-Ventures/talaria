import Foundation
import Observation
#if os(iOS)
import AVFoundation
#endif

// On-device audio for voice mode: microphone capture with level metering and
// voice-activity detection, plus playback of the gateway's synthesized replies.
//
// Capture uses AVAudioRecorder rather than an AVAudioEngine tap: the transcribe
// endpoint wants a *container* (it writes the bytes to a temp file and hands the
// path to the STT provider), and AVAudioRecorder gives AAC-in-m4a plus hardware
// metering for free — an engine tap would mean hand-rolling an AAC encoder for
// no gain. `audio/m4a` is in upstream's accepted MIME map (web_server.py:1582).
//
// macOS compiles a no-op stub: the package builds for macOS 14 so the app can be
// type-checked without Xcode, but voice is a phone surface (and AVAudioSession
// does not exist there).

/// One finished recording, already packaged for POST /api/audio/transcribe.
public struct RecordedClip: Sendable {
    /// `data:audio/m4a;base64,…`
    public var dataURL: String
    public var mimeType: String
    public var duration: TimeInterval

    public init(dataURL: String, mimeType: String, duration: TimeInterval) {
        self.dataURL = dataURL; self.mimeType = mimeType; self.duration = duration
    }
}

public enum MicPermission: Sendable, Equatable {
    case undetermined, granted, denied, unsupported
}

/// Why capture could not start. Kept as a case rather than a sentence so the
/// caller renders it in its own theme voice.
public enum RecorderFailure: Sendable, Equatable {
    /// Another app — or a phone call — owns the input.
    case busy
    /// AVFoundation refused; carries the system's own localized reason.
    case engine(String)
}

/// Why the recorder decided a capture segment was over.
public enum SegmentEnd: Sendable, Equatable {
    /// Speech happened, then trailing silence — the normal end of an utterance.
    case speech
    /// Nothing was said for `quietTimeout`.
    case silence
    /// Hit the hard clip cap.
    case maxDuration
}

// MARK: - Recorder

@MainActor
@Observable
public final class AudioRecorder {
    /// Bars in the voice waveform; the level history is kept at this width so
    /// the view can render it directly.
    public static let barCount = 12

    /// Trailing silence that ends an utterance (desktop's VAD uses the same
    /// order of magnitude — long enough to survive a mid-sentence breath).
    public static let trailingSilence: TimeInterval = 1.4
    /// Give up and re-listen when nothing at all was said.
    public static let quietTimeout: TimeInterval = 10
    /// Hard cap on one clip (25 MB upload limit is far away; this is about
    /// latency, not bytes).
    public static let maxDuration: TimeInterval = 45

    /// Level below which audio counts as room tone rather than speech.
    private static let speechThreshold = 0.18
    private static let tick: TimeInterval = 0.06

    public private(set) var permission: MicPermission = .undetermined
    public private(set) var isRecording = false
    /// Smoothed 0…1 input level.
    public private(set) var level: Double = 0
    /// Rolling level history, oldest → newest, `barCount` wide.
    public private(set) var levels: [Double] = Array(repeating: 0, count: AudioRecorder.barCount)
    /// True once this segment contained something loud enough to be speech.
    public private(set) var heardSpeech = false
    /// Set when capture fails for a reason worth showing the user.
    public private(set) var failure: RecorderFailure?

    /// Fired on the main actor when a segment ends; the clip stays open until
    /// the owner calls `stop()`.
    public var onSegmentEnd: ((SegmentEnd) -> Void)?

    public init() {
        #if os(iOS)
        permission = Self.currentPermission()
        #else
        permission = .unsupported
        #endif
    }

    /// False where there is no microphone path at all (macOS build).
    public var isSupported: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    #if os(iOS)

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var silence: TimeInterval = 0
    @ObservationIgnored private var quiet: TimeInterval = 0
    @ObservationIgnored private var ended = false

    private static func currentPermission() -> MicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    /// Ask once; returns the settled state. A denied mic is terminal until the
    /// user changes it in Settings, so callers show a themed dead end rather
    /// than re-prompting.
    @discardableResult
    public func ensurePermission() async -> MicPermission {
        let current = Self.currentPermission()
        guard current == .undetermined else {
            permission = current
            return current
        }
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        permission = granted ? .granted : .denied
        return permission
    }

    /// Begin one capture segment. Safe to call while already recording (no-op).
    public func start() {
        guard !isRecording, permission == .granted else { return }
        failure = nil
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            try VoiceAudioSession.activate()
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                failure = .busy
                return
            }
            self.recorder = recorder
            self.fileURL = url
        } catch {
            failure = .engine(error.localizedDescription)
            return
        }
        isRecording = true
        heardSpeech = false
        ended = false
        silence = 0
        quiet = 0
        level = 0
        levels = Array(repeating: 0, count: Self.barCount)
        startMetering()
    }

    /// Stop and package the clip. Returns nil when nothing usable was captured
    /// (too short, or no speech at all) — the caller just listens again.
    @discardableResult
    public func stop() -> RecordedClip? {
        guard let recorder, let fileURL else {
            teardown()
            return nil
        }
        let duration = recorder.currentTime
        let spoke = heardSpeech
        recorder.stop()
        teardown()

        defer { try? FileManager.default.removeItem(at: fileURL) }
        // A tap-length blip is never speech; sending it burns a provider call
        // and comes back empty anyway.
        guard spoke, duration >= 0.4,
              let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        return RecordedClip(dataURL: "data:audio/m4a;base64,\(data.base64EncodedString())",
                            mimeType: "audio/m4a",
                            duration: duration)
    }

    /// Drop the segment without producing a clip (mute, dismissal, barge-in).
    public func cancel() {
        let url = fileURL
        recorder?.stop()
        teardown()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func teardown() {
        meterTask?.cancel()
        meterTask = nil
        recorder = nil
        fileURL = nil
        isRecording = false
        level = 0
        levels = Array(repeating: 0, count: Self.barCount)
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tick))
                guard let self, self.isRecording else { return }
                self.sample()
            }
        }
    }

    private func sample() {
        guard let recorder else { return }
        recorder.updateMeters()
        let value = Self.normalize(Double(recorder.averagePower(forChannel: 0)))
        // Light smoothing: the raw meter jitters hard enough to look like noise
        // on a 12-bar display.
        level = level * 0.45 + value * 0.55
        levels.removeFirst()
        levels.append(level)

        if value >= Self.speechThreshold {
            heardSpeech = true
            silence = 0
        } else if heardSpeech {
            silence += Self.tick
        } else {
            quiet += Self.tick
        }

        guard !ended else { return }
        if heardSpeech, silence >= Self.trailingSilence {
            ended = true
            onSegmentEnd?(.speech)
        } else if !heardSpeech, quiet >= Self.quietTimeout {
            ended = true
            onSegmentEnd?(.silence)
        } else if recorder.currentTime >= Self.maxDuration {
            ended = true
            onSegmentEnd?(.maxDuration)
        }
    }

    /// dBFS → 0…1 over a 50 dB window. Linear amplitude would leave speech
    /// pinned near zero; a dB window tracks what the ear (and the prototype's
    /// waveform) expects.
    private static func normalize(_ db: Double) -> Double {
        let floorDB = -50.0
        guard db.isFinite else { return 0 }
        return max(0, min(1, (db - floorDB) / -floorDB))
    }

    #else

    // macOS: the whole surface compiles, nothing records.
    @discardableResult
    public func ensurePermission() async -> MicPermission { .unsupported }
    public func start() {}
    @discardableResult
    public func stop() -> RecordedClip? { nil }
    public func cancel() {}

    #endif
}

// MARK: - Playback

/// Plays the gateway's synthesized replies and exposes the same 0…1 level
/// shape as the recorder, so the waveform keeps moving while the bot talks.
@MainActor
@Observable
public final class VoicePlayer {
    public private(set) var isPlaying = false
    public private(set) var level: Double = 0
    public private(set) var levels: [Double] = Array(repeating: 0,
                                                     count: AudioRecorder.barCount)

    public init() {}

    #if os(iOS)

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var finished: CheckedContinuation<Void, Never>?

    /// Play to completion. Returns early (and quietly) if `stop()` interrupts —
    /// barge-in and "end call" both need playback to unwind without throwing.
    @discardableResult
    public func play(_ audio: Data) async -> Bool {
        stop()
        do {
            try VoiceAudioSession.activate()
            let player = try AVAudioPlayer(data: audio)
            player.isMeteringEnabled = true
            player.prepareToPlay()
            guard player.play() else { return false }
            self.player = player
        } catch {
            return false
        }
        isPlaying = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finished = cont
            meterTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(0.06))
                    guard let self, let player = self.player else { return }
                    guard player.isPlaying else {
                        self.stop()
                        return
                    }
                    player.updateMeters()
                    let value = Self.normalize(Double(player.averagePower(forChannel: 0)))
                    self.level = self.level * 0.45 + value * 0.55
                    self.levels.removeFirst()
                    self.levels.append(self.level)
                }
            }
        }
        return true
    }

    public func stop() {
        meterTask?.cancel()
        meterTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        level = 0
        levels = Array(repeating: 0, count: AudioRecorder.barCount)
        finished?.resume()
        finished = nil
    }

    private static func normalize(_ db: Double) -> Double {
        let floorDB = -45.0
        guard db.isFinite else { return 0 }
        return max(0, min(1, (db - floorDB) / -floorDB))
    }

    #else

    @discardableResult
    public func play(_ audio: Data) async -> Bool { false }
    public func stop() {}

    #endif
}

// MARK: - Session

/// One place that owns the AVAudioSession category, so record and playback do
/// not fight over it mid-conversation.
public enum VoiceAudioSession {
    #if os(iOS)
    /// `.playAndRecord` + `.voiceChat` keeps the mic and the speaker live in the
    /// same breath and turns on the hardware echo canceller, which is what makes
    /// speaking over a reply survivable. `.defaultToSpeaker` keeps the reply out
    /// of the earpiece when the phone is on a table.
    public static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord || session.mode != .voiceChat {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        }
        try session.setActive(true)
    }

    public static func deactivate() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }
    #else
    public static func activate() throws {}
    public static func deactivate() {}
    #endif
}
