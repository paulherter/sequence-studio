import Testing
import Foundation
import CoreVideo
import SQCore
@testable import SQExport

/// Export first frame (PLAYBACK-PERF "Export: first frame overlaps the writer start"): frame 0 is asked for before the
/// writer starts and before the loudness pass, so its cold open and seek overlap that work instead of following it.
@Suite struct FirstFramePrefetchTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Test pattern that raises `asked` when frame 0 is requested.
    struct WatchedSource: FrameSource {
        let inner: TestPatternSource
        let asked: Flag
        var frameCount: Int { inner.frameCount }
        var frameDuration: Time { inner.frameDuration }
        func frame(at index: Int) async throws -> CVPixelBuffer {
            if index == 0 { asked.set() }
            return try await inner.frame(at: index)
        }
    }

    /// Silence; the first read waits (up to 5 s) for frame 0 to be asked for and records whether it was.
    final class WaitingAudio: RewindableAudioSource, @unchecked Sendable {
        let sampleRate = 48_000, channels = 2
        let total = 48_000
        let asked: Flag
        let sawFrameZero = Flag()
        private let lock = NSLock()
        private var position = 0, waited = false
        init(asked: Flag) { self.asked = asked }
        func rewind() async throws { lock.withLock { position = 0 } }
        func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
            if !lock.withLock({ let w = waited; waited = true; return w }) {
                let deadline = ContinuousClock.now + .seconds(5)
                while !asked.isSet, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
                if asked.isSet { sawFrameZero.set() }
            }
            return lock.withLock {
                let n = min(maxFrames, total - position)
                guard n > 0 else { return nil }
                position += n
                return AudioChunk(samples: [Float](repeating: 0, count: n * channels), channels: channels)
            }
        }
    }

    @Test func firstFrameIsAskedForDuringTheLoudnessPass() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-firstframe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = smallSettings(codec: .h264, width: 64, height: 32)
        s.audio.enabled = true
        s.audio.loudness = LoudnessNormalization()
        let asked = Flag()
        let audio = WaitingAudio(asked: asked)
        let video = WatchedSource(inner: TestPatternSource(width: 64, height: 32, frameCount: 30, frameDuration: Time(1, 30)),
                                  asked: asked)
        let url = dir.appendingPathComponent("out.mp4")
        try await ExportWriter.export(video: video, audio: audio, settings: s, to: url, segments: 1) { _ in }
        #expect(audio.sawFrameZero.isSet)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
