import CoreGraphics
import CoreVideo
import CoreMedia
import Foundation
import Metal
import Testing
import SQAnalysis
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

// F7.11 Anonymize in playback: a mask that must cover is drawn on stills and inside nested sequences, and the render
// thread never waits for it (whole frame until the matte is there). The cover in these tests is an Invert limited to
// the mask, so a covered pixel differs from the same render without the cover.

private let fd = Time(1, 30)
private let width = 128, height = 64

private func readback(_ texture: MTLTexture, device: MTLDevice) -> [Float16]? {
    let w = texture.width, h = texture.height, bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: Float16.self), count: w * h * 4))
}

private func redStill() throws -> StillFrame {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return StillFrame(buffer: try StillImage.pixelBuffer(from: ctx.makeImage()!), info: StillImage.trackInfo(width: width, height: height))
}

/// A clip whose Anonymize mask limits an Invert, and the keys its mattes are stored under.
private struct Covered {
    var clip: Clip
    var plain: Clip
    var keys: [String]
    var part: String

    init(media: UUID, still: Bool) throws {
        var c = Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero,
                     mediaDuration: still ? nil : Time(2, 1), isStill: still)
        plain = c
        let pick = MagicSelection(points: [MagicPoint(position: Vec2(0.1, 0.5), subtract: false, sourceTime: .zero)], part: .face)
        let masks = c.addAnonymize([pick], target: .face, cover: .mosaic, subjectWidth: 8, frameWidth: width, frameHeight: height)
        let mask = try #require(masks.first)
        let added = c.addEffect(kind: ClipEffect.invertKind)
        let invert = try #require(added)
        c.setMask(mask, input: true, ofEffect: invert)
        c.effects.removeAll { $0.kind == ClipEffect.mosaicKind }
        let sel = try #require(c.masks.first?.magic)
        clip = c
        part = try #require(sel.partKey(media: media))
        keys = sel.matteKeys(media: media)
    }

    /// Stores a matte covering the left eighth of the frame at source time `pts`.
    func putLeft(pts: Double) {
        var v = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<16 { v[y * width + x] = 1 } }
        MagicMatteStore.shared.put(SubjectMatte(width: width, height: height, values: v), key: part, pts: pts)
    }

    func forget() { keys.forEach(MagicMatteStore.shared.remove) }
}

private func timeline(_ clips: [Clip], w: Int = width, h: Int = height) -> Timeline {
    Timeline(name: "t", format: SequenceFormat(width: w, height: h, frameDuration: fd), tracks: [Track(kind: .video, clips: clips)])
}

@Suite(.serialized) @MainActor struct AnonymizePlaybackTests {
    /// The picture at `time`, drawn again after the background work of the matte store until it is settled.
    private func picture(_ engine: PlaybackEngine, device: MTLDevice, at time: Time, settle: Bool = true) async throws -> [Float16] {
        engine.seek(to: time)
        await engine.waitForDecodes()
        _ = engine.tick()
        for _ in 0..<(settle ? 4 : 0) {
            MagicMatteStore.shared.waitForCovers()
            engine.seek(to: time)
            await engine.waitForDecodes()
            _ = engine.tick()
        }
        let tex = try #require(engine.lastRenderedTexture)
        return try #require(readback(tex, device: device))
    }

    /// Mean difference of the green channel between two pictures over the columns `x` of the middle rows.
    private func change(_ a: [Float16], _ b: [Float16], _ x: Range<Int>, w: Int = width, h: Int = height) -> Float {
        var sum: Float = 0, n: Float = 0
        for y in (h / 4)..<(h * 3 / 4) { for i in x {
            let p = (y * w + i) * 4
            sum += abs(Float(a[p]) - Float(b[p])) + abs(Float(a[p + 1]) - Float(b[p + 1])) + abs(Float(a[p + 2]) - Float(b[p + 2]))
            n += 1
        } }
        return sum / n
    }

    @Test func aStillWithoutAMatteIsCoveredWholeFromTheFirstFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let media = UUID()
        let c = try Covered(media: media, still: true)
        defer { c.forget() }
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(stills: [media: try redStill()]), clock: ManualClock())
        engine.setTimeline(timeline([c.plain]))
        let plain = try await picture(engine, device: device, at: Time(1, 2), settle: false)
        engine.setTimeline(timeline([c.clip]))
        let first = try await picture(engine, device: device, at: Time(1, 2), settle: false)
        #expect(change(first, plain, 2..<12) > 0.5 && change(first, plain, 58..<70) > 0.5 && change(first, plain, 114..<126) > 0.5)
        let settled = try await picture(engine, device: device, at: Time(1, 2))
        #expect(change(settled, plain, 2..<12) > 0.5 && change(settled, plain, 58..<70) > 0.5 && change(settled, plain, 114..<126) > 0.5)
    }

    @Test func aStillTakesTheMatteTrackedOnIt() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let media = UUID()
        let c = try Covered(media: media, still: true)
        defer { c.forget() }
        c.putLeft(pts: 0)
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(stills: [media: try redStill()]), clock: ManualClock())
        engine.setTimeline(timeline([c.plain]))
        let plain = try await picture(engine, device: device, at: Time(1, 2), settle: false)
        engine.setTimeline(timeline([c.clip]))
        let px = try await picture(engine, device: device, at: Time(1, 2))
        #expect(change(px, plain, 2..<12) > 0.5)
        #expect(change(px, plain, 58..<70) < 0.02 && change(px, plain, 114..<126) < 0.02)
    }

    @Test func aCoveredClipInsideANestedSequenceIsCovered() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec()
        spec.width = 320; spec.height = 180; spec.frameCount = 60; spec.frameDuration = TestClipSpec.fps(30)
        let url = try await TestClipWriter.write(spec)
        let media = UUID()
        let c = try Covered(media: media, still: false)
        defer { c.forget() }
        for i in 0..<20 { c.putLeft(pts: Double(i) / 30) }
        func nested(_ clip: Clip) -> (Timeline, [Timeline.ID: Timeline]) {
            let inner = timeline([clip], w: 320, h: 180)
            let nest = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero,
                            sequence: inner.id)
            return (timeline([nest], w: 320, h: 180), [inner.id: inner])
        }
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)]),
                                        clock: ManualClock())
        let p = nested(c.plain)
        engine.setTimeline(p.0, sequences: p.1)
        let plain = try await picture(engine, device: device, at: fd * 10, settle: false)
        let late = try await picture(engine, device: device, at: fd * 28, settle: false)
        let n = nested(c.clip)
        engine.setTimeline(n.0, sequences: n.1)
        let px = try await picture(engine, device: device, at: fd * 10)
        let on = change(px, plain, 4..<30, w: 320, h: 180), off = change(px, plain, 200..<316, w: 320, h: 180)
        #expect(on > 0.05, "covered where tracked: \(on)")
        #expect(off < 0.01, "not covered elsewhere: \(off)")
        // Past the tracked frames: the estimate or the whole frame, never nothing.
        let after = try await picture(engine, device: device, at: fd * 28)
        let past = change(after, late, 4..<30, w: 320, h: 180)
        #expect(past > 0.05, "covered past the tracking: \(past)")
    }
}
