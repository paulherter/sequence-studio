import Testing
import Foundation
import CoreMedia
import Metal
import SSCore
import SSMedia
import SSMediaTestSupport
@testable import SSPlayback

private let fd = Time(1, 30)
private let format = SequenceFormat(width: 320, height: 180, frameDuration: fd)

/// One generated 60-frame H.264 clip (320x180, 30 fps, stamps 0...59), shared by all tests.
private actor SharedClip {
    static let shared = SharedClip()
    private var url: URL?
    func get() async throws -> URL {
        if let url { return url }
        var spec = TestClipSpec()
        spec.frameCount = 60
        spec.frameDuration = TestClipSpec.fps(30)
        let u = try await TestClipWriter.write(spec)
        url = u
        return u
    }
}

/// Reads the FrameStamp (16 black/white 16x16 blocks, bit 0 leftmost) from an rgba16Float texture at row `y0`.
private func readStamp(_ texture: MTLTexture, device: MTLDevice, y0: Int = 0) -> Int? {
    let w = texture.width, h = texture.height
    let bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let px = buf.contents().assumingMemoryBound(to: Float16.self)
    var value = 0
    for bit in 0..<FrameStamp.bitCount {
        var sum: Float = 0, n: Float = 0
        for y in (y0 + 4)..<(y0 + 12) {
            for x in (bit * 16 + 4)..<(bit * 16 + 12) {
                let i = y * w * 4 + x * 4
                sum += 0.2126 * Float(px[i]) + 0.7152 * Float(px[i + 1]) + 0.0722 * Float(px[i + 2]); n += 1
            }
        }
        let v = sum / n
        if v > 0.3 && v < 0.7 { return nil }
        if v >= 0.7 { value |= 1 << bit }
    }
    return value
}

@MainActor
private struct Rig {
    let engine: PlaybackEngine
    let clock: ManualClock
    let device: MTLDevice
    let media: UUID
    var timeline: Timeline

    static func make(_ build: (UUID) -> Timeline) async throws -> Rig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await SharedClip.shared.get()
        let demuxer = try await AVDemuxer(url: url)
        let media = UUID()
        let resolver = StaticMediaResolver(demuxers: [media: demuxer])
        let clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: resolver, clock: clock)
        let tl = build(media)
        engine.setTimeline(tl)
        return Rig(engine: engine, clock: clock, device: device, media: media, timeline: tl)
    }

    static func single(_ media: UUID) -> Timeline {
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 60),
                        start: .zero, mediaDuration: fd * 60)
        return Timeline(name: "Seq", format: format, tracks: [Track(kind: .video, clips: [clip])])
    }

    func stamp(y0: Int = 0) -> Int? {
        guard let tex = engine.lastRenderedTexture else { return nil }
        return readStamp(tex, device: device, y0: y0)
    }

    /// tick; returns the stamp if a frame was presented.
    func tick() -> Int? { engine.tick() ? stamp() : nil }
}

@Suite(.serialized) @MainActor struct PlaybackEngineTests {
    @Test func playSeekAndStepBackFromCache() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        // Preroll: seek plans + submits immediately; once decoded the first tick presents frame 0 without a drop.
        e.seek(to: .zero)
        await e.waitForDecodes()
        var stamps: [Int] = []
        if let s = rig.tick() { stamps.append(s) }
        #expect(e.stats.droppedFrames == 0)

        e.play()
        for _ in 1..<60 {
            await e.waitForDecodes()
            rig.clock.advance(by: fd)
            if let s = rig.tick() { stamps.append(s) }
        }
        #expect(stamps == Array(0..<60))
        #expect(e.stats.droppedFrames == 0)
        #expect(e.position == fd * 59)

        // Nothing changed: no present.
        e.pause()
        _ = e.tick()
        #expect(e.tick() == false)

        // Seek to 37: cached already, presents 37.
        e.seek(to: fd * 37)
        await e.waitForDecodes()
        #expect(rig.tick() == 37)

        // Step back 10: every frame served from cache, no decode job at all.
        let decodesBefore = e.decodeCalls
        var back: [Int] = []
        for _ in 0..<10 {
            e.step(-1)
            if let s = rig.tick() { back.append(s) }
        }
        await e.waitForDecodes()
        #expect(back == Array((27...36).reversed()))
        #expect(e.decodeCalls == decodesBefore)
        #expect(e.position == fd * 27)

        let st = e.stats
        #expect(st.presentedFrames >= 71)
        #expect(st.droppedFrames == 0)
        #expect(st.stepLatencies.count >= 11)
        #expect(st.cacheBytes > 0)
        #expect(st.maxAVDrift == .zero)
    }

    @Test func seekPresentsFrameOnceDecoded() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.seek(to: fd * 37)
        _ = e.tick()                       // may miss (loading placeholder)
        await e.waitForDecodes()
        #expect(rig.tick() == 37)
        #expect(e.position == fd * 37)
        #expect(e.stats.stepLatencies.count == 1)
    }

    @Test func setTimelineAfterTrimRecompositesWithoutFlush() async throws {
        var rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.seek(to: fd * 10)
        await e.waitForDecodes()
        #expect(rig.tick() == 10)
        let cached = e.cacheCount
        #expect(cached > 0)

        // Ripple head trim by 5 frames: the clip still starts at 0, its source starts at 5.
        let clipID = rig.timeline.tracks[0].clips[0].id
        try rig.timeline.rippleTrim(clipID, edge: .head, by: fd * 5)
        e.setTimeline(rig.timeline)
        #expect(e.cacheCount == cached)
        #expect(rig.tick() == 15)          // invalidated: presents again at the same position
        #expect(e.cacheCount == cached)
    }

    @Test func stackedClipsCompositeBoth() async throws {
        let rig = try await Rig.make { media in
            let a = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: fd * 10, duration: fd * 20),
                         start: .zero, mediaDuration: fd * 60)
            var anim = ClipAnimation()
            anim.position = AnimatedProperty(Vec2(0, 90))     // shift V2 down: V1's stamp row stays visible
            let b = Clip(name: "B", media: media, kind: .video, source: TimeRange(start: fd * 40, duration: fd * 20),
                         start: .zero, mediaDuration: fd * 60, animation: anim)
            return Timeline(name: "Seq", format: format,
                            tracks: [Track(kind: .video, clips: [a]), Track(kind: .video, clips: [b])])
        }
        let e = rig.engine
        e.seek(to: fd * 3)
        await e.waitForDecodes()
        #expect(e.tick())
        #expect(rig.stamp(y0: 0) == 13)
        #expect(rig.stamp(y0: 90) == 43)
    }

    @Test func qualityChangeUsesOtherScale() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.seek(to: fd * 5)
        await e.waitForDecodes()
        #expect(rig.tick() == 5)
        let full = e.cacheCount
        e.quality = .half
        _ = e.tick()
        await e.waitForDecodes()
        #expect(rig.tick() == 5)
        #expect(e.cacheCount > full)       // half-scale frames stored beside the full ones
    }

    @Test func offlineMediaDrawsPlaceholder() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock())
        engine.setTimeline(Rig.single(UUID()))
        #expect(engine.tick())
        #expect(engine.lastRenderedTexture != nil)
        #expect(engine.stats.presentedFrames == 1)
    }
}
