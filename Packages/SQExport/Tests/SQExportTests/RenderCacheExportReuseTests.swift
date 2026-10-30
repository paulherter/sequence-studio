import AVFoundation
import CoreVideo
import Foundation
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
import Testing
@testable import SQExport

// Preview render cache follow-ups: an export reads the cached segments playback reads (only when its settings give the
// cache's picture), the pending-writes tier, the cache key's working space, and the encoder callback QoS check.

/// Mean absolute difference over every plane's bytes (both buffers of the same format and size).
private func meanDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    var planes: [(UnsafeRawPointer, UnsafeRawPointer, Int, Int, Int)] = []
    if CVPixelBufferIsPlanar(a) {
        for p in 0..<CVPixelBufferGetPlaneCount(a) {
            planes.append((UnsafeRawPointer(CVPixelBufferGetBaseAddressOfPlane(a, p)!), UnsafeRawPointer(CVPixelBufferGetBaseAddressOfPlane(b, p)!),
                           CVPixelBufferGetBytesPerRowOfPlane(a, p), CVPixelBufferGetBytesPerRowOfPlane(b, p),
                           CVPixelBufferGetHeightOfPlane(a, p)))
        }
    } else {
        planes.append((UnsafeRawPointer(CVPixelBufferGetBaseAddress(a)!), UnsafeRawPointer(CVPixelBufferGetBaseAddress(b)!),
                       CVPixelBufferGetBytesPerRow(a),
                       CVPixelBufferGetBytesPerRow(b), CVPixelBufferGetHeight(a)))
    }
    var sum = 0.0, n = 0
    for (pa, pb, ra, rb, h) in planes {
        let w = min(ra, rb)
        for y in 0..<h {
            let la = pa.advanced(by: y * ra).assumingMemoryBound(to: UInt8.self)
            let lb = pb.advanced(by: y * rb).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { sum += Double(abs(Int(la[x]) - Int(lb[x]))) }
            n += w
        }
    }
    return n == 0 ? 0 : sum / Double(n)
}

private func surfaceBuffer(_ w: Int = 64, _ h: Int = 36) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    memset(CVPixelBufferGetBaseAddress(pb!), 0x40, CVPixelBufferGetBytesPerRow(pb!) * h)
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

@Suite(.serialized) struct RenderCacheExportReuseTests {
    private let fd = Time(1, 30)

    private func sequence(_ media: UUID) -> Timeline {
        let clip = Clip(name: "v", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
        return Timeline(name: "t", format: SequenceFormat(width: 320, height: 180, frameDuration: fd),
                        tracks: [Track(kind: .video, clips: [clip])])
    }

    private func exportSettings(_ tl: Timeline, codec: VideoCodec = .h264) -> ExportSettings {
        var s = ExportSettings()
        s.video.codec = codec
        s.video.width = tl.format.width; s.video.height = tl.format.height
        s.video.frameDuration = tl.format.frameDuration
        s.audio.enabled = false
        return s
    }

    @Test func reuseOnlyWhenTheExportGivesTheCachedPicture() {
        let tl = sequence(UUID())
        let base = exportSettings(tl)
        #expect(RenderCacheSegmentWriter.mayReuse(base, timeline: tl))
        for c in [VideoCodec.hevc, .prores422LT, .prores422Proxy] {
            var s = base; s.video.codec = c
            #expect(RenderCacheSegmentWriter.mayReuse(s, timeline: tl), "\(c)")
        }
        // Masters above the cache's ProRes 422 LT render fresh.
        for c in [VideoCodec.prores422, .prores422HQ, .prores4444] {
            var s = base; s.video.codec = c
            #expect(!RenderCacheSegmentWriter.mayReuse(s, timeline: tl), "\(c)")
        }
        var s = base; s.video.width = 640; s.video.height = 360
        #expect(!RenderCacheSegmentWriter.mayReuse(s, timeline: tl))
        s = base; s.video.frameDuration = Time(1, 25)
        #expect(!RenderCacheSegmentWriter.mayReuse(s, timeline: tl))
        s = base; s.variant = UUID()
        #expect(!RenderCacheSegmentWriter.mayReuse(s, timeline: tl))
        s = base; s.video.codec = .prores4444; s.video.preservesAlpha = true
        #expect(!RenderCacheSegmentWriter.mayReuse(s, timeline: tl))
        s = base; s.hdrToSDR = HDRToSDR(exposureStops: 1)
        #expect(!RenderCacheSegmentWriter.mayReuse(s, timeline: tl))
    }

    @Test func exportReadsTheCachedSpanAndRendersTheRestFresh() async throws {
        var spec = TestClipSpec(); spec.frameCount = 90
        let url = try await TestClipWriter.write(spec)
        let media = UUID(), cached = UUID()
        // The "cache file" here is the same pattern clip: inside the span the export shows its file time (t - span start).
        let resolver = StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url), cached: try await AVDemuxer(url: url)])
        let tl = sequence(media)
        let span = RenderCacheSpan(range: TimeRange(start: Time(1, 1), duration: Time(1, 1)), media: cached)
        let s = exportSettings(tl)
        let plain = try ExportSourceBuilder.make(timeline: tl, sequences: [:], settings: s, resolver: resolver).video
        let reuse = try ExportSourceBuilder.make(timeline: tl, sequences: [:], settings: s, resolver: resolver, renderCache: [span]).video
        let inSpan = try await reuse.frame(at: 30), fileStart = try await plain.frame(at: 0), fresh30 = try await plain.frame(at: 30)
        #expect(meanDifference(inSpan, fileStart) < 0.5)
        #expect(meanDifference(inSpan, fresh30) > 1)
        let outside = try await reuse.frame(at: 70), fresh70 = try await plain.frame(at: 70)
        #expect(meanDifference(outside, fresh70) < 0.5)

        // A master renders fresh even when spans are handed in.
        var master = s; master.video.codec = .prores422HQ
        let freshMaster = try ExportSourceBuilder.make(timeline: tl, sequences: [:], settings: master, resolver: resolver).video
        let noReuse = try ExportSourceBuilder.make(timeline: tl, sequences: [:], settings: master, resolver: resolver,
                                                   renderCache: [span]).video
        #expect(meanDifference(try await noReuse.frame(at: 30), try await freshMaster.frame(at: 30)) < 0.5)
    }

    @Test func aRealCacheFileExportsLikeTheFreshRender() async throws {
        var spec = TestClipSpec(); spec.frameCount = 90
        let src = try await TestClipWriter.write(spec)
        let media = UUID()
        let tl = sequence(media)
        var segment = try #require(RenderCachePlan.segments(of: tl, context: RenderCacheContext(rendererID: "t", workingSpace: "w")).first)
        segment.range = TimeRange(start: Time(1, 1), duration: Time(1, 2))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: file) }
        let base = StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: src)])
        let pending = RenderCachePendingFrames(media: RenderCacheMedia.id(forKey: segment.key), anchor: Time(1, 6))
        try await RenderCacheSegmentWriter.write(segment: segment, timeline: tl, sequences: [:], resolver: base, to: file,
                                                 pending: pending)
        // The writer filled the pending tier with the frames it encoded, at file time.
        let frames = pending.take()
        #expect(frames.count == 15)
        #expect(frames.first?.pts == .zero && frames.last?.pts == fd * 14)
        #expect(frames.allSatisfy { $0.media == pending.media })

        let id = RenderCacheMedia.id(forKey: segment.key)
        let resolver = StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: src), id: try await UncachedFileDemuxer(url: file)])
        let s = exportSettings(tl)
        let fresh = try ExportSourceBuilder.make(timeline: tl, sequences: [:], settings: s, resolver: resolver).video
        let reuse = try ExportSourceBuilder.make(timeline: tl, sequences: [:], settings: s, resolver: resolver,
                                                 renderCache: [RenderCacheSpan(range: segment.range, media: id)]).video
        for i in [30, 37, 44] {
            // ProRes 422 LT against the uncompressed composite: a small difference only.
            #expect(meanDifference(try await reuse.frame(at: i), try await fresh.frame(at: i)) < 3, "frame \(i)")
        }
    }

    @Test func pendingTierKeepsTheFramesNearestTheAnchor() {
        let one = DecodedFrame(media: UUID(), pts: .zero, duration: fd, pixelBuffer: surfaceBuffer()).byteCost
        let tier = RenderCachePendingFrames(media: UUID(), anchor: fd * 10, byteBudget: one * 4)
        for i in 0..<20 { tier.add(surfaceBuffer(), at: fd * Int64(i), duration: fd) }
        #expect(tier.count == 4 && tier.byteCount <= one * 4)
        let kept = tier.take().map(\.pts)
        #expect(Set(kept) == Set([fd * 9, fd * 10, fd * 11, fd * 8]) || Set(kept) == Set([fd * 9, fd * 10, fd * 11, fd * 12]))
        #expect(tier.count == 0 && tier.byteCount == 0)
        // Buffers the monitor cannot draw (no IOSurface) are not kept.
        var plain: CVPixelBuffer?
        CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &plain)
        tier.add(plain!, at: .zero, duration: fd)
        #expect(tier.count == 0)
    }

    @Test func workingSpaceIsRealAndFollowsTheCacheEncoding() {
        let tl = sequence(UUID())
        let ws = RenderCacheSegmentWriter.workingSpace(for: tl)
        #expect(ws != "default")
        #expect(ws.hasPrefix(RenderCacheSegmentWriter.compositorWorkingSpace))
        #expect(ws.contains(VideoCodec.prores422LT.rawValue))
        #expect(RenderCacheSegmentWriter.workingSpace(for: tl) == ws)
        // The key changes with it: same clips, other working space, other segment keys.
        let a = RenderCachePlan.segments(of: tl, context: RenderCacheContext(rendererID: "r", workingSpace: ws))
        let b = RenderCachePlan.segments(of: tl, context: RenderCacheContext(rendererID: "r", workingSpace: ws + "x"))
        #expect(a.map(\.key) != b.map(\.key))
    }

    @Test func encoderCallbackQoSIsChecked() throws {
        #expect(SpeedEncoderSession.isBelow(QOS_CLASS_UTILITY, QOS_CLASS_USER_INITIATED))
        #expect(SpeedEncoderSession.isBelow(QOS_CLASS_BACKGROUND, QOS_CLASS_UTILITY))
        #expect(!SpeedEncoderSession.isBelow(QOS_CLASS_USER_INITIATED, QOS_CLASS_UTILITY))
        #expect(!SpeedEncoderSession.isBelow(QOS_CLASS_USER_INITIATED, QOS_CLASS_USER_INITIATED))
        #expect(!SpeedEncoderSession.isBelow(QOS_CLASS_UNSPECIFIED, QOS_CLASS_USER_INITIATED))
        #expect(!SpeedEncoderSession.isBelow(QOS_CLASS_UTILITY, QOS_CLASS_UNSPECIFIED))

        var s = ExportSettings()
        s.video.codec = .h264; s.video.width = 64; s.video.height = 36
        s.video.frameDuration = fd; s.video.bitrate = .average(1_000_000)
        s.audio.enabled = false
        let session = try SpeedEncoderSession(settings: s)
        for i in 0..<5 {
            try session.encode(surfaceBuffer(), pts: CMTime(value: CMTimeValue(i), timescale: 30), duration: CMTime(value: 1, timescale: 30))
        }
        try session.complete()
        _ = try session.take()
        let q = session.callbackQoS
        #expect(q.callbacks == 5)
        #expect(q.below <= q.callbacks)
    }
}
