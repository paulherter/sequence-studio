import Testing
import Foundation
import Metal
import Synchronization
import SQCore
import SQMedia
import SQMediaTestSupport
import SQRender
@testable import SQPlayback

// FB-H2: review fixes to the FB-H scrub stand-ins. A relink or proxy change never leaves old-file frames as stand-ins
// (neither from a tick that overlapped it nor from a job that finished before the scheduler forgot it), nested sequence
// instances keep their own stand-in, Frame Blending never mixes a stand-in, a capped hold resets, and a paused edit is not
// held for a cold layer at the position already presented.

private let fd = Time(1, 30)

private actor StandInClip {
    static let shared = StandInClip()
    private var url: URL?
    func get() async throws -> URL {
        if let url { return url }
        var spec = TestClipSpec()
        spec.frameCount = 90
        spec.frameDuration = TestClipSpec.fps(30)
        let u = try await TestClipWriter.write(spec)
        url = u
        return u
    }
}

@Suite(.serialized) @MainActor struct ScrubStandInFixesTests {
    struct Rig { let e: PlaybackEngine; let idx: SampleIndex; let m: UUID; let m2: UUID }

    private func clip(_ media: UUID, name: String = "V") -> Clip {
        Clip(name: name, media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 90), start: .zero, mediaDuration: fd * 90)
    }

    private func rig(twoLayers: Bool = false) async throws -> Rig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await StandInClip.shared.get()
        let demuxer = try await AVDemuxer(url: url)
        let m = UUID(), m2 = UUID()
        let e = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [m: demuxer, m2: demuxer]), clock: ManualClock())
        e.scrubRefineDelay = nil
        var tracks = [Track(kind: .video, clips: [clip(m)])]
        if twoLayers {
            var c = clip(m2, name: "V2")
            c.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
            tracks.append(Track(kind: .video, clips: [c]))
        }
        e.setTimeline(Timeline(name: "S", format: SequenceFormat(width: 320, height: 180, frameDuration: fd), tracks: tracks))
        return Rig(e: e, idx: demuxer.index, m: m, m2: m2)
    }

    private func settle(_ e: PlaybackEngine, until done: () -> Bool) async {
        for _ in 0..<SQTiming.polls(50) where !done() {
            _ = e.tick()
            await e.waitForDecodes()
        }
        _ = e.tick()
    }

    private func stallDecodes(_ e: PlaybackEngine) {
        let s = DecodeScheduler(decoder: { _ in throw CancellationError() }, sink: { _, _ in })
        e.loop.state.withLock { $0.scheduler = s }
    }

    private func put(_ r: Rig, _ f: Int, media: UUID? = nil, from template: DecodedFrame) {
        let id = media ?? r.m
        let pts = r.idx.entries[f].pts
        r.e.loop.cache.insert(DecodedFrame(media: id, pts: pts, duration: fd, pixelBuffer: template.pixelBuffer),
                              for: FrameKey(media: id, pts: pts, scale: .full))
    }

    private func warmStart(_ r: Rig) async throws -> DecodedFrame {
        r.e.seek(to: .zero)
        await settle(r.e) { r.e.stats.stepLatencies.count == 1 }
        await r.e.waitForDecodes()
        let t = try #require(r.e.loop.cache.frame(FrameKey(media: r.m, pts: r.idx.entries[0].pts, scale: .full)))
        stallDecodes(r.e)
        return t
    }

    // (1) A relink that lands while a tick composites old-file frames: the tick does not refill the stand-ins.
    @Test func relinkDuringATickDoesNotRefillTheStandIns() async throws {
        let r = try await rig()
        let tmpl = try await warmStart(r)
        #expect(!r.e.loop.lastShownByClip.withLock { $0.isEmpty })
        put(r, 30, from: tmpl)
        let loop = r.e.loop, m = r.m
        let fired = Mutex(false)
        loop.state.withLock { $0.afterLayers = {
            guard !fired.withLock({ f in defer { f = true }; return f }) else { return }
            loop.mediaChanged([m])
        } }
        r.e.seek(to: r.idx.entries[30].pts)
        let before = r.e.stats.presentedFrames
        _ = r.e.tick()
        loop.state.withLock { $0.afterLayers = nil }
        #expect(r.e.stats.presentedFrames == before + 1)      // the old picture was still drawn this once
        #expect(loop.lastShownByClip.withLock { $0.isEmpty })  // but not kept as a stand-in
    }

    // (1) A tick between the relink and the scheduler settling may store old-file stand-ins: the settle step drops them.
    @Test func relinkCleanUpDropsStandInsTakenBeforeTheSchedulerSettled() async throws {
        let r = try await rig()
        _ = try await warmStart(r)
        let old = r.e.loop.lastShownByClip.withLock { $0 }
        #expect(!old.isEmpty)
        r.e.loop.mediaChanged([r.m])
        r.e.loop.lastShownByClip.withLock { $0 = old }          // refilled by a tick from an old-file frame
        await r.e.waitForDecodes()
        #expect(r.e.loop.lastShownByClip.withLock { $0.isEmpty })
    }

    // (2) Two instances of one nested sequence share the inner clip's ID: each keeps its own stand-in.
    @Test func nestedInstancesKeepTheirOwnStandIn() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await StandInClip.shared.get()
        let demuxer = try await AVDemuxer(url: url)
        let m = UUID()
        let e = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [m: demuxer]), clock: ManualClock())
        let format = SequenceFormat(width: 320, height: 180, frameDuration: fd)
        let inner = Timeline(name: "Inner", format: format, tracks: [Track(kind: .video, clips: [clip(m)])])
        func nest(_ name: String, from f: Int64) -> Clip {
            Clip(name: name, media: inner.id, kind: .video, source: TimeRange(start: fd * f, duration: fd * 30), start: .zero,
                 mediaDuration: fd * 90, sequence: inner.id)
        }
        var top = nest("B", from: 40)
        top.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
        e.setTimeline(Timeline(name: "S", format: format, tracks: [Track(kind: .video, clips: [nest("A", from: 0)]),
                                                                   Track(kind: .video, clips: [top])]),
                      sequences: [inner.id: inner])
        e.seek(to: .zero)
        await settle(e) { e.stats.stepLatencies.count == 1 && !e.loop.state.withLock { $0.incomplete } }
        let shown = e.loop.lastShownByClip.withLock { $0 }
        #expect(shown.count == 2)
        #expect(Set(shown.keys.map(\.clip)).count == 1)
        #expect(Set(shown.values.map(\.frame.pts)) == [demuxer.index.entries[0].pts, demuxer.index.entries[40].pts])
    }

    // (3) Frame Blending only mixes the exact frame of the source with the next, never a stand-in.
    @Test func frameBlendNeedsTheExactFrame() async throws {
        let r = try await rig()
        let tmpl = try await warmStart(r)
        var req = LayerRequest(clip: UUID(), media: r.m, track: UUID(), sourceTime: r.idx.entries[10].pts + Time(1, 60))
        req.interpolation = .frameBlend
        func frame(_ f: Int, media: UUID? = nil) -> DecodedFrame {
            DecodedFrame(media: media ?? r.m, pts: r.idx.entries[f].pts, duration: fd, pixelBuffer: tmpl.pixelBuffer)
        }
        #expect(RenderLoop.blends(req, frame: frame(10), sid: r.m, scrub: false, f: 10, in: r.idx))
        #expect(!RenderLoop.blends(req, frame: frame(8), sid: r.m, scrub: false, f: 10, in: r.idx))   // stand-in
        #expect(!RenderLoop.blends(req, frame: frame(10, media: UUID()), sid: r.m, scrub: false, f: 10, in: r.idx))
        #expect(!RenderLoop.blends(req, frame: frame(10), sid: r.m, scrub: true, f: 10, in: r.idx))
        req.interpolation = .frameSampling
        #expect(!RenderLoop.blends(req, frame: frame(10), sid: r.m, scrub: false, f: 10, in: r.idx))
        #expect(RenderLoop.flowRequest(req, sid: r.m, from: .zero, to: fd, playing: false) == nil)
        // Optical flow mixes the same pair; the flow is keyed by the pair, settled frames at export quality.
        req.interpolation = .opticalFlow
        #expect(RenderLoop.blends(req, frame: frame(10), sid: r.m, scrub: false, f: 10, in: r.idx))
        let a = r.idx.entries[10].pts, b = r.idx.entries[11].pts
        let settled = try #require(RenderLoop.flowRequest(req, sid: r.m, from: a, to: b, playing: false))
        #expect(settled.quality == .better && settled.key == FlowPairKey(media: r.m, from: a, to: b))
        #expect(RenderLoop.flowRequest(req, sid: r.m, from: a, to: b, playing: true)?.quality == .faster)
    }

    // (4) + (5) A capped hold resets when its composite is presented, and a paused edit at that position composites at once.
    @Test func cappedHoldResetsAndAPausedEditIsNotHeld() async throws {
        let r = try await rig(twoLayers: true)
        let tmpl = try await warmStart(r)
        r.e.loop.cache.remove(media: r.m2)                   // V2 has no picture at all
        r.e.loop.lastShownByClip.withLock { $0.removeAll() }
        put(r, 60, from: tmpl)
        r.e.loop.state.withLock { $0.holdLimit = .zero }     // the hold runs out at once
        let presented = r.e.stats.presentedFrames, ph = r.e.stats.placeholderComposites
        r.e.seek(to: r.idx.entries[60].pts)
        _ = r.e.tick()
        #expect(r.e.stats.presentedFrames == presented + 1)
        #expect(r.e.stats.placeholderComposites == ph + 1)
        #expect(r.e.loop.state.withLock { $0.holdStart == nil })
        // An edit while V2 is still cold: the position is already presented, so nothing waits for V2.
        r.e.loop.state.withLock { $0.holdLimit = .seconds(1) }
        r.e.loop.invalidate()
        _ = r.e.tick()
        #expect(r.e.stats.presentedFrames == presented + 2)
        // Paused, a playhead move still holds for a cold layer among others; all layers cold holds either way.
        #expect(RenderLoop.shouldHold(noFrame: 1, layers: 2, solids: 0, coldInTransition: 0, hasLast: true, playing: false, moved: true))
        #expect(!RenderLoop.shouldHold(noFrame: 1, layers: 2, solids: 0, coldInTransition: 0, hasLast: true, playing: false, moved: false))
        #expect(RenderLoop.shouldHold(noFrame: 2, layers: 2, solids: 0, coldInTransition: 0, hasLast: true, playing: false, moved: false))
        #expect(RenderLoop.shouldHold(noFrame: 1, layers: 2, solids: 0, coldInTransition: 1, hasLast: true, playing: false, moved: false))
    }
}
