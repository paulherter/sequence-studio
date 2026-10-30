import Testing
import Foundation
import Metal
import SQCore
import SQMedia
import SQMediaTestSupport
import SQText
@testable import SQPlayback

private let fd = Time(1, 30)

/// Presentation-rate regression guard (no real media, no wall clock): a manual clock advances one 30 fps frame per
/// display tick for 150 ticks over a 5 s stamped clip; every tick must present a new source frame. Decodes are awaited
/// between ticks, so only the engine's own hold / wait / skip logic can cost a frame.
/// Manual clock, no wall-clock timing: these are correctness tests of the hold / skip logic and stay in the default run.
@Suite(.serialized) @MainActor struct PresentationRateTests {
    private static func stamp(_ tex: MTLTexture, device: MTLDevice) -> Int? {
        let w = tex.width, h = tex.height, bpr = w * 8
        guard let q = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
              let cb = q.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let px = buf.contents().assumingMemoryBound(to: Float16.self)
        var value = 0
        for bit in 0..<FrameStamp.bitCount {
            var sum: Float = 0, n: Float = 0
            for y in 4..<12 { for x in (bit * 16 + 4)..<(bit * 16 + 12) {
                let i = y * w * 4 + x * 4
                sum += 0.2126 * Float(px[i]) + 0.7152 * Float(px[i + 1]) + 0.0722 * Float(px[i + 2]); n += 1
            } }
            let v = sum / n
            if v > 0.3 && v < 0.7 { return nil }
            if v >= 0.7 { value |= 1 << bit }
        }
        return value
    }

    private struct Result { var presented = 0, distinctStamps = Set<Int>(), dropped = 0, ticks = 0 }

    private enum Scene { case plain, textV2, captions, dissolve }

    private func run(_ scene: Scene) async throws -> Result {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec()
        spec.frameCount = 150; spec.frameDuration = TestClipSpec.fps(30)
        let url = try await TestClipWriter.write(spec)
        let media = UUID()
        let clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)]), clock: clock)
        let format = SequenceFormat(width: 320, height: 180, frameDuration: fd)
        var tracks: [Track]
        if scene == .dissolve {
            let a = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 80), start: .zero, mediaDuration: fd * 150)
            let b = Clip(name: "B", media: media, kind: .video, source: TimeRange(start: fd * 70, duration: fd * 80), start: fd * 80, mediaDuration: fd * 150)
            var t = Track(kind: .video); try t.overwrite(a); try t.overwrite(b)
            tracks = [t]
        } else {
            tracks = [Track(kind: .video, clips: [Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 150),
                                                       start: .zero, mediaDuration: fd * 150)])]
        }
        if scene == .textV2 {
            let style = TextStyle(fontName: "Helvetica-Bold", size: 30, color: .white)
            let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "HELLO", style: style), animations: nil)
            let id = UUID()
            var text = Clip(id: id, name: "Text", media: id, kind: .video, source: TimeRange(start: .zero, duration: fd * 150), start: .zero, generator: ref)
            text.animation.position = AnimatedProperty(Vec2(0, 40))
            tracks.append(Track(kind: .video, clips: [text]))
        }
        var tl = Timeline(name: "s", format: format, tracks: tracks)
        if scene == .dissolve {
            let v = tl.tracks[0]
            try tl.addTransition(kind: .crossDissolve, track: v.id, outgoing: v.clips[0].id, incoming: v.clips[1].id, duration: fd * 10)
        }
        if scene == .captions {
            _ = try tl.replaceCaptions([CaptionItem(lines: ["HELLO"], range: TimeRange(start: Time(1, 1), end: Time(4, 1)), styleRef: "title")])
        }
        engine.setTimeline(tl)
        // Warm up like a user pressing play after the first frame is up: decode, text rasters.
        engine.seek(to: .zero)
        await engine.waitForDecodes()
        for _ in 0..<50 {
            _ = engine.tick()
            if scene == .textV2 || scene == .captions { try await Task.sleep(for: .milliseconds(20)) }
            await engine.waitForDecodes()
        }
        engine.play()
        let before = engine.stats
        var r = Result()
        for _ in 0..<150 {
            clock.advance(by: fd)
            let presented = engine.tick()
            r.ticks += 1
            if presented {
                r.presented += 1
                if let tex = engine.lastRenderedTexture, let s = Self.stamp(tex, device: device) { r.distinctStamps.insert(s) }
            }
            await engine.waitForDecodes()
        }
        engine.pause()
        r.dropped = engine.stats.droppedFrames - before.droppedFrames
        return r
    }

    @Test func plainPlaybackPresentsEveryTick() async throws {
        let r = try await run(.plain)
        #expect(r.presented >= 148, "presented \(r.presented)")
        #expect(r.distinctStamps.count >= 148, "distinct frames \(r.distinctStamps.count)")
        #expect(r.dropped == 0)
    }

    @Test func textOnV2PresentsEveryTick() async throws {
        let r = try await run(.textV2)
        #expect(r.presented >= 148, "presented \(r.presented)")
        #expect(r.distinctStamps.count >= 148, "distinct frames \(r.distinctStamps.count)")
        #expect(r.dropped == 0)
    }

    @Test func captionsPresentEveryTick() async throws {
        let r = try await run(.captions)
        #expect(r.presented >= 148, "presented \(r.presented)")
        #expect(r.distinctStamps.count >= 148, "distinct frames \(r.distinctStamps.count)")
        #expect(r.dropped == 0)
    }

    @Test func crossDissolvePresentsEveryTick() async throws {
        let r = try await run(.dissolve)   // blended frames carry no clean stamp: count presented composites
        #expect(r.presented >= 148, "presented \(r.presented)")
        #expect(r.dropped == 0)
    }
}
