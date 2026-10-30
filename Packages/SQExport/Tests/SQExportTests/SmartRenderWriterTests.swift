import Testing
import AVFoundation
import CoreMedia
import Foundation
import SQCore
@testable import SQExport

/// Smart Render writer: passthrough runs are copied sample for sample, the rest is encoded, timing is the frame grid.
@Suite(.serialized) struct SmartRenderWriterTests {
    struct Sample: Sendable { var pts: CMTime; var dts: CMTime; var sync: Bool; var bytes: Data }
    static let fd = Time(1, 30)

    static func samples(_ url: URL) async throws -> [Sample] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let tk = Box(track)
        return try await offPool {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: tk.buffer, outputSettings: nil)
            reader.add(out); reader.startReading()
            var all: [Sample] = []
            while let sb = out.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sb) > 0, let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                var data = Data(count: CMBlockBufferGetDataLength(block))
                _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
                let notSync = (a?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
                all.append(Sample(pts: CMSampleBufferGetPresentationTimeStamp(sb), dts: CMSampleBufferGetDecodeTimeStamp(sb),
                                  sync: !notSync, bytes: data))
            }
            return all
        }
    }

    static func settings(_ codec: VideoCodec = .h264) -> ExportSettings {
        var s = smallSettings(codec: codec, width: 128, height: 64)
        s.video.keyframeInterval = 30
        return s
    }

    /// A 90-frame source file written by the plain export (keyframes every 30 frames), and its samples.
    static func makeSource(in dir: URL, codec: VideoCodec = .h264) async throws -> (URL, [Sample]) {
        let url = dir.appendingPathComponent("source.mp4")
        try await ExportWriter.export(video: SegmentablePattern(width: 128, height: 64, frameCount: 90), audio: nil,
                                      settings: settings(codec), to: url, segments: 1, progress: { _ in })
        return (url, try await samples(url))
    }

    static func plan(total: Int, runs: [SmartRenderRun]) -> SmartRenderPlan {
        SmartRenderPlan(totalFrames: total, runs: runs, passthrough: runs, reasons: [:])
    }

    static func time(_ t: CMTime) -> Time { Time(t.value, Int64(t.timescale)) }

    @Test func copiesWholeGOPsAndEncodesTheRest() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (src, source) = try await Self.makeSource(in: dir)
        let syncs = source.filter(\.sync).map(\.pts).sorted { $0 < $1 }
        try #require(syncs.count >= 3)
        let media = UUID()
        // Output frames 20..<50 show the source's second GOP.
        let gop2 = source.filter { $0.pts >= syncs[1] && $0.pts < syncs[2] }
        let run = SmartRenderRun(frames: 20..<(20 + gop2.count), clip: UUID(), media: media, sourceStart: Self.time(syncs[1]))
        let url = dir.appendingPathComponent("out.mp4")
        let r = try await ExportWriter.exportSmart(video: SegmentablePattern(width: 128, height: 64, frameCount: 90), audio: nil,
                                                   settings: Self.settings(), plan: Self.plan(total: 90, runs: [run]),
                                                   mediaURLs: [media: src], to: url, progress: { _ in })
        #expect(r.copiedFrames == gop2.count && !r.fellBack)
        let out = try await Self.samples(url)
        #expect(out.count == 90)
        // Frame grid, no gaps or duplicates.
        let pts = out.map { Int(($0.pts.seconds * 30).rounded()) }.sorted()
        #expect(pts == Array(pts[0]..<(pts[0] + 90)))
        let dts = out.map(\.dts).filter(\.isValid)
        #expect(zip(dts, dts.dropFirst()).allSatisfy { $0 < $1 })
        // The copied samples are the source's bytes.
        let base = out.map(\.pts).min { $0 < $1 }!
        let copied = out.filter {
            let f = Int((($0.pts - base).seconds * 30).rounded())
            return f >= 20 && f < 20 + gop2.count
        }
        let order: (Data, Data) -> Bool = { $0.lexicographicallyPrecedes($1) }
        #expect(copied.map(\.bytes).sorted(by: order) == gop2.map(\.bytes).sorted(by: order))
        #expect(copied.filter(\.sync).count == 1)
        // Valid: every frame decodes, length is 3 s.
        let info = try await readVideo(url)
        #expect(info.frames == 90 && info.codec == kCMVideoCodecType_H264)
        let d = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(d - 3.0) < 0.05)
    }

    @Test func keepsAudioAlongsideCopiedRuns() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (src, source) = try await Self.makeSource(in: dir)
        let syncs = source.filter(\.sync).map(\.pts).sorted { $0 < $1 }
        let media = UUID()
        let run = SmartRenderRun(frames: 0..<30, clip: UUID(), media: media, sourceStart: Self.time(syncs[1]))
        var s = Self.settings()
        s.audio.enabled = true
        let url = dir.appendingPathComponent("out.mp4")
        let r = try await ExportWriter.exportSmart(video: SegmentablePattern(width: 128, height: 64, frameCount: 90),
                                                   audio: SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(90, 30)),
                                                   settings: s, plan: Self.plan(total: 90, runs: [run]),
                                                   mediaURLs: [media: src], to: url, progress: { _ in })
        #expect(r.copiedFrames == 30 && !r.fellBack)
        let asset = AVURLAsset(url: url)
        let a = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(abs(try await a.load(.timeRange).duration.seconds - 3.0) < 0.1)
        #expect(try await readVideo(url).frames == 90)
    }

    @Test func runsThatDoNotStartOnASyncSampleAreEncoded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (src, source) = try await Self.makeSource(in: dir)
        let syncs = source.filter(\.sync).map(\.pts).sorted { $0 < $1 }
        let media = UUID()
        let off = Self.time(syncs[1]) + Self.fd * 3
        let run = SmartRenderRun(frames: 20..<40, clip: UUID(), media: media, sourceStart: off)
        let url = dir.appendingPathComponent("out.mp4")
        let r = try await ExportWriter.exportSmart(video: SegmentablePattern(width: 128, height: 64, frameCount: 90), audio: nil,
                                                   settings: Self.settings(), plan: Self.plan(total: 90, runs: [run]),
                                                   mediaURLs: [media: src], to: url, progress: { _ in })
        #expect(r.copiedFrames == 0)
        #expect(try await readVideo(url).frames == 90)
    }

    @Test func verifyRefusesWrongSizeCodecAndPartialGOPs() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (src, source) = try await Self.makeSource(in: dir)
        let syncs = source.filter(\.sync).map(\.pts).sorted { $0 < $1 }
        let from = Self.time(syncs[1])
        let run = SmartRenderRun(frames: 0..<30, clip: UUID(), media: UUID(), sourceStart: from)
        let ok = await ExportWriter.verifiedCopy(run, url: src, frameDuration: Self.fd, size: (128, 64), codec: kCMVideoCodecType_H264)
        let wrongSize = await ExportWriter.verifiedCopy(run, url: src, frameDuration: Self.fd, size: (64, 128), codec: kCMVideoCodecType_H264)
        let wrongCodec = await ExportWriter.verifiedCopy(run, url: src, frameDuration: Self.fd, size: (128, 64), codec: kCMVideoCodecType_HEVC)
        // A run that ends inside a GOP: the sample after it is not a sync sample.
        let short = SmartRenderRun(frames: 0..<20, clip: UUID(), media: UUID(), sourceStart: from)
        let partial = await ExportWriter.verifiedCopy(short, url: src, frameDuration: Self.fd, size: (128, 64), codec: kCMVideoCodecType_H264)
        #expect(ok && !wrongSize && !wrongCodec && !partial)
    }
}
