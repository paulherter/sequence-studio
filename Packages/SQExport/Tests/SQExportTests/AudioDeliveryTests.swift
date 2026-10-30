import Testing
import AVFoundation
import Foundation
import SQCore
@testable import SQExport

/// Interleaved samples from a closure of (frame, channel).
private final class ShapedAudio: RewindableAudioSource, @unchecked Sendable {
    let sampleRate = 48_000
    let channels: Int
    let total: Int
    let sample: @Sendable (Int, Int) -> Float
    private var pos = 0
    init(channels: Int = 2, seconds: Int, sample: @escaping @Sendable (Int, Int) -> Float) {
        self.channels = channels; total = seconds * 48_000; self.sample = sample
    }
    func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
        let n = min(maxFrames, total - pos)
        guard n > 0 else { return nil }
        var out = [Float](repeating: 0, count: n * channels)
        for i in 0..<n { for c in 0..<channels { out[i * channels + c] = sample(pos + i, c) } }
        pos += n
        return AudioChunk(samples: out, channels: channels)
    }
    func rewind() async throws { pos = 0 }
}

private func tone(_ i: Int, _ amp: Float) -> Float { Float(sin(2 * Double.pi * Double(i % 48_000 * 440 % 48_000) / 48_000)) * amp }

@Suite struct AudioDeliveryTests {
    private let target = LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1)

    @Test func cleanToneHasNoFindingsExceptLevel() async throws {
        let s = ShapedAudio(seconds: 3) { i, c in tone(i, 0.2) * (c == 0 ? 1 : 0.5) }
        let a = try await AudioPreflight.analyze(s)
        #expect(a.clippedSamples == 0 && a.gapCount == 0 && !a.isDualMono && !a.isSilent)
        #expect(abs(a.durationSeconds - 3) < 0.01)
        let f = AudioPreflight.evaluate(a, target: target, normalizing: false)
        #expect(f.first { $0.kind == .clipping }?.severity == .pass)
        #expect(f.first { $0.kind == .loudness }?.severity == .fail) // far below -14 LUFS
        let n = AudioPreflight.evaluate(a, target: target, normalizing: true)
        #expect(n.first { $0.kind == .loudness }?.severity == .pass)
    }

    @Test func loudnessRangeIsMeasuredAndListed() async throws {
        let s = ShapedAudio(seconds: 20) { i, _ in tone(i, i < 10 * 48_000 ? 0.02 : 0.0632) }   // +10 dB step
        let a = try await AudioPreflight.analyze(s)
        #expect(abs((a.loudnessRangeLU ?? 0) - 10) < 0.5)
        let f = AudioPreflight.evaluate(a, target: target, normalizing: false)
        #expect(f.first { $0.kind == .loudnessRange }?.message.hasPrefix("Loudness range") == true)
    }

    @Test func clippingGapAndDualMonoAreFound() async throws {
        // 1 s tone at full scale, 2 s silence, 1 s tone: identical channels.
        let s = ShapedAudio(seconds: 4) { i, _ in (i < 48_000 || i >= 144_000) ? (i % 2 == 0 ? 1.0 : -1.0) : 0 }
        let a = try await AudioPreflight.analyze(s)
        #expect(a.clippedSamples > 0)
        #expect(a.gapCount == 1)
        #expect(abs(a.longestGapSeconds - 2) < 0.01)
        #expect(a.isDualMono)
        let f = AudioPreflight.evaluate(a, target: target, normalizing: true, unsyncedClips: 2)
        #expect(f.first { $0.kind == .clipping }?.severity == .fail)
        #expect(f.first { $0.kind == .gaps }?.severity == .warning)
        #expect(f.first { $0.kind == .dualMono }?.severity == .warning)
        #expect(f.first { $0.kind == .unsynced }?.severity == .warning)
    }

    @Test func silentMixFails() async throws {
        let a = try await AudioPreflight.analyze(ShapedAudio(seconds: 2) { _, _ in 0 })
        #expect(a.isSilent)
        let f = AudioPreflight.evaluate(a, target: target, normalizing: false)
        #expect(f.first?.kind == .silent && f.first?.severity == .fail)
    }

    @Test func audioOnlyPresetsAndSettings() {
        let m4a = ExportPreset.audioM4A.settings
        #expect(m4a.audioOnly == .m4a && m4a.fileExtension == "m4a" && m4a.validate().isEmpty)
        let wav = ExportPreset.audioWAV.settings
        #expect(wav.audioOnly == .wav && wav.effectiveAudio.codec == .pcm && wav.fileExtension == "wav")
        var burn = m4a; burn.captions = .burnIn; burn.coverImage = .jpg
        #expect(burn.forDelivery.captions == .none && burn.forDelivery.coverImage == nil)
    }

    @Test func oldSettingsDecodeWithoutAudioOnly() throws {
        let data = try JSONEncoder().encode(ExportSettings())
        #expect(!String(decoding: data, as: UTF8.self).contains("audioOnly"))
        #expect(try JSONDecoder().decode(ExportSettings.self, from: data).audioOnly == nil)
    }

    @Test func audioOnlyM4AExportIsNormalizedAndVerified() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.m4a")
        var s = ExportPreset.audioM4A.settings
        s.video.frameDuration = Time(1, 30)
        s.audio.loudness = target
        let v = TestPatternSource(width: 64, height: 112, frameCount: 90, frameDuration: Time(1, 30))
        let a = ShapedAudio(seconds: 3) { i, c in tone(i, 0.1) }
        let r = try await ExportWriter.export(video: v, audio: a, settings: s, to: url, progress: { _ in })
        let report = try #require(r)
        let verified = try #require(report.verified)
        #expect(abs(verified.integratedLUFS - -14) < 1.0)
        #expect(verified.truePeakDB <= -1 + LoudnessReport.verifyToleranceDB + 0.001)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func audioOnlyWAVExportHasNoPicture() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.wav")
        let s = ExportPreset.audioWAV.settings
        let v = TestPatternSource(width: 64, height: 112, frameCount: 30, frameDuration: Time(1, 30))
        let a = SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(1, 1))
        try await ExportWriter.export(video: v, audio: a, settings: s, to: url, progress: { _ in })
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(abs(try await track.load(.timeRange).duration.seconds - 1) < 0.1)
    }

    @Test func audioOnlyWithoutAudioThrows() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let v = TestPatternSource(width: 64, height: 112, frameCount: 30, frameDuration: Time(1, 30))
        await #expect(throws: ExportError.self) {
            try await ExportWriter.export(video: v, audio: nil, settings: ExportPreset.audioWAV.settings,
                                          to: dir.appendingPathComponent("x.wav"), progress: { _ in })
        }
    }

    @Test func preferencesRoundTripAndApply() throws {
        var s = ExportPreset.default.settings
        s.captions = .sidecarSRT; s.coverImage = .jpg; s.continueOnDamagedFrames = true
        s.audio.loudness = target
        let p = ExportPreferences(presetID: ExportPreset.youtube1080.id, settings: s, exportAllFormats: true)
        #expect(p.customVideo == nil)
        let back = try #require(ExportPreferences.decode(p.encoded()))
        #expect(back == p && back.preset == .youtube1080)
        var fresh = ExportPreset.youtube1080.settings
        back.apply(to: &fresh, loudness: LoudnessNormalization(targetLUFS: -16, truePeakCeilingDB: -2))
        #expect(fresh.captions == .sidecarSRT && fresh.coverImage == .jpg && fresh.continueOnDamagedFrames)
        #expect(fresh.audio.loudness == LoudnessNormalization(targetLUFS: -16, truePeakCeilingDB: -2))
    }

    @Test func customPreferencesKeepHandEditedVideo() throws {
        var s = ExportPreset.default.settings
        s.video.width = 720; s.video.height = 1280
        let p = ExportPreferences(presetID: ExportPreferences.customPresetID, settings: s)
        #expect(p.preset == nil)
        var fresh = ExportPreset.default.settings
        try #require(ExportPreferences.decode(p.encoded())).apply(to: &fresh, loudness: LoudnessNormalization())
        #expect(fresh.video.width == 720 && fresh.video.height == 1280)
    }

    @Test func damagedOrEmptyPreferencesDecodeToDefaults() throws {
        let p = try #require(ExportPreferences.decode(Data("{}".utf8)))
        #expect(p.presetID == ExportPreset.default.id && p.audioEnabled && !p.normalizeLoudness)
        #expect(ExportPreferences.decode(Data("nope".utf8)) == nil)
        #expect(ExportPreferences.decode(nil) == nil)
    }
}
