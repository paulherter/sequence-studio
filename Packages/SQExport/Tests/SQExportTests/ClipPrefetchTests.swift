import CoreVideo
import Foundation
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
import Testing
import VideoToolbox
@testable import SQExport

// Export decode-ahead across cuts (PLAYBACK-PERF "Export: clip starts decoded ahead"): the renderer looks a little ahead
// on the output timeline and hands every clip start to the provider, which decodes it on its own decoder lane (session),
// so a cut no longer waits for a seek (decode from the sync sample) on the render path.

private let fd = Time(1, 30)

private func clip(_ media: UUID, src: Int, frames: Int, at: Int, generator: GeneratorRef? = nil) -> Clip {
    Clip(name: "c", media: media, kind: .video, source: TimeRange(start: Time(Int64(src), 30), duration: Time(Int64(frames), 30)),
         start: Time(Int64(at), 30), generator: generator)
}

private func timeline(_ tracks: [[Clip]], width: Int = 64, height: Int = 32) -> Timeline {
    Timeline(name: "t", format: SequenceFormat(width: width, height: height, frameDuration: fd),
             tracks: tracks.map { Track(kind: .video, clips: $0) })
}

@Suite struct ClipPrefetchScannerTests {
    private func scan(_ tl: Timeline, start: Int = 0, count: Int, lead: Int, to: [Int]) -> [[ClipPrefetchScanner.Hint]] {
        var s = ClipPrefetchScanner(start: Time(Int64(start), 30), frameDuration: fd, frameCount: count, leadFrames: lead)
        return to.map { f in s.advance(to: Time(Int64(f), 30)) { tl.videoLayers(at: $0) } }
    }

    @Test func hintsTheNextClipStartOnceItIsWithinTheLead() {
        let a = UUID(), b = UUID()
        let tl = timeline([[clip(a, src: 0, frames: 30, at: 0), clip(b, src: 50, frames: 30, at: 30)]])
        let h = scan(tl, count: 60, lead: 10, to: [0, 19, 20, 21, 40])
        #expect(h[0].isEmpty)
        #expect(h[1].isEmpty)
        #expect(h[2] == [ClipPrefetchScanner.Hint(media: b, sourceTime: Time(50, 30))])
        #expect(h[3].isEmpty)
        #expect(h[4].isEmpty)
    }

    @Test func aJumpCutOnOneMediaIsHinted() {
        let a = UUID()
        let tl = timeline([[clip(a, src: 0, frames: 30, at: 0), clip(a, src: 40, frames: 20, at: 30)]])
        #expect(scan(tl, count: 50, lead: 10, to: [20]) == [[ClipPrefetchScanner.Hint(media: a, sourceTime: Time(40, 30))]])
    }

    @Test func clipsDrawnAtTheStartAreNotHinted() {
        let a = UUID(), b = UUID()
        let tl = timeline([[clip(a, src: 0, frames: 30, at: 0), clip(b, src: 50, frames: 30, at: 30)]])
        // A segment that starts inside b: its first frame is fetched by the render itself.
        #expect(scan(tl, start: 35, count: 20, lead: 10, to: [35, 45]) == [[], []])
    }

    @Test func neverLooksPastTheLastFrame() {
        let a = UUID(), b = UUID()
        let tl = timeline([[clip(a, src: 0, frames: 30, at: 0), clip(b, src: 50, frames: 30, at: 30)]])
        #expect(scan(tl, count: 30, lead: 10, to: [20, 29]) == [[], []])
    }

    @Test func generatorsAreNotHinted() {
        let a = UUID()
        let tl = timeline([[clip(a, src: 0, frames: 60, at: 0)],
                           [clip(UUID(), src: 0, frames: 10, at: 30, generator: .solid(rgb: [255, 0, 0]))]])
        #expect(scan(tl, count: 60, lead: 10, to: [20, 25]) == [[], []])
    }

    @Test func aClipStartingOverAContinuingClipIsHintedAlone() {
        let a = UUID(), b = UUID()
        let tl = timeline([[clip(a, src: 0, frames: 60, at: 0)], [clip(b, src: 7, frames: 10, at: 30)]])
        #expect(scan(tl, count: 60, lead: 10, to: [20]) == [[ClipPrefetchScanner.Hint(media: b, sourceTime: Time(7, 30))]])
    }
}

private func stamp(_ src: CVPixelBuffer) -> Int? {
    if FrameStamp.supportedFormats.contains(CVPixelBufferGetPixelFormatType(src)) { return FrameStamp.read(src) }
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), kCVPixelFormatType_32BGRA, nil, &dst)
    var xfer: VTPixelTransferSession?
    guard let dst, VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xfer) == noErr, let xfer,
          VTPixelTransferSessionTransferImage(xfer, from: src, to: dst) == noErr else { return nil }
    return FrameStamp.read(dst)
}

/// Decoder lanes: test clips are 60 frames with a sync sample every 12, so a jump is a real seek.
@Suite(.serialized) struct DecoderLaneTests {
    private func resolver(media: Int = 1) async throws -> (StaticMediaResolver, [UUID]) {
        var spec = TestClipSpec(); spec.frameCount = 60
        var d: [UUID: any Demuxing] = [:], ids: [UUID] = []
        for _ in 0..<media {
            let id = UUID()
            d[id] = try await AVDemuxer(url: try await TestClipWriter.write(spec))
            ids.append(id)
        }
        return (StaticMediaResolver(demuxers: d, audio: [:]), ids)
    }

    private func stamps(_ p: DecoderFrameProvider, _ m: UUID, _ frames: some Sequence<Int>) async throws -> [Int?] {
        var out: [Int?] = []
        for i in frames { out.append(try await p.frame(media: m, at: Time(Int64(i), 30)).map { stamp($0.buffer) } ?? nil) }
        return out
    }

    @Test func aPrefetchedClipStartNeedsNoDecodeOnTheRequest() async throws {
        let (r, ids) = try await resolver(); let m = ids[0]
        let p = DecoderFrameProvider(resolver: r, lookAhead: 4)
        #expect(try await stamps(p, m, 0..<10) == (0..<10).map { Optional($0) })
        await p.prefetch(media: m, at: Time(40, 30))
        await p.settle()
        let before = await p.requestDecodes
        #expect(try await stamps(p, m, 10..<14) == (10..<14).map { Optional($0) })
        #expect(try await stamps(p, m, 40..<46) == (40..<46).map { Optional($0) })
        #expect(await p.requestDecodes == before)
        #expect(await p.lanesOpened == 1)
    }

    @Test func aPrefetchOnAFreshProviderUsesTheMediasFirstLane() async throws {
        let (r, ids) = try await resolver(); let m = ids[0]
        let p = DecoderFrameProvider(resolver: r, lookAhead: 4)
        await p.prefetch(media: m, at: Time(40, 30))
        await p.settle()
        #expect(try await stamps(p, m, 40..<46) == (40..<46).map { Optional($0) })
        #expect(await p.requestDecodes == 0)
        #expect(await p.sessionCount == 1)
        #expect(await p.lanesOpened == 0)
    }

    /// A dissolve between two points of one media: each point keeps its own lane, no seek per frame.
    @Test func twoPointsOfOneMediaAlternateWithoutSeeking() async throws {
        let (r, ids) = try await resolver(); let m = ids[0]
        let p = DecoderFrameProvider(resolver: r, lookAhead: 4)
        _ = try await stamps(p, m, 0..<3)
        await p.prefetch(media: m, at: Time(40, 30))
        await p.settle()
        let seeks = await p.reseeks
        var got: [Int?] = [], want: [Int?] = []
        for i in 0..<10 {
            got += try await stamps(p, m, [3 + i, 40 + i])
            want += [3 + i, 40 + i]
        }
        #expect(got == want)
        #expect(await p.reseeks == seeks)
    }

    /// Prefetch only opens a lane while the shared session budget keeps room for the render's own opens.
    @Test func prefetchLeavesRoomInTheSessionBudget() async throws {
        let (r, ids) = try await resolver(); let m = ids[0]
        let budget = DecoderBudget(maxDecoders: 2)
        let p = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 4)
        _ = try await stamps(p, m, [0])
        await p.prefetch(media: m, at: Time(40, 30))
        await p.settle()
        #expect(await p.lanesOpened == 0)
        #expect(budget.usage.decoders == 1)
        #expect(try await stamps(p, m, [40]) == [40])
    }

    /// Nothing is prefetched for a frame a lane already holds, is decoding or reaches by decoding on.
    @Test func noPrefetchForAFrameALaneAlreadyReaches() async throws {
        let (r, ids) = try await resolver(); let m = ids[0]
        let p = DecoderFrameProvider(resolver: r, lookAhead: 4)
        _ = try await stamps(p, m, 0..<6)
        for f in [7, 9, 12] { await p.prefetch(media: m, at: Time(Int64(f), 30)) }
        await p.settle()
        #expect(await p.lanesOpened == 0)
        #expect(await p.prefetches == 0)
    }

    /// Once another lane serves the media, a lane left idle closes (sessions stay bounded).
    @Test func anIdleLaneClosesWhenAnotherServesTheMedia() async throws {
        let (r, ids) = try await resolver(); let m = ids[0]
        let budget = DecoderBudget()
        let p = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 4, laneIdleRequests: 6)
        _ = try await stamps(p, m, 0..<3)
        await p.prefetch(media: m, at: Time(30, 30))
        await p.settle()
        #expect(await p.sessionCount == 2)
        #expect(try await stamps(p, m, 30..<45) == (30..<45).map { Optional($0) })
        await p.settle()
        #expect(await p.sessionCount == 1)
        #expect(budget.usage.decoders == 1)
        // The closed lane's point opens again when asked, exact.
        #expect(try await stamps(p, m, [3, 4]) == [3, 4])
    }

    @Test func releaseClosesEveryLane() async throws {
        let (r, ids) = try await resolver(); let m = ids[0]
        let budget = DecoderBudget()
        let p = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 4)
        _ = try await stamps(p, m, 0..<3)
        await p.prefetch(media: m, at: Time(40, 30))
        await p.release(media: [m])
        await p.settle()
        #expect(budget.usage == (0, 0))
        #expect(await p.sessionCount == 0)
    }

    /// Lanes per media are capped.
    @Test func lanesPerMediaAreCapped() async throws {
        let (r, ids) = try await resolver(); let m = ids[0]
        let p = DecoderFrameProvider(resolver: r, lookAhead: 4, lanesPerMedia: 2)
        _ = try await stamps(p, m, [0])
        for f in [20, 40, 55] { await p.prefetch(media: m, at: Time(Int64(f), 30)) }
        await p.settle()
        #expect(await p.sessionCount == 2)
        #expect(try await stamps(p, m, [20, 40, 55]) == [20, 40, 55])
    }
}

/// The whole export render with and without clip prefetch: identical bytes (same frames, same compositor).
@Suite(.serialized) struct ClipPrefetchExportTests {
    @Test func prefetchGivesByteIdenticalFrames() async throws {
        var spec = TestClipSpec(); spec.frameCount = 60
        let a = UUID(), b = UUID()
        let r = StaticMediaResolver(demuxers: [a: try await AVDemuxer(url: try await TestClipWriter.write(spec)),
                                               b: try await AVDemuxer(url: try await TestClipWriter.write(spec))], audio: [:])
        var over = clip(a, src: 10, frames: 20, at: 25)
        over.animation.opacity = AnimatedProperty(0.5)
        over.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
        let tl = timeline([[clip(a, src: 0, frames: 20, at: 0), clip(b, src: 30, frames: 15, at: 20),
                            clip(a, src: 40, frames: 15, at: 35), clip(b, src: 5, frames: 15, at: 50)], [over]],
                          width: 160, height: 90)
        var outputs: [[[UInt8]]] = []
        var lanes = 0, prefetches = 0
        for prefetch in [false, true] {
            let p = DecoderFrameProvider(resolver: r)
            let src = try TimelineFrameSource(timeline: tl, provider: p, width: 160, height: 90, frameDuration: fd, frameCount: 65,
                                              clipPrefetch: prefetch)
            var all: [[UInt8]] = []
            for i in 0..<65 { all.append(bytes(try await src.frame(at: i))) }
            outputs.append(all)
            if prefetch { lanes = await p.lanesOpened; prefetches = await p.prefetches }
        }
        #expect(outputs[0] == outputs[1])
        #expect(Set(outputs[0]).count > 30)
        #expect(prefetches >= 3, "prefetches \(prefetches)")
        #expect(lanes >= 1, "lanes \(lanes)")
    }
}

private func bytes(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!
    let n = CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
    return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: n))
}
