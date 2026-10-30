import AVFoundation
import Foundation
import SQCore
import Testing
@testable import SQExport

/// Every preset of the Export sheet must produce a file with its resolution, frame rate, duration and an audio track.
@Suite struct PresetFileTests {
    @Test func catalogueOrderAndIDsAreUnique() {
        let all = ExportPreset.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.first == .matchSource)
        #expect(all.contains(.youtube1080) && all.contains(.youtube4K) && all.contains(.proRes))
        #expect(all.allSatisfy { $0.settings.validate().isEmpty })
        #expect(ExportPreset.youtube1080.settings.video.width == 1920 && ExportPreset.youtube1080.settings.video.height == 1080)
        #expect(ExportPreset.youtube4K.settings.video.width == 3840 && ExportPreset.youtube4K.settings.video.height == 2160)
        #expect(ExportPreset.proRes.settings.fileExtension == "mov")
    }

    @Test func matchSourceFollowsTheSequence() {
        let f = SequenceFormat(width: 2560, height: 1440, frameDuration: Time(1001, 24000))
        let s = ExportPreset.matchSource.settings(matching: f)
        #expect(s.video.width == 2560 && s.video.height == 1440)
        #expect(s.video.frameDuration == Time(1001, 24000))
        #expect(s.video.codec == .h264)
        #expect(s.validate().isEmpty)
        // Odd sequence sizes round down to even (encoders need it).
        let odd = ExportPreset.matchSource.settings(matching: SequenceFormat(width: 1081, height: 1921, frameDuration: Time(1, 30)))
        #expect(odd.video.width == 1080 && odd.video.height == 1920)
        // YouTube keeps its size, takes the sequence rate; social presets stay fixed.
        let y = ExportPreset.youtube1080.settings(matching: SequenceFormat(width: 3840, height: 2160, frameDuration: Time(1, 60)))
        #expect(y.video.width == 1920 && y.video.frameDuration == Time(1, 60))
        #expect(y.video.bitrate.averageBitsPerSecond > ExportPreset.youtube1080.settings.video.bitrate.averageBitsPerSecond)
        let t = ExportPreset.default.settings(matching: f)
        var expected = ExportPreset.default.settings
        expected.video.frameDuration = Time(1001, 24000)   // 23.976 fps is kept
        #expect(t == expected)
    }

    @Test func socialPresetsKeepTheSequenceRateWithinRange() {
        func rate(_ preset: ExportPreset, _ d: Time) -> Time {
            preset.settings(matching: SequenceFormat(width: 1080, height: 1920, frameDuration: d)).video.frameDuration
        }
        for p in [ExportPreset.default, .feedPortrait, .feedSquare, .stories] {
            #expect(rate(p, Time(1, 25)) == Time(1, 25))
            #expect(rate(p, Time(1001, 30000)) == Time(1001, 30000))
            #expect(rate(p, Time(1, 60)) == Time(1, 60))
            #expect(rate(p, Time(1, 120)) == Time(1, 30))
            #expect(rate(p, Time(1, 15)) == Time(1, 30))
        }
    }

    /// Writes 0.5 s at the preset's own size and rate (every frame a test pattern) and reads the file back.
    @Test(.serialized, arguments: ExportPreset.all) func presetProducesACorrectFile(_ preset: ExportPreset) async throws {
        guard !preset.isAudioOnly else { return }   // covered by AudioDeliveryTests
        guard preset.settings.frameOutput == nil else { return }   // GIF and sequences: FrameOutputTests
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = preset.settings
        let fps = Double(s.video.frameDuration.timescale) / Double(s.video.frameDuration.value)
        let frames = Int((fps / 2).rounded())
        let url = dir.appendingPathComponent("out." + s.fileExtension)
        let v = TestPatternSource(width: s.video.width, height: s.video.height, frameCount: frames, frameDuration: s.video.frameDuration)
        let a = SineAudioSource(sampleRate: s.audio.sampleRate, channels: s.audio.channels, duration: Time(1, 2), frequency: 440)
        try await ExportWriter.export(video: v, audio: a, settings: s, to: url, progress: { _ in })

        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(Int(size.width) == s.video.width && Int(size.height) == s.video.height, "\(preset.id) size")
        let rate = Double(try await video.load(.nominalFrameRate))
        #expect(abs(rate - fps) < 0.05, "\(preset.id) fps \(rate)")
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 0.5) < 0.1, "\(preset.id) duration \(duration)")
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1, "\(preset.id) audio")
    }
}
