import Testing
import Foundation
import CoreMedia
import Metal
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

private let fd = Time(1, 30)

/// The 16 frame-stamp bits as linear luma (0 = black, 1 = white) from an rgba16Float texture.
private func stampLevels(_ texture: MTLTexture, device: MTLDevice) -> [Float]? {
    let w = texture.width, h = texture.height, bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let px = buf.contents().assumingMemoryBound(to: Float16.self)
    return (0..<FrameStamp.bitCount).map { bit in
        var sum: Float = 0, n: Float = 0
        for y in 4..<12 { for x in (bit * 16 + 4)..<(bit * 16 + 12) {
            let i = y * w * 4 + x * 4
            sum += 0.2126 * Float(px[i]) + 0.7152 * Float(px[i + 1]) + 0.0722 * Float(px[i + 2]); n += 1
        } }
        return sum / n
    }
}

private func bits(_ v: Int) -> [Float] { (0..<FrameStamp.bitCount).map { (v >> $0) & 1 == 1 ? 1 : 0 } }

@MainActor private func readLevels(_ engine: PlaybackEngine, _ device: MTLDevice) throws -> [Float] {
    let tex = try #require(engine.lastRenderedTexture)
    return try #require(stampLevels(tex, device: device))
}

@Suite(.serialized) @MainActor struct TransitionPlaybackTests {
    /// Mid-transition frame read back from the engine: A and B both decoded, blended in linear light. Frame stamps are
    /// black/white blocks, so each block's level is `(1 - w) * bitA + w * bitB`.
    @Test func midTransitionFrameIsTheLinearBlend() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec()
        spec.frameCount = 60; spec.frameDuration = TestClipSpec.fps(30)
        let url = try await TestClipWriter.write(spec)
        let media = UUID()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)]),
                                        clock: ManualClock())
        // A = clip frames 0..<40 at 0; B = clip frames 10..<50 at 40. Transition 10 frames centred on the cut: span 35..<45.
        let a = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 40), start: .zero, mediaDuration: fd * 60)
        let b = Clip(name: "B", media: media, kind: .video, source: TimeRange(start: fd * 10, duration: fd * 40), start: fd * 40, mediaDuration: fd * 60)
        var track = Track(kind: .video); try track.overwrite(a); try track.overwrite(b)
        var tl = Timeline(name: "t", format: SequenceFormat(width: 320, height: 180, frameDuration: fd), tracks: [track])
        try tl.addTransition(kind: .crossDissolve, track: track.id, outgoing: a.id, incoming: b.id, duration: fd * 10)
        engine.setTimeline(tl)

        // Frame 40 = index 5 of 10: w = 6/11. A shows clip frame 40 (its tail handle), B shows clip frame 10.
        engine.seek(to: fd * 40)
        await engine.waitForDecodes()
        #expect(engine.tick())
        let levels = try readLevels(engine, device)
        let w: Float = 6.0 / 11, bitsA = bits(40), bitsB = bits(10)
        for k in 0..<FrameStamp.bitCount {
            let expected = (1 - w) * bitsA[k] + w * bitsB[k]
            #expect(abs(levels[k] - expected) < 0.08, "bit \(k): \(levels[k]) vs \(expected)")
        }
        // The first frame of the span is almost A; outside the span it is exactly B.
        engine.seek(to: fd * 35); await engine.waitForDecodes()
        #expect(engine.tick())
        let first = try readLevels(engine, device)
        for k in 0..<FrameStamp.bitCount { #expect(abs(first[k] - ((10.0 / 11) * bits(35)[k] + (1.0 / 11) * bits(5)[k])) < 0.08) }
        engine.seek(to: fd * 45); await engine.waitForDecodes()
        #expect(engine.tick())
        let after = try readLevels(engine, device)
        for k in 0..<FrameStamp.bitCount { #expect(abs(after[k] - bits(15)[k]) < 0.08) }
    }

    /// Measurement: 5 s of 1080p30 played in real time through a 1 s dissolve (both clips decoded at once) against the same
    /// cut without a transition. Prints dropped frames and tick times; only a gross failure fails the test. Opt-in (`SQ_PERF=1`): writing the 1080p clip takes ~110 s.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_PERF"] == "1"))
    func dissolveFiveSecondPlayAt1080p() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec()
        spec.width = 1920; spec.height = 1080; spec.frameCount = 240; spec.frameDuration = TestClipSpec.fps(30)
        let url = try await TestClipWriter.write(spec)
        let demuxer = try await AVDemuxer(url: url)
        var results: [(String, Int, Int, Double, Double, Double)] = []
        for withTransition in [false, true] {
            let media = UUID()
            let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [media: demuxer]))
            // A: clip frames 0..<75 at 0; B: clip frames 120..<195 at 75 (5 s total). A 1 s transition centred on the cut at 2.5 s.
            let a = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 75), start: .zero, mediaDuration: fd * 240)
            let b = Clip(name: "B", media: media, kind: .video, source: TimeRange(start: fd * 120, duration: fd * 75), start: fd * 75, mediaDuration: fd * 240)
            var track = Track(kind: .video); try track.overwrite(a); try track.overwrite(b)
            var tl = Timeline(name: "t", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [track])
            if withTransition { try tl.addTransition(kind: .crossDissolve, track: track.id, outgoing: a.id, incoming: b.id, duration: fd * 30) }
            engine.setTimeline(tl)
            engine.seek(to: .zero)
            await engine.waitForDecodes()
            _ = engine.tick()
            let before = engine.stats, decodes0 = engine.decodeCalls
            engine.play()
            let clock = ContinuousClock()
            let start = clock.now
            var worst = 0.0, total = 0.0, ticks = 0
            while clock.now - start < .seconds(5) {
                let t0 = clock.now
                _ = engine.tick()
                let dt = (clock.now - t0) / .milliseconds(1)
                worst = max(worst, dt); total += dt; ticks += 1
                try await Task.sleep(for: .milliseconds(8))
            }
            engine.pause()
            let st = engine.stats
            results.append((withTransition ? "dissolve" : "plain cut", st.presentedFrames - before.presentedFrames,
                            st.droppedFrames - before.droppedFrames, total / Double(max(1, ticks)), worst, Double(engine.decodeCalls - decodes0)))
        }
        for r in results {
            NSLog("transition perf 1080p30 5 s play [%@]: presented=%d dropped=%d tick mean=%.2fms max=%.2fms decodeCalls=%.0f",
                  r.0, r.1, r.2, r.3, r.4, r.5)
        }
        #expect(results[1].1 > 100)      // played, not stalled
    }
}

@Suite struct TransitionHoldTests {
    @Test func solidDipLayersDoNotPreventTheScrubHold() {
        // A dip: solid + outgoing + incoming, both pictures cold: hold (3 layers, 1 solid, 2 cold).
        #expect(RenderLoop.shouldHold(noFrame: 2, layers: 3, solids: 1, coldInTransition: 2, hasLast: true))
        // Plain cut, everything cold: as before.
        #expect(RenderLoop.shouldHold(noFrame: 1, layers: 1, solids: 0, coldInTransition: 0, hasLast: true))
        // Nothing presented yet: never hold.
        #expect(!RenderLoop.shouldHold(noFrame: 1, layers: 1, solids: 0, coldInTransition: 0, hasLast: false))
    }

    @Test func aDissolveWithOneColdSideHoldsInsteadOfDrawingThePlaceholder() {
        #expect(RenderLoop.shouldHold(noFrame: 1, layers: 2, solids: 0, coldInTransition: 1, hasLast: true))
        // One cold layer among others that are not part of a transition still composites (unchanged behaviour).
        #expect(!RenderLoop.shouldHold(noFrame: 1, layers: 3, solids: 0, coldInTransition: 0, hasLast: true))
        #expect(!RenderLoop.shouldHold(noFrame: 0, layers: 2, solids: 0, coldInTransition: 0, hasLast: true))
    }
}
