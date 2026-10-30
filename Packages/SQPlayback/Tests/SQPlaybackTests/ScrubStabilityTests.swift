import Testing
import Foundation
import Metal
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

// FB-H: scrub stability. While a frame is still decoding the picture never jumps off the drag path (a backward drag must
// not show the cached start of the clip and then jump forward again), a cached frame between the keyframe and the target
// beats the keyframe, a release after a proxy scrub keeps the proxy picture until the original lands, a cold layer among
// others is held instead of drawn gray while paused, and resting during a drag refines to the exact frame.

private let fd = Time(1, 30)

private actor StabilityClip {
    static let shared = StabilityClip()
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

@Suite(.serialized) @MainActor struct ScrubStabilityTests {
    struct Rig { let e: PlaybackEngine; let idx: SampleIndex; let m: UUID; let m2: UUID }

    /// One 90-frame clip on V1 (and the same file as a second media on V2 when `twoLayers`), proxies optional.
    private func rig(proxy: Bool = false, twoLayers: Bool = false) async throws -> Rig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await StabilityClip.shared.get()
        let demuxer = try await AVDemuxer(url: url)
        let m = UUID(), m2 = UUID()
        var proxies: [UUID: any Demuxing] = [:]
        if proxy { proxies[m] = try await AVDemuxer(url: url) }
        let e = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [m: demuxer, m2: demuxer], proxies: proxies),
                                   clock: ManualClock())
        e.scrubRefineDelay = nil
        var tracks = [Track(kind: .video, clips: [Clip(name: "V", media: m, kind: .video, source: TimeRange(start: .zero, duration: fd * 90),
                                                      start: .zero, mediaDuration: fd * 90)])]
        if twoLayers {
            var c = Clip(name: "V2", media: m2, kind: .video, source: TimeRange(start: .zero, duration: fd * 90), start: .zero, mediaDuration: fd * 90)
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

    /// From here on nothing decodes (every job fails silently): the cache holds only what the test put there.
    private func stallDecodes(_ e: PlaybackEngine) {
        let s = DecodeScheduler(decoder: { _ in throw CancellationError() }, sink: { _, _ in })
        e.loop.state.withLock { $0.scheduler = s }
    }

    /// A decoded frame re-keyed as frame `f` of `media` (stands in for a decode that landed).
    private func put(_ r: Rig, _ f: Int, media: UUID? = nil, from template: DecodedFrame) {
        let id = media ?? r.m
        let pts = r.idx.entries[f].pts
        r.e.loop.cache.insert(DecodedFrame(media: id, pts: pts, duration: fd, pixelBuffer: template.pixelBuffer),
                              for: FrameKey(media: id, pts: pts, scale: .full))
    }

    private func keyframe(_ r: Rig, _ f: Int) -> Int { PrefetchPlanner.scrubFrame(for: f, in: r.idx) }

    /// Opens the clip (real decode of the start), then stalls the decoder and returns frame 0 as a template.
    private func warmStart(_ r: Rig) async throws -> DecodedFrame {
        r.e.seek(to: .zero)
        await settle(r.e) { r.e.stats.stepLatencies.count == 1 }
        await r.e.waitForDecodes()
        let t = try #require(r.e.loop.cache.frame(FrameKey(media: r.m, pts: r.idx.entries[0].pts, scale: .full)))
        stallDecodes(r.e)
        return t
    }

    @Test func backwardDragIntoAColdGOPKeepsThePictureOnThePath() async throws {
        let r = try await rig()
        let tmpl = try await warmStart(r)
        let startCached = (0..<r.idx.count).filter { r.e.cachedFrame(media: r.m, pts: r.idx.entries[$0].pts) }
        #expect(startCached.contains(0) && (startCached.max() ?? 0) < 40)
        put(r, 80, from: tmpl)
        r.e.seek(to: r.idx.entries[80].pts)
        _ = r.e.tick()
        #expect(r.e.stats.lastShownPTS == r.idx.entries[80].pts)
        let ph = r.e.stats.placeholderComposites
        r.e.beginScrub()
        r.e.scrub(to: r.idx.entries[50].pts)                 // keyframe of 50 not decoded yet
        _ = r.e.tick()
        let shown = try #require(r.e.stats.lastShownPTS)
        // On the path between the picture (80) and the target's keyframe..target, never back at the cached start.
        #expect(shown >= r.idx.entries[keyframe(r, 50)].pts)
        #expect(shown <= r.idx.entries[80].pts)
        #expect(r.e.stats.placeholderComposites == ph)
        r.e.endScrub()
    }

    @Test func forwardDragIntoAColdGOPDoesNotJumpBack() async throws {
        let r = try await rig()
        let tmpl = try await warmStart(r)
        put(r, 40, from: tmpl)
        r.e.seek(to: r.idx.entries[40].pts)
        _ = r.e.tick()
        r.e.beginScrub()
        r.e.scrub(to: r.idx.entries[70].pts)
        _ = r.e.tick()
        let shown = try #require(r.e.stats.lastShownPTS)
        #expect(shown >= r.idx.entries[40].pts)              // not the cached start (nearest earlier would be fine only if >= 40)
        r.e.endScrub()
    }

    @Test func cachedFrameBetweenKeyframeAndTargetBeatsTheKeyframe() async throws {
        let r = try await rig()
        let tmpl = try await warmStart(r)
        let target = (40..<80).first { keyframe(r, $0) <= $0 - 4 }!
        let k = keyframe(r, target)
        put(r, k, from: tmpl)
        put(r, target - 2, from: tmpl)                      // a GOP decode delivered up to here so far
        r.e.beginScrub()
        let n = r.e.stats.scrubLatencies.count
        r.e.scrub(to: r.idx.entries[target].pts)
        _ = r.e.tick()
        #expect(r.e.stats.lastShownPTS == r.idx.entries[target - 2].pts)
        #expect(r.e.stats.scrubLatencies.count == n + 1)     // counts as landed: nothing to wait for
        r.e.endScrub()
    }

    @Test func releaseAfterAProxyScrubKeepsTheProxyPicture() async throws {
        let r = try await rig(proxy: true)
        r.e.seek(to: .zero)
        await settle(r.e) { r.e.stats.stepLatencies.count == 1 }
        await r.e.waitForDecodes()
        let target = (40..<80).first { keyframe(r, $0) < $0 }!
        r.e.beginScrub()
        r.e.scrub(to: r.idx.entries[target].pts)
        await settle(r.e) { r.e.stats.scrubLatencies.count == 1 }
        let scrubShown = try #require(r.e.stats.lastShownPTS)
        #expect(scrubShown >= r.idx.entries[keyframe(r, target)].pts)
        stallDecodes(r.e)
        let ph = r.e.stats.placeholderComposites
        r.e.endScrub()                                       // originals from here on: none decoded near the target
        _ = r.e.tick()
        let shown = try #require(r.e.stats.lastShownPTS)
        #expect(shown == scrubShown)                         // no detour back to the cached start of the original
        #expect(r.e.stats.placeholderComposites == ph)
    }

    @Test func pausedColdLayerAmongOthersIsHeldNotDrawnGrey() async throws {
        let r = try await rig(twoLayers: true)
        r.e.seek(to: .zero)
        await settle(r.e) { r.e.stats.stepLatencies.count == 1 }
        await r.e.waitForDecodes()
        let tmpl = try #require(r.e.loop.cache.frame(FrameKey(media: r.m, pts: r.idx.entries[0].pts, scale: .full)))
        stallDecodes(r.e)
        r.e.loop.cache.remove(media: r.m2)                   // V2 has no frame at all now (and none shown at 60)
        r.e.loop.lastShownByClip.withLock { $0.removeAll() }
        put(r, 60, from: tmpl)                               // V1 at 60 is ready
        let presented = r.e.stats.presentedFrames, ph = r.e.stats.placeholderComposites
        r.e.seek(to: r.idx.entries[60].pts)
        _ = r.e.tick()
        #expect(r.e.stats.placeholderComposites == ph)
        #expect(r.e.stats.presentedFrames == presented)      // held (the old picture stays) instead of a gray V2
        // Playing, one cold layer among others still composites (never freeze playback on one slow layer).
        #expect(!RenderLoop.shouldHold(noFrame: 1, layers: 2, solids: 0, coldInTransition: 0, hasLast: true, playing: true))
        #expect(RenderLoop.shouldHold(noFrame: 1, layers: 2, solids: 0, coldInTransition: 0, hasLast: true, playing: false))
    }

    @Test func restingDuringADragRefinesToTheExactFrame() async throws {
        let r = try await rig()
        r.e.seek(to: .zero)
        await settle(r.e) { r.e.stats.stepLatencies.count == 1 }
        await r.e.waitForDecodes()
        r.e.scrubRefineDelay = .milliseconds(20)
        let target = (40..<80).first { keyframe(r, $0) < $0 }!
        r.e.beginScrub()
        r.e.scrub(to: r.idx.entries[target].pts)
        await settle(r.e) { r.e.stats.scrubLatencies.count == 1 }
        // Hold still: after the rest delay the exact frame is decoded and shown, still inside the gesture.
        for _ in 0..<SQTiming.polls(100) where r.e.stats.lastShownPTS != r.idx.entries[target].pts {
            try await Task.sleep(for: .milliseconds(10))
            _ = r.e.tick()
            await r.e.waitForDecodes()
        }
        #expect(r.e.stats.lastShownPTS == r.idx.entries[target].pts)
        #expect(r.e.loop.isScrubbing)
        // Moving on drops back to keyframes (no exact GOP for every position).
        let mark = r.e.decodeCalls
        r.e.scrubRefineDelay = nil
        let next = (target + 13 < 90) ? target + 13 : target - 13
        r.e.scrub(to: r.idx.entries[next].pts)
        await settle(r.e) { r.e.stats.scrubLatencies.count >= 2 }
        let k = keyframe(r, next)
        #expect(keyframesOnly(r, r.e.decodeRanges(since: mark), including: k))
        r.e.endScrub()
    }

    /// Every half-float of a rendered texture (blit to a shared buffer).
    private func pixels(_ texture: MTLTexture) throws -> [Float16] {
        let w = texture.width, h = texture.height, bpr = w * 8
        let device = texture.device
        let queue = try #require(device.makeCommandQueue())
        let buf = try #require(device.makeBuffer(length: bpr * h, options: .storageModeShared))
        let cb = try #require(queue.makeCommandBuffer()), blit = try #require(cb.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: Float16.self), count: w * h * 4))
    }

    /// Golden: the exact frame a slow drag shows, and the settled frame after release, are pixel-identical to a plain
    /// paused seek to that frame (the reference render) on a fresh engine.
    @Test func slowDragExactFrameMatchesAPausedSeek() async throws {
        let r = try await rig(twoLayers: true)
        r.e.seek(to: .zero)
        await settle(r.e) { r.e.stats.stepLatencies.count == 1 }
        let target = (40..<80).first { keyframe(r, $0) < $0 - 2 }!
        r.e.beginScrub()
        r.e.scrub(to: r.idx.entries[target - 2].pts)
        r.e.scrub(to: r.idx.entries[target - 1].pts)
        r.e.scrub(to: r.idx.entries[target].pts)
        await settle(r.e) { r.e.stats.lastShownPTS == r.idx.entries[target].pts }
        await r.e.waitForDecodes(); _ = r.e.tick()
        #expect(r.e.stats.lastShownPTS == r.idx.entries[target].pts)
        let dragged = try pixels(try #require(r.e.lastRenderedTexture))
        let steps = r.e.stats.stepLatencies.count
        r.e.endScrub()
        await settle(r.e) { r.e.stats.stepLatencies.count > steps }
        await r.e.waitForDecodes(); _ = r.e.tick()
        let released = try pixels(try #require(r.e.lastRenderedTexture))

        let ref = try await rig(twoLayers: true)
        ref.e.seek(to: ref.idx.entries[target].pts)
        await settle(ref.e) { ref.e.stats.stepLatencies.count == 1 && ref.e.stats.lastShownPTS == ref.idx.entries[target].pts }
        await ref.e.waitForDecodes(); _ = ref.e.tick()
        let reference = try pixels(try #require(ref.e.lastRenderedTexture))
        #expect(dragged == reference)
        #expect(released == reference)
    }

    /// Single sync frames only: the playhead's `k` (unless cached already), plus at most the next keyframe in the drag direction.
    private func keyframesOnly(_ r: Rig, _ ranges: [ClosedRange<Int>], including k: Int) -> Bool {
        ranges.count <= 2 && ranges.filter { $0 != k...k }.count <= 1
            && ranges.allSatisfy { $0.count == 1 && r.idx.entries[$0.lowerBound].isSync }
    }

    /// A fast drag that rests plans the exact window around the playhead (both directions), not the slow-drag window
    /// (forward only in the last move's direction, keyframes first): the rest drops the drag velocity.
    @Test func restAfterAFastDragDropsTheDragVelocity() async throws {
        let r = try await rig()
        r.e.beginScrub()
        r.e.scrub(to: r.idx.entries[10].pts)
        r.e.scrub(to: r.idx.entries[40].pts)                  // a fast move: 30 frames
        #expect(r.e.loop.scrubVelocity == 30)
        let at = r.e.loop.clock.now()
        r.e.loop.refineScrub(at: at)                          // the gesture rests here
        #expect(r.e.loop.scrubVelocity == 0)
        // A slow drag that rests (refine already at the playhead) drops it too.
        r.e.scrub(to: r.idx.entries[41].pts)
        #expect(r.e.loop.scrubVelocity == 1)
        r.e.loop.refineScrub(at: r.e.loop.clock.now())
        #expect(r.e.loop.scrubVelocity == 0)
        r.e.endScrub()
    }

    /// Scrub latency: a slow drag (one frame per move) shows the exact frames at once, without the rest delay; the
    /// keyframe alone would freeze the picture for a whole GOP. A fast move still decodes only the keyframe.
    @Test func slowDragShowsExactFramesWithoutTheRestDelay() async throws {
        let r = try await rig()
        r.e.seek(to: .zero)
        await settle(r.e) { r.e.stats.stepLatencies.count == 1 }
        await r.e.waitForDecodes()
        #expect(r.e.scrubRefineDelay == nil)                  // no rest refine: only the slow-drag rule can show exact frames
        let target = (40..<80).first { keyframe(r, $0) < $0 - 2 }!
        r.e.beginScrub()
        let mark = r.e.decodeCalls
        r.e.scrub(to: r.idx.entries[target - 3].pts)          // the first move of a gesture is a jump: keyframe only
        await settle(r.e) { r.e.stats.scrubLatencies.count == 1 }
        let k = keyframe(r, target)
        #expect(r.e.decodeRanges(since: mark).allSatisfy { $0 == k...k })
        for f in (target - 2)...target {                      // now one frame per move
            r.e.scrub(to: r.idx.entries[f].pts)
            await settle(r.e) { r.e.stats.lastShownPTS == r.idx.entries[f].pts }
            #expect(r.e.stats.lastShownPTS == r.idx.entries[f].pts)
        }
        // The slow drag goes forward: no GOP behind the playhead's was decoded.
        #expect(!r.e.decodeRanges(since: mark).contains { $0.upperBound < k })
        #expect(r.e.loop.isScrubbing)
        // A fast move drops back to keyframes.
        await r.e.waitForDecodes()
        let mark2 = r.e.decodeCalls, n = r.e.stats.scrubLatencies.count
        let next = (target + 13 < 90) ? target + 13 : target - 13
        r.e.scrub(to: r.idx.entries[next].pts)
        await settle(r.e) { r.e.stats.scrubLatencies.count > n }
        let k2 = keyframe(r, next)
        #expect(keyframesOnly(r, r.e.decodeRanges(since: mark2), including: k2))
        r.e.endScrub()
    }
}
