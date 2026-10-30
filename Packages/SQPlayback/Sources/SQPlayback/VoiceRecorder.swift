import AVFoundation
import Foundation
import Observation
import SQCore

/// The microphone behind `VoiceRecorder`. The app uses `AVMicrophoneCapture`; tests inject a fake, so no test touches a mic.
@MainActor public protocol MicrophoneCapturing: AnyObject {
    /// True when the app may record (asks the system the first time).
    func requestAccess() async -> Bool
    /// Starts writing the microphone to `url` (a file the capture creates).
    func start(to url: URL) throws
    /// Stops and returns the length of what was written, nil when it cannot be read.
    func stop() -> Time?
    /// Seconds recorded so far, for the status line.
    var elapsed: Double { get }
}

public enum VoiceRecorderState: Sendable, Equatable {
    case idle, requestingAccess
    /// Seconds left before recording starts.
    case countdown(Int)
    case recording
}

public enum VoiceRecorderError: Error, Sendable, Equatable {
    case accessDenied, busy, canceled, notRecording, failed
}

/// One finished take: the file, its length and the timeline time it was started at.
public struct VoiceRecording: Sendable, Equatable {
    public var url: URL
    public var duration: Time
    public var anchor: Time
    public init(url: URL, duration: Time, anchor: Time) { self.url = url; self.duration = duration; self.anchor = anchor }
}

/// Records a voice-over: access check, a countdown (3, 2, 1), then the microphone to a file until `stop()`.
/// Knows no timeline; the session decides where the take goes.
@MainActor @Observable
public final class VoiceRecorder {
    public private(set) var state: VoiceRecorderState = .idle { didSet { if state != oldValue { onChange?(state) } } }
    @ObservationIgnored public var onChange: ((VoiceRecorderState) -> Void)?
    @ObservationIgnored private let capture: any MicrophoneCapturing
    @ObservationIgnored private let countdownSeconds: Int
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var current: (url: URL, anchor: Time)?

    public init(capture: any MicrophoneCapturing = AVMicrophoneCapture(), countdown: Int = 3,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.capture = capture
        self.countdownSeconds = max(0, countdown)
        self.sleep = sleep
    }

    public var isBusy: Bool { state != .idle }
    public var elapsed: Double { state == .recording ? capture.elapsed : 0 }

    /// Returns when the microphone is recording. Throws `accessDenied`, `busy`, `canceled` (a `cancel()` came first) or `failed`.
    public func start(to url: URL, anchor: Time) async throws {
        guard state == .idle else { throw VoiceRecorderError.busy }
        generation += 1
        let mine = generation
        state = .requestingAccess
        guard await capture.requestAccess() else {
            if mine == generation { state = .idle }
            throw VoiceRecorderError.accessDenied
        }
        guard mine == generation else { throw VoiceRecorderError.canceled }
        var left = countdownSeconds
        while left > 0 {
            state = .countdown(left)
            do { try await sleep(.seconds(1)) } catch {
                if mine == generation { state = .idle }
                throw VoiceRecorderError.canceled
            }
            guard mine == generation else { throw VoiceRecorderError.canceled }
            left -= 1
        }
        do { try capture.start(to: url) } catch {
            state = .idle
            throw (error as? VoiceRecorderError) ?? VoiceRecorderError.failed
        }
        current = (url, anchor)
        state = .recording
    }

    /// Stops recording and hands back the take.
    public func stop() throws -> VoiceRecording {
        guard state == .recording, let current else { throw VoiceRecorderError.notRecording }
        let length = capture.stop()
        self.current = nil
        state = .idle
        guard let length else {
            try? FileManager.default.removeItem(at: current.url)
            throw VoiceRecorderError.failed
        }
        return VoiceRecording(url: current.url, duration: length, anchor: current.anchor)
    }

    /// Ends a countdown or a recording and drops the file.
    public func cancel() {
        generation += 1
        if state == .recording {
            _ = capture.stop()
            if let current { try? FileManager.default.removeItem(at: current.url) }
        }
        current = nil
        state = .idle
    }
}

/// Microphone to a 48 kHz mono 16-bit WAV file with `AVAudioRecorder` (the system default input).
@MainActor public final class AVMicrophoneCapture: MicrophoneCapturing {
    private var recorder: AVAudioRecorder?
    private var url: URL?

    public init() {}

    public var elapsed: Double { recorder?.currentTime ?? 0 }

    public func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings), r.record() else { throw VoiceRecorderError.failed }
        recorder = r
        self.url = url
    }

    public func stop() -> Time? {
        recorder?.stop()
        recorder = nil
        defer { url = nil }
        guard let url, let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return Time(Int64(file.length), Int64(file.processingFormat.sampleRate))
    }
}
