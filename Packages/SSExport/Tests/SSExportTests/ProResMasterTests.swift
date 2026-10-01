import Testing
import AVFoundation
import CoreMedia
import Foundation
import SSCore
@testable import SSExport

@Suite struct ProResMasterTests {
    @Test func presetDefaults() {
        let s = ExportSettings.proRes422HQMaster
        #expect(s.video.codec == .prores422HQ)
        #expect(s.color == .rec709)
        #expect(s.audio.codec == .pcm)
        #expect(s.audio.pcmBitDepth == 24)
        #expect(s.audio.sampleRate == 48_000)
        #expect(s.audio.channels == 2)
        #expect(s.fileExtension == "mov")
        #expect(s.validate().isEmpty)
        #expect(ExportSettings().fileExtension == "mp4")
    }

    @Test func socialPresetsStayDeliveryCodecs() {
        #expect(ExportPreset.social.allSatisfy { $0.codec == .h264 || $0.codec == .hevc })
    }

    @Test func codableRoundTripAndOldDataDecodes() throws {
        let s = ExportSettings.proRes422HQMaster
        #expect(try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(s)) == s)
        // Audio settings written before PCM existed: no pcmBitDepth key, codec aac.
        let old = #"{"enabled":true,"codec":"aac","sampleRate":48000,"channels":2,"bitrate":192000}"#
        let a = try JSONDecoder().decode(AudioSettings.self, from: Data(old.utf8))
        #expect(a.codec == .aac)
        #expect(a.pcmBitDepth == 24)
        // The two previous video codec raw values are unchanged.
        #expect(try JSONDecoder().decode(VideoCodec.self, from: Data(#""hevc""#.utf8)) == .hevc)
    }

    @Test func exportsProResWithPCM() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.mov")
        var s = ExportSettings.proRes422HQMaster
        s.video.width = 64; s.video.height = 112
        let v = TestPatternSource(width: 64, height: 112, frameCount: 30, frameDuration: Time(1, 30))
        let a = SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(1, 1), frequency: 440)
        try await ExportWriter.export(video: v, audio: a, settings: s, to: url, progress: { _ in })

        let info = try await readVideo(url)
        #expect(info.codec == kCMVideoCodecType_AppleProRes422HQ)   // 'apch'
        #expect(info.primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
        #expect(info.transfer == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String))
        #expect(info.matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String))
        #expect(info.frames == 30)

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let fd = try #require(try await track.load(.formatDescriptions).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatLinearPCM)
        #expect(asbd.mBitsPerChannel == 24)
        #expect(asbd.mSampleRate == 48_000)
        #expect(asbd.mChannelsPerFrame == 2)
        #expect(asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0)
        let dur = try await track.load(.timeRange).duration.seconds
        #expect(abs(dur - 1.0) < 0.1)
    }

    @Test func queueUsesMovExtension() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue()
        var s = ExportSettings.proRes422HQMaster
        s.video.width = 64; s.video.height = 112
        let job = ExportJob(name: "Master", settings: s, outputDirectory: dir) {
            ExportSources(video: TestPatternSource(width: 64, height: 112, frameCount: 6, frameDuration: Time(1, 30)))
        }
        let id = await q.enqueue(job)
        #expect(await q.status(id)?.outputURL.pathExtension == "mov")
    }
}
