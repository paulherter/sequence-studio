import CoreMedia
import Foundation
import Metal
import Synchronization
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

// Hidden layers (PLAYBACK-PERF "Playback: hidden layers"): a media layer under an opaque picture that fills the canvas
// is not drawn, and while playing not decoded (only the sync frame of its GOP); it is decoded again in time for the
// frame where it comes out from under the cover. Paused, its frame at the playhead is decoded, so an edit that uncovers
// it shows the exact frame at once; playing, an uncovered layer never shows an old picture or the gray placeholder.
// The picture itself is compared with the export in SQExportTests/PlaybackHiddenLayerTests.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

private func pixels(_ t: MTLTexture, device: MTLDevice) -> [Float16] {
    let w = t.width, h = t.height, bpr = w * 8
    let q = device.makeCommandQueue()!, buf = device.makeBuffer(length: bpr * h, options: .storageModeShared)!
    let cb = q.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: Float16.self), count: w * h * 4))
}

/// The two test clips (150 frames, a sync sample every 12), written once.
private actor Clips {
    static let shared = Clips()
    private var urls: [URL]?
    func get() async throws -> [URL] {
        if let urls { return urls }
        var spec = TestClipSpec(); spec.frameCount = 150
        let r = [try await TestClipWriter.write(spec), try await TestClipWriter.write(spec)]
        urls = r
        return r
    }
}

/// What uncovers the lower layer.
private enum Uncover: String, CaseIterable {
    case opacity, trackHidden, effect, coverDeleted, cullOff

    /// Whether the cover is still drawn afterwards.
    var keepsCover: Bool { self != .trackHidden && self != .coverDeleted }

    @MainActor func apply(_ engine: PlaybackEngine, _ tl: Timeline) {
        var t = tl
        var cover = tl.tracks[1].clips[0]
        switch self {
        case .opacity: cover.animation.opacity = AnimatedProperty(0.5)
        case .trackHidden: t.tracks[1].isVisible = false
        case .effect: cover.effects = [ClipEffect.make(kind: ClipEffect.dropShadowKind)!]
        case .coverDeleted: t.tracks[1] = Track(kind: .video, clips: [])
        case .cullOff: engine.cullsHiddenLayers = false; return
        }
        if self == .opacity || self == .effect { t.tracks[1] = Track(kind: .video, clips: [cover]) }
        engine.setTimeline(t)
    }
}

@Suite(.serialized) @MainActor struct HiddenLayerPlaybackTests {
    private struct Rig {
        let engine: PlaybackEngine, clock: ManualClock, device: MTLDevice, a: UUID, b: UUID, timeline: Timeline
    }

    /// A for 150 frames; B (as large as the canvas) over frames 30..<120.
    private func rig(cull: Bool, cover: (inout Clip) -> Void = { _ in }) async throws -> Rig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let spec = TestClipSpec()
        let a = UUID(), b = UUID()
        let urls = try await Clips.shared.get()
        let resolver = StaticMediaResolver(demuxers: [a: try await AVDemuxer(url: urls[0]), b: try await AVDemuxer(url: urls[1])], audio: [:])
        let clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: resolver, clock: clock)
        engine.quality = .full
        engine.cullsHiddenLayers = cull
        engine.waitsForStartFrame = false
        let lower = Clip(name: "A", media: a, kind: .video, source: TimeRange(start: .zero, duration: f(150)), start: .zero)
        var upper = Clip(name: "B", media: b, kind: .video, source: TimeRange(start: f(30), duration: f(90)), start: f(30))
        cover(&upper)
        let tl = Timeline(name: "cover", format: SequenceFormat(width: spec.width, height: spec.height, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [lower]), Track(kind: .video, clips: [upper])])
        engine.setTimeline(tl)
        return Rig(engine: engine, clock: clock, device: device, a: a, b: b, timeline: tl)
    }

    /// Paused at frame `n` with every frame it draws decoded, and the paused window around it.
    private func show(_ engine: PlaybackEngine, _ n: Int64) async throws -> TickProfile {
        engine.seek(to: f(n))
        for _ in 0..<200 {
            _ = engine.tick()
            if let p = engine.lastTickProfile, p.time == f(n), p.presented, p.missing == 0, p.noFrame == 0 {
                await engine.waitForDecodes()       // the window around the playhead
                return p
            }
            await engine.waitForDecodes()
        }
        throw CancellationError()
    }

    /// Plays `frames` frames on from where the engine is, every planned decode finished before the next tick.
    private func play(_ r: Rig, frames: Int, each: (TickProfile) -> Void = { _ in }) async {
        for _ in 0..<frames {
            r.clock.advance(by: fd)
            if r.engine.tick(), let p = r.engine.lastTickProfile { each(p) }
            await r.engine.waitForDecodes()
        }
    }

    @Test func aCoveredLayerIsNotDecodedWhilePlayingAndComesBackInTime() async throws {
        let r = try await rig(cull: true)
        // The first covered frame teaches the engine that B is opaque (from B's first decoded frame).
        #expect(try await show(r.engine, 40).hidden == 1)
        r.engine.play()
        var wrong: [String] = []
        await play(r, frames: 60) { p in
            if p.hidden != 1 || p.layers != 1 || p.missing != 0 { wrong.append("\(p.time): hidden \(p.hidden) layers \(p.layers) missing \(p.missing)") }
        }
        #expect(wrong.isEmpty, "\(wrong)")
        // Playhead at frame 100, deep under the cover: of A only single warm frames were decoded there
        // (one per plan refresh), the newest a few frames behind the playhead.
        #expect(r.engine.cachedFrame(media: r.b, pts: f(100)))
        let warm = (56..<101).filter { r.engine.cachedFrame(media: r.a, pts: f(Int64($0))) }
        #expect(warm.count <= 8, "\(warm)")
        #expect((warm.last ?? 0) >= 88, "the hidden layer is kept warm near the playhead: \(warm)")
        // On to the cover's end: A is back on its first visible frame, exact, without a dropped frame.
        var back: TickProfile?
        await play(r, frames: 24) { p in if p.time == f(120) { back = p } }
        let p = try #require(back)
        #expect(p.missing == 0 && p.noFrame == 0 && p.hidden == 0 && p.layers == 1)
        #expect(r.engine.stats.droppedFrames == 0)
        #expect(r.engine.stats.lastShownPTS == f(124))
    }

    @Test func pausedTheHiddenLayerIsNotDrawnButItsFrameIsDecoded() async throws {
        let r = try await rig(cull: true)
        _ = try await show(r.engine, 40)
        let p = try await show(r.engine, 90)
        #expect(p.hidden == 1 && p.layers == 1)
        #expect(r.engine.cachedFrame(media: r.b, pts: f(90)))
        #expect(r.engine.cachedFrame(media: r.a, pts: f(90)))
    }

    @Test func everythingIsDrawnWhenHiddenLayersAreNotLeftOut() async throws {
        let r = try await rig(cull: false)
        _ = try await show(r.engine, 40)
        let p = try await show(r.engine, 90)
        #expect(p.hidden == 0 && p.layers == 2)
        r.engine.play()
        await play(r, frames: 10)
        #expect(r.engine.cachedFrame(media: r.a, pts: f(99)))
    }

    /// A cover that is not plain (here Opacity below 1) hides nothing, and its layers below are decoded.
    @Test func aFadedCoverHidesNothing() async throws {
        let r = try await rig(cull: true) { $0.animation.opacity = AnimatedProperty(0.5) }
        _ = try await show(r.engine, 40)
        let p = try await show(r.engine, 90)
        #expect(p.hidden == 0 && p.layers == 2)
        #expect(r.engine.cachedFrame(media: r.a, pts: f(90)))
    }

    /// Paused: whatever uncovers the lower layer, the very next redraw shows its exact frame (the picture an engine
    /// that never left anything out shows).
    @Test(arguments: Uncover.allCases) fileprivate func pausedAnUncoveredLayerShowsItsExactFrameOnTheNextRedraw(_ how: Uncover) async throws {
        let r = try await rig(cull: true)
        _ = try await show(r.engine, 40)
        #expect(try await show(r.engine, 90).hidden == 1)
        how.apply(r.engine, r.timeline)
        #expect(r.engine.tick(), "\(how): the redraw after the edit was held")
        let p = try #require(r.engine.lastTickProfile)
        #expect(p.presented && !p.held && p.hidden == 0 && p.missing == 0 && p.noFrame == 0, "\(how): \(p)")
        #expect(p.layers == (how.keepsCover ? 2 : 1), "\(how)")
        let got = pixels(try #require(r.engine.lastRenderedTexture), device: r.device)

        let ref = try await rig(cull: false)
        _ = try await show(ref.engine, 90)
        how.apply(ref.engine, ref.timeline)
        for _ in 0..<50 {
            _ = ref.engine.tick()
            if let q = ref.engine.lastTickProfile, q.presented, q.missing == 0, q.noFrame == 0 { break }
            await ref.engine.waitForDecodes()
        }
        #expect(got == pixels(try #require(ref.engine.lastRenderedTexture), device: ref.device), "\(how): not the picture of the edited timeline")
    }

    /// Playing: an uncovered layer is never drawn with a picture older than a few frames and never as the gray
    /// placeholder; until its frame is decoded the previous picture stays, then playback goes on exact.
    @Test(arguments: Uncover.allCases, [true, false])
    fileprivate func playingAnUncoveredLayerNeverShowsAnOldPicture(_ how: Uncover, decodesLandAtOnce: Bool) async throws {
        let r = try await rig(cull: true)
        _ = try await show(r.engine, 40)
        r.engine.play()
        await play(r, frames: 40)                       // playhead at frame 80, A hidden since 40
        #expect(r.engine.lastTickProfile?.hidden == 1)
        how.apply(r.engine, r.timeline)
        let limit = fd * Int64(RenderLoop.uncoveredStandInFrames)
        var wrong: [String] = [], exact = 0
        for i in 0..<20 {
            r.clock.advance(by: fd)
            let presented = r.engine.tick()
            if decodesLandAtOnce || i >= 4 { await r.engine.waitForDecodes() }
            guard presented, let p = r.engine.lastTickProfile else { continue }
            if p.noFrame > 0 { wrong.append("\(p.time): placeholder") }
            if p.hidden != 0 { wrong.append("\(p.time): still hidden") }
            // A is the bottom layer: `lastShownPTS` is its frame (its source time is the timeline time).
            let shown = try #require(r.engine.stats.lastShownPTS)
            if p.time - shown > limit || shown > p.time { wrong.append("\(p.time): A shows \(shown)") }
            if p.missing == 0 { exact += 1 }
        }
        #expect(wrong.isEmpty, "\(how): \(wrong)")
        #expect(exact >= 10, "\(how): playback did not go on with exact frames (\(exact))")
    }

    /// A cover the memory knows as opaque, but whose media is gone (offline), hides nothing: the layer below is planned
    /// ahead and drawn exact.
    @Test func anOfflineCoverHidesNothingAndTheLayerBelowIsPlanned() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let spec = TestClipSpec()
        let urls = try await Clips.shared.get()
        let a = UUID(), b = UUID()
        let resolver = SwitchResolver([a: try await AVDemuxer(url: urls[0]), b: try await AVDemuxer(url: urls[1])])
        let clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: resolver, clock: clock)
        engine.quality = .full
        engine.waitsForStartFrame = false
        let lower = Clip(name: "A", media: a, kind: .video, source: TimeRange(start: .zero, duration: f(150)), start: .zero)
        let upper = Clip(name: "B", media: b, kind: .video, source: TimeRange(start: f(30), duration: f(90)), start: f(30))
        let tl = Timeline(name: "cover", format: SequenceFormat(width: spec.width, height: spec.height, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [lower]), Track(kind: .video, clips: [upper])])
        engine.setTimeline(tl)
        let r = Rig(engine: engine, clock: clock, device: device, a: a, b: b, timeline: tl)
        #expect(try await show(engine, 40).hidden == 1)
        // B's file goes away; the engine is told (relink path), its memory of B must not hide A any more.
        resolver.remove(b)
        engine.mediaChanged([b])
        await engine.waitForDecodes()
        engine.play()
        var wrong: [String] = []
        await play(r, frames: 30) { p in
            if p.hidden != 0 || p.layers != 2 { wrong.append("\(p.time): hidden \(p.hidden) layers \(p.layers)") }
        }
        #expect(wrong.isEmpty, "\(wrong)")
        #expect(engine.cachedFrame(media: a, pts: f(70)), "the layer below the offline cover is decoded")
        #expect(engine.stats.lastShownPTS == f(70))
    }

    /// Rotated sources count with their upright size: a 640x360 file turned by 90 degrees is 360x640 on screen and
    /// does not fill a 640x360 canvas; a 360x640 file turned by 90 degrees does. Same picture as with everything drawn.
    @Test(arguments: [(640, 360, 0), (360, 640, 1)])
    func aRotatedCoverCountsWithItsUprightSize(_ w: Int, _ h: Int, _ hidden: Int) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let urls = try await Clips.shared.get()
        var turned = TestClipSpec(); turned.width = w; turned.height = h; turned.rotation = 90; turned.frameCount = 60
        let cover = try await TestClipWriter.write(turned)
        defer { try? FileManager.default.removeItem(at: cover) }
        let a = UUID(), b = UUID()
        func shown(cull: Bool) async throws -> (TickProfile, [Float16]) {
            let resolver = StaticMediaResolver(demuxers: [a: try await AVDemuxer(url: urls[0]), b: try await AVDemuxer(url: cover)], audio: [:])
            let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
            engine.quality = .full
            engine.cullsHiddenLayers = cull
            let lower = Clip(name: "A", media: a, kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero)
            let upper = Clip(name: "B", media: b, kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero)
            engine.setTimeline(Timeline(name: "turned", format: SequenceFormat(width: 640, height: 360, frameDuration: fd),
                                        tracks: [Track(kind: .video, clips: [lower]), Track(kind: .video, clips: [upper])]))
            _ = try await show(engine, 10)
            let p = try await show(engine, 20)
            return (p, pixels(try #require(engine.lastRenderedTexture), device: device))
        }
        let (p, culled) = try await shown(cull: true)
        let (q, all) = try await shown(cull: false)
        #expect(p.hidden == hidden && p.layers == 2 - hidden, "hidden \(p.hidden), layers \(p.layers)")
        #expect(q.hidden == 0 && q.layers == 2)
        #expect(culled == all)
    }

    /// The memory is kept per decoded source: an opaque original does not make its proxy a cover, nor the other way
    /// round. Here the proxy (ProRes 4444) decodes with an alpha channel: playing with proxies nothing is hidden,
    /// paused on the original the layer below is.
    @Test func aProxyWithAlphaIsNoCoverWhileItsOpaqueOriginalIs() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let spec = TestClipSpec()
        let urls = try await Clips.shared.get()
        var proxySpec = TestClipSpec(); proxySpec.codec = .prores4444Alpha; proxySpec.frameCount = 150
        let proxyURL = try await TestClipWriter.write(proxySpec)
        defer { try? FileManager.default.removeItem(at: proxyURL) }
        let a = UUID(), b = UUID()
        let resolver = ProxyTestResolver(originals: [a: try await AVDemuxer(url: urls[0]), b: try await AVDemuxer(url: urls[1])])
        resolver.setProxy(try await AVDemuxer(url: proxyURL), for: b)
        let clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: resolver, clock: clock)
        engine.quality = .full
        engine.waitsForStartFrame = false
        engine.proxyUse = ProxyUse(scrubbing: true, playback: true)
        let lower = Clip(name: "A", media: a, kind: .video, source: TimeRange(start: .zero, duration: f(150)), start: .zero)
        let upper = Clip(name: "B", media: b, kind: .video, source: TimeRange(start: f(30), duration: f(90)), start: f(30))
        let tl = Timeline(name: "cover", format: SequenceFormat(width: spec.width, height: spec.height, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [lower]), Track(kind: .video, clips: [upper])])
        engine.setTimeline(tl)
        let r = Rig(engine: engine, clock: clock, device: device, a: a, b: b, timeline: tl)
        // Paused: the original, opaque.
        _ = try await show(engine, 40)
        #expect(try await show(engine, 50).hidden == 1)
        // Playing: the proxy, which carries alpha. Once its first frame is drawn nothing is hidden, and A is decoded.
        engine.play()
        var last: TickProfile?
        await play(r, frames: 30) { last = $0 }
        let p = try #require(last)
        #expect(p.hidden == 0 && p.layers == 2 && p.missing == 0, "hidden \(p.hidden), layers \(p.layers), missing \(p.missing)")
        // Paused again: back on the original, the layer below is hidden again.
        engine.pause()
        #expect(try await show(engine, 90).hidden == 1)
    }
}

/// Originals that can go away (a file moved while the project is open).
private final class SwitchResolver: MediaResolver, Sendable {
    private let demuxers: Mutex<[UUID: any Demuxing]>
    init(_ d: [UUID: any Demuxing]) { demuxers = Mutex(d) }
    func remove(_ id: UUID) { demuxers.withLock { $0[id] = nil } }
    func demuxer(for media: UUID) throws -> any Demuxing {
        guard let d = demuxers.withLock({ $0[media] }) else { throw MediaResolverError.unknownMedia(media) }
        return d
    }
    func audio(for media: UUID) throws -> any AudioSource { throw MediaResolverError.unknownMedia(media) }
}
