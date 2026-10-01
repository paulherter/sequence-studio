import Testing
import AVFoundation
import Foundation
import SQCore
@testable import SQExport

@Suite struct AudioExportTests {
    @Test func aacTrackReadsBack() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.mp4")
        var s = smallSettings(codec: .h264)
        s.audio.enabled = true
        s.audio.sampleRate = 48_000
        s.audio.channels = 2
        s.audio.bitrate = 128_000
        let v = TestPatternSource(width: 64, height: 112, frameCount: 30, frameDuration: Time(1, 30))
        let a = SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(1, 1), frequency: 440)
        try await ExportWriter.export(video: v, audio: a, settings: s, to: url, progress: { _ in })

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let fd = try #require(try await track.load(.formatDescriptions).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC)
        #expect(asbd.mSampleRate == 48_000)
        #expect(asbd.mChannelsPerFrame == 2)
        let dur = try await track.load(.timeRange).duration.seconds
        #expect(abs(dur - 1.0) < 0.1)
        // Video still intact and tagged.
        let info = try await readVideo(url)
        #expect(info.frames == 30)
        #expect(info.primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
    }

    @Test func monoAt44100() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.mp4")
        var s = smallSettings(codec: .h264)
        s.audio.enabled = true; s.audio.sampleRate = 44_100; s.audio.channels = 1; s.audio.bitrate = 64_000
        let v = TestPatternSource(width: 64, height: 112, frameCount: 15, frameDuration: Time(1, 30))
        let a = SineAudioSource(sampleRate: 44_100, channels: 1, duration: Time(1, 2), frequency: 1000)
        try await ExportWriter.export(video: v, audio: a, settings: s, to: url, progress: { _ in })
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        let fd = try #require(try await track.load(.formatDescriptions).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee)
        #expect(asbd.mSampleRate == 44_100 && asbd.mChannelsPerFrame == 1)
    }

    @Test func disabledAudioWritesNoAudioTrack() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("n.mp4")
        let s = smallSettings(codec: .h264) // audio disabled
        let v = TestPatternSource(width: 64, height: 112, frameCount: 6, frameDuration: Time(1, 30))
        let a = SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(1, 1))
        try await ExportWriter.export(video: v, audio: a, settings: s, to: url, progress: { _ in })
        #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty)
    }
}
