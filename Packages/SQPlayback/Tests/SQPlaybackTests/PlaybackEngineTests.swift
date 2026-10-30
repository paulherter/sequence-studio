import Testing
import Foundation
import CoreMedia
import Metal
import Synchronization
import SQCore
import SQText
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

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

private final class CalledFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

private final class BoxedTexture: @unchecked Sendable {
    let texture: MTLTexture
    init(_ t: MTLTexture) { texture = t }
}

@MainActor private final class ExportSeen {
    var scale: DecodeScale?, paused: Bool?, stamp: Int?, failure: String?
}

/// Every open blocks until `release` is signalled (a stuck resolve: `waitForDecodes` never returns meanwhile).
private final class BlockingResolver: MediaResolver, Sendable {
    let release = DispatchSemaphore(value: 0)
    func demuxer(for media: UUID) throws -> any Demuxing {
        release.wait(); release.signal()
        throw MediaResolverError.unknownMedia(media)
    }
    func audio(for media: UUID) throws -> any AudioSource { throw MediaResolverError.unknownMedia(media) }
}

@MainActor
private struct Rig {
    let engine: PlaybackEngine
    let clock: ManualClock
    let device: MTLDevice
    let media: UUID
    var timeline: Timeline

    static func make(wrap: (any Demuxing) -> any Demuxing = { $0 }, _ build: (UUID) -> Timeline) async throws -> Rig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await SharedClip.shared.get()
        let demuxer = wrap(try await AVDemuxer(url: url))
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
    /// Frame capture (eyedropper, Auto, thumbnails): copies the frame on the loop's own command buffer, so what it reads
    /// is exactly the frame that was rendered, never a half-written next one, and nothing waits for the GPU on the caller.
    @Test func frameCaptureReturnsTheRenderedFrameAndCoalescesPerKey() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        let device = rig.device
        func capture(key: String = "t") async -> Int? {
            await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
                e.requestFrameCapture(key: key) { frame, cb in
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: frame.pixelFormat, width: frame.width, height: frame.height, mipmapped: false)
                    guard let copy = device.makeTexture(descriptor: d), let blit = cb.makeBlitCommandEncoder() else { cont.resume(returning: nil); return nil }
                    blit.copy(from: frame, to: copy)
                    blit.endEncoding()
                    let box = BoxedTexture(copy)
                    return { cont.resume(returning: readStamp(box.texture, device: device)) }
                }
            }
        }
        e.seek(to: Time(10, 30))
        await e.waitForDecodes()
        // A request made while a render is due (the seek invalidated the loop) is served by that render.
        async let early = capture()
        try await Task.sleep(for: .milliseconds(50))
        _ = rig.tick()
        #expect(await early == 10)
        // An idle loop (nothing to render) serves it from its own command buffer: the same frame.
        #expect(await capture() == 10)
        // The next frame is captured as that frame.
        e.seek(to: Time(11, 30))
        await e.waitForDecodes()
        async let next = capture()
        try await Task.sleep(for: .milliseconds(50))
        _ = rig.tick()
        #expect(await next == 11)
        // Same key: only the newest request survives (the older completion is dropped, never called).
        let oldCalled = CalledFlag()
        e.seek(to: Time(12, 30)); await e.waitForDecodes()
        e.requestFrameCapture(key: "k") { _, _ in oldCalled.set(); return nil }
        async let newer = capture(key: "k")
        try await Task.sleep(for: .milliseconds(50))
        _ = rig.tick()
        #expect(await newer == 12)
        #expect(!oldCalled.value)
        // Different keys do not replace each other.
        e.seek(to: Time(13, 30)); await e.waitForDecodes()
        async let a = capture(key: "a")
        async let b = capture(key: "b")
        try await Task.sleep(for: .milliseconds(50))
        _ = rig.tick()
        let (ra, rb) = await (a, b)
        #expect(ra == 13 && rb == 13)
    }

    /// Start gate: play right after a seek into undecoded media holds the clock (and audio) at the start frame until it is
    /// decoded, then runs from exactly there: no placeholders, no skipped or dropped frames at the start.
    @Test func playAfterSeekWaitsForTheStartFrame() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.seek(to: .zero)
        await e.waitForDecodes()
        #expect(rig.tick() == 0)

        e.seek(to: fd * 40)
        e.play()
        #expect(e.rate == .forward)
        #expect(rig.clock.rate.isPaused)                 // held: frame 40 is not decoded yet
        rig.clock.advance(by: fd * 5)
        _ = e.tick()
        #expect(rig.clock.now() == fd * 40)
        await e.waitForDecodes()
        var stamps: [Int] = []
        if let s = rig.tick() { stamps.append(s) }
        #expect(rig.clock.rate == .forward)              // started on the tick that had the exact frame
        for _ in 0..<5 {
            await e.waitForDecodes()
            rig.clock.advance(by: fd)
            if let s = rig.tick() { stamps.append(s) }
        }
        #expect(stamps == Array(40...45))
        #expect(e.stats.placeholderComposites == 0)
        #expect(e.stats.droppedFrames == 0)
    }

    /// Pause during the start gate: the clock never starts.
    @Test func pauseCancelsTheStartGate() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.seek(to: .zero)
        await e.waitForDecodes()
        _ = rig.tick()
        e.seek(to: fd * 40)
        e.play()
        e.pause()
        await e.waitForDecodes()
        _ = rig.tick()
        #expect(rig.clock.rate.isPaused)
        rig.clock.advance(by: fd * 3)
        _ = rig.tick()
        #expect(rig.clock.now() == fd * 40)
    }

    /// A seek that lands after a tick decided to open the gate (render thread) but before the clock started (main actor):
    /// the open is dropped, the gate waits afresh at the new position and starts there.
    @Test func seekDuringGateOpenIsNotLost() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.seek(to: .zero)
        await e.waitForDecodes()
        _ = rig.tick()
        e.seek(to: fd * 40)
        e.play()
        await e.waitForDecodes()
        _ = e.loop.tick()                                  // render thread: frame 40 ready, open requested
        #expect(rig.clock.rate.isPaused)                   // the clock starts only on the main actor
        e.seek(to: fd * 20)
        e.performStartGateOpen()
        #expect(rig.clock.rate.isPaused)
        #expect(rig.clock.now() == fd * 20)
        #expect(e.loop.isWaitingToStart)
        await e.waitForDecodes()
        #expect(rig.tick() == 20)
        #expect(rig.clock.rate == .forward)
        #expect(rig.clock.now() == fd * 20)
    }

    /// A pause between the render thread's open request and the main actor's start: the clock stays stopped.
    @Test func pauseDuringGateOpenKeepsTheClockStopped() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.seek(to: .zero)
        await e.waitForDecodes()
        _ = rig.tick()
        e.seek(to: fd * 40)
        e.play()
        await e.waitForDecodes()
        _ = e.loop.tick()
        e.pause()
        e.performStartGateOpen()
        #expect(rig.clock.rate.isPaused)
        #expect(e.rate.isPaused)
        #expect(!e.loop.isWaitingToStart)
    }

    /// The start frame was shown complete but its frames were evicted since: play still waits for them.
    @Test func playWaitsWhenTheShownStartFrameIsNoLongerCached() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.seek(to: fd * 40)
        await e.waitForDecodes()
        #expect(rig.tick() == 40)
        e.loop.cache.remove(media: rig.media)
        e.play()
        #expect(rig.clock.rate.isPaused)
        #expect(e.loop.isWaitingToStart)
    }

    /// The gate's limit runs without ticks (no monitor attached): the clock starts after it at the start frame.
    @Test func gateLimitStartsTheClockWithoutTicks() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.loop.startGateLimit = .milliseconds(50)
        e.seek(to: fd * 40)
        e.play()
        #expect(rig.clock.rate.isPaused)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.clock.rate == .forward)
        #expect(!e.loop.isWaitingToStart)
    }

    /// No timeline: play starts at once (nothing to wait for).
    @Test func playWithoutTimelineDoesNotWait() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let clock = ManualClock()
        let e = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [:]), clock: clock)
        e.play()
        #expect(clock.rate == .forward)
        #expect(!e.loop.isWaitingToStart)
    }

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
        #expect(e.stats.droppedFrames == 0)       // a paused seek waiting for decode is not a drop
    }

    /// Two media ids over one demuxer: the second has nothing in the cache, so its first tick has no frame at all.
    private func coldRig() async throws -> (engine: PlaybackEngine, device: MTLDevice, a: UUID, b: UUID) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let demuxer = try await AVDemuxer(url: try await SharedClip.shared.get())
        let a = UUID(), b = UUID()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [a: demuxer, b: demuxer]),
                                        clock: ManualClock())
        return (engine, device, a, b)
    }

    private func clipTimeline(id: UUID, _ m: UUID) -> Timeline {
        let c = Clip(name: "C", media: m, kind: .video, source: TimeRange(start: .zero, duration: fd * 60),
                     start: .zero, mediaDuration: fd * 60)
        return Timeline(id: id, name: "Seq", format: format, tracks: [Track(kind: .video, clips: [c])])
    }

    @Test func farSeekHoldsLastFrameUntilNewMediaDecoded() async throws {
        let r = try await coldRig()
        let id = UUID()
        r.engine.setTimeline(clipTimeline(id: id, r.a))
        r.engine.seek(to: fd * 10)
        await r.engine.waitForDecodes()
        #expect(r.engine.tick())
        #expect(readStamp(try #require(r.engine.lastRenderedTexture), device: r.device) == 10)

        // Same sequence, material that is not decoded: keep the picture, do not present a black placeholder.
        r.engine.setTimeline(clipTimeline(id: id, r.b))
        #expect(r.engine.tick() == false)
        #expect(readStamp(try #require(r.engine.lastRenderedTexture), device: r.device) == 10)
        await r.engine.waitForDecodes()
        #expect(r.engine.tick())
    }

    @Test func differentSequenceDoesNotShowThePreviousFrame() async throws {
        let r = try await coldRig()
        r.engine.setTimeline(clipTimeline(id: UUID(), r.a))
        r.engine.seek(to: fd * 10)
        await r.engine.waitForDecodes()
        #expect(r.engine.tick())
        r.engine.setTimeline(clipTimeline(id: UUID(), r.b))   // another sequence: its first tick presents (placeholder)
        #expect(r.engine.tick())
    }

    @Test func holdIsBoundedWhenADecodeNeverLands() async throws {
        let r = try await coldRig()
        let id = UUID()
        r.engine.setTimeline(clipTimeline(id: id, r.a))
        r.engine.seek(to: fd * 10)
        await r.engine.waitForDecodes()
        #expect(r.engine.tick())
        r.engine.loop.state.withLock { $0.holdLimit = .zero }
        r.engine.setTimeline(clipTimeline(id: id, r.b))
        #expect(r.engine.tick())                               // limit reached: composite with the placeholder
    }

    /// FB-H: paused, a cold layer among others holds the old picture (no gray layer) until `holdLimit`, then composites.
    /// Playing, it composites at once (`shouldHold(playing:)`, ScrubStabilityTests).
    @Test func oneColdLayerAmongOthersHoldsWhilePausedThenComposites() async throws {
        let r = try await coldRig()
        let id = UUID()
        func two(_ top: UUID) -> Timeline {
            var t = clipTimeline(id: id, r.a)
            let c = Clip(name: "T", media: top, kind: .video, source: TimeRange(start: .zero, duration: fd * 60),
                         start: .zero, mediaDuration: fd * 60)
            t.tracks.append(Track(kind: .video, clips: [c]))
            return t
        }
        r.engine.setTimeline(clipTimeline(id: id, r.a))
        r.engine.seek(to: fd * 10)
        await r.engine.waitForDecodes()
        #expect(r.engine.tick())
        r.engine.setTimeline(two(r.b))                         // V1 is warm, V2 is cold
        #expect(!r.engine.tick())                              // paused: held
        r.engine.loop.state.withLock { $0.holdLimit = .zero }
        r.engine.loop.invalidate()
        #expect(r.engine.tick())                               // limit reached: composites
    }

    @Test func setTimelineAfterTrimRecompositesWithoutFlush() async throws {
        var rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.seek(to: fd * 10)
        await e.waitForDecodes()
        #expect(rig.tick() == 10)
        await e.waitForDecodes()           // prefetch around the playhead settles: a stable baseline
        let cached = e.cacheCount
        #expect(cached > 0)

        // Ripple head trim by 5 frames: the clip still starts at 0, its source starts at 5.
        let clipID = rig.timeline.tracks[0].clips[0].id
        try rig.timeline.rippleTrim(clipID, edge: .head, by: fd * 5)
        e.setTimeline(rig.timeline)
        #expect(e.cacheCount >= cached)    // nothing flushed (new prefetch may add frames, never remove)
        #expect(rig.tick() == 15)          // invalidated: presents again at the same position
        await e.waitForDecodes()
        #expect(e.cacheCount >= cached)
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

    /// Export Frame never bakes a Look hover preview into the picture: it clears it, and none can be set while it waits.
    @Test func exportFrameClearsTheLookPreview() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "x", style: TextStyle(fontName: "Menlo", size: 40, color: .white)), animations: nil)
        e.setLookPreview(.text(container: UUID(), layer: UUID(), from: ref, to: ref))
        #expect(e.loop.lookPreview.set(nil))                                // it was set
        e.setLookPreview(.captions(style: TextStyle(fontName: "Menlo", size: 40, color: .white), animation: nil, karaoke: nil))
        await e.withFullSizeFrame { _ in }
        #expect(!e.loop.lookPreview.set(nil))                               // and Export Frame cleared it
    }

    /// Weak Mac (reduced preview decode): Full quality decodes at half size and keys those frames as half (the key names
    /// the size really decoded). Export Frame renders a true full-size frame and the viewer goes back to half decodes.
    @Test func reducedPreviewDecodeKeysHalfAndExportFrameDecodesFull() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.loop.setReducesFullDecode(true)
        e.seek(to: fd * 5)
        await e.waitForDecodes()
        #expect(rig.tick() == 5)
        let pts = fd * 5
        #expect(e.loop.cache.frame(FrameKey(media: rig.media, pts: pts, scale: .full)) == nil)
        let half = try #require(e.loop.cache.frame(FrameKey(media: rig.media, pts: pts, scale: .half)))
        #expect(CVPixelBufferGetWidth(half.pixelBuffer) == 160)
        var stamp: Int?
        await e.withFullSizeFrame { r in if case .frame(let tex) = r { stamp = readStamp(tex, device: rig.device) } }
        #expect(stamp == 5)
        let full = try #require(e.loop.cache.frame(FrameKey(media: rig.media, pts: pts, scale: .full)))
        #expect(CVPixelBufferGetWidth(full.pixelBuffer) == 320)
        #expect(e.loop.decodeScale == .half)          // back to the reduced preview decode
        #expect(e.quality == .full)
    }

    /// Export Frame review 1+2: while the full-size render waits, a quality change is deferred (not applied half-way), a
    /// second Export Frame is refused (one save sheet), and Play is ignored (the frame stays the paused playhead frame).
    @Test func exportFrameIgnoresQualityPlayAndASecondExportWhileWaiting() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.loop.setReducesFullDecode(true)
        e.seek(to: fd * 5)
        await e.waitForDecodes()
        #expect(rig.tick() == 5)
        let seen = ExportSeen()
        let device = rig.device
        let first = Task { @MainActor in
            await e.withFullSizeFrame { r in
                seen.scale = e.loop.decodeScale
                seen.paused = e.rate.isPaused
                if case .frame(let tex) = r { seen.stamp = readStamp(tex, device: device) } else { seen.failure = "\(r)" }
            }
        }
        for _ in 0..<1000 where !e.isExportingFrame { await Task.yield() }
        #expect(e.isExportingFrame)
        e.quality = .half
        e.play()
        var second: FullSizeFrameResult?
        await e.withFullSizeFrame { second = $0 }
        if case .failed(.busy) = second {} else { Issue.record("second export must be refused, got \(String(describing: second))") }
        await first.value
        #expect(seen.failure == nil)
        #expect(seen.stamp == 5)
        #expect(seen.scale == .full, "decoded at full size although the quality changed during the wait")
        #expect(seen.paused == true)
        #expect(!e.isExportingFrame)
        #expect(e.loop.decodeScale == .half, "the deferred quality (half) applies after the export")
        #expect(e.rate.isPaused)
    }

    /// Export Frame review 3: a decode that never finishes ends in a timeout (no hang), the viewer quality is restored.
    @Test func exportFrameTimesOutOnAStuckDecode() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resolver = BlockingResolver()
        defer { resolver.release.signal() }
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        engine.loop.setReducesFullDecode(true)
        engine.setTimeline(Rig.single(UUID()))
        engine.fullSizeFrameTimeout = .milliseconds(300)
        let t0 = ContinuousClock.now
        var result: FullSizeFrameResult?
        await engine.withFullSizeFrame { result = $0 }
        if case .failed(.timedOut) = result {} else { Issue.record("expected a timeout, got \(String(describing: result))") }
        #expect(ContinuousClock.now - t0 < .seconds(3))
        #expect(!engine.isExportingFrame)
        #expect(engine.loop.decodeScale == .half)
    }

    /// Export Frame review 4: a frame that cannot complete (offline media) is reported, not exported as a placeholder,
    /// and without waiting for the timeout.
    @Test func exportFrameReportsAnIncompleteFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock())
        engine.setTimeline(Rig.single(UUID()))
        await engine.waitForDecodes()
        _ = engine.tick()
        let t0 = ContinuousClock.now
        var result: FullSizeFrameResult?
        await engine.withFullSizeFrame { result = $0 }
        if case .failed(.incomplete) = result {} else { Issue.record("expected incomplete, got \(String(describing: result))") }
        #expect(ContinuousClock.now - t0 < .seconds(2))
    }

    /// Export Frame review 5: a render that gave up after `maxRenderRetries` is not a complete frame (the last presented
    /// one is stale).
    @Test func renderThatGaveUpIsNotComplete() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.seek(to: fd * 5)
        await e.waitForDecodes()
        #expect(rig.tick() == 5)
        #expect(e.loop.lastFrameComplete)
        var tl = rig.timeline
        tl.format = SequenceFormat(width: 0, height: 0, frameDuration: fd)        // no render target can be made
        e.setTimeline(tl)
        await e.waitForDecodes()
        for _ in 0..<(RenderLoop.maxRenderRetries + 3) { _ = e.tick() }
        #expect(e.loop.state.withLock { $0.renderedGeneration == $0.generation }, "gave up")
        #expect(!e.loop.lastFrameComplete)
    }

    @Test func offlineMediaDrawsPlaceholder() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock())
        engine.setTimeline(Rig.single(UUID()))
        #expect(engine.tick())
        #expect(engine.lastRenderedTexture != nil)
        #expect(engine.stats.presentedFrames == 1)
    }

    // MARK: Review regressions

    @Test func invalidationDuringTickIsNotLost() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let hook = Hook()
        let engine = try PlaybackEngine(device: device, media: HookResolver(hook: hook), clock: ManualClock())
        engine.setTimeline(Rig.single(UUID()))          // offline media: the composite is complete (placeholder)
        let loop = engine.loop
        hook.set { loop.invalidate() }                  // fires inside the tick, while resolving the layer's media
        #expect(engine.tick())
        #expect(engine.tick())                          // the invalidation from inside the first tick still renders
        #expect(engine.tick() == false)
    }

    @Test func publishMergesOutcomes() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock())
        let loop = engine.loop
        #expect(loop.publish(TickOutcome(presented: true, time: fd * 5, stoppedAtEdge: false)))
        #expect(!loop.publish(TickOutcome(presented: false, time: fd * 5, stoppedAtEdge: false)))
        #expect(!loop.publish(TickOutcome(presented: false, time: fd * 6, stoppedAtEdge: true)))
        let o = try #require(loop.takeOutcome())
        #expect(o.presented && o.stoppedAtEdge && o.time == fd * 5)
        #expect(!loop.publish(TickOutcome(presented: false, time: fd * 7, stoppedAtEdge: false)))   // idle: no hop
        #expect(loop.takeOutcome() == nil)
    }

    @Test func frameIndexClampsToFirstAndLast() {
        let entries = (0..<4).map { SampleIndex.Entry(pts: fd * Int64($0), dts: fd * Int64($0), duration: fd, isSync: $0 == 0, decodeOrdinal: $0) }
        let index = SampleIndex(entries: entries)
        #expect(RenderLoop.frameIndex(fd * -2, in: index) == 0)
        #expect(RenderLoop.frameIndex(fd * 2, in: index) == 2)
        #expect(RenderLoop.frameIndex(fd * 9, in: index) == 3)
    }

    @Test func setTimelineClearsDamage() async throws {
        let flaky = Flaky()
        var rig = try await Rig.make(wrap: { FlakyDemuxer(inner: $0, flaky: flaky) }, Rig.single)
        let e = rig.engine
        flaky.set(true)
        e.seek(to: fd * 10)
        await e.waitForDecodes()
        _ = e.tick()
        #expect(rig.stamp() != 10)                      // damaged placeholder
        flaky.set(false)
        rig.timeline.name = "edited"
        e.setTimeline(rig.timeline)
        e.seek(to: fd * 10)
        _ = e.tick()
        await e.waitForDecodes()
        #expect(rig.tick() == 10)
    }

    @Test func viewerZoomRepresentsWithoutDecoding() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        #expect(e.viewerZoom == .fit)
        e.seek(to: fd * 12)
        await e.waitForDecodes()
        #expect(rig.tick() == 12)
        #expect(e.tick() == false)                       // nothing changed
        #expect(e.loop.lastPresentedZoom == .fit)
        let decodes = e.decodeCalls, presented = e.stats.presentedFrames

        e.viewerZoom = .percent(200)
        #expect(rig.tick() == 12)                        // same frame, presented again
        #expect(e.loop.lastPresentedZoom == .percent(200))
        #expect(e.stats.presentedFrames == presented + 1)
        #expect(e.tick() == false)
        e.viewerZoom = .percent(200)                     // unchanged: no re-present
        #expect(e.tick() == false)
        e.viewerZoom = .fit
        #expect(e.tick())
        #expect(e.loop.lastPresentedZoom == .fit)
        await e.waitForDecodes()
        #expect(e.decodeCalls == decodes)
        #expect(e.position == fd * 12)
        #expect(e.stats.droppedFrames == 0)
    }

    /// Position = start of the frame shown: exact for an on-grid seek, floored to the grid otherwise.
    @Test func seekPositionIsFrameFloor() async throws {
        let rig = try await Rig.make(Rig.single)
        let e = rig.engine
        e.seek(to: Time(1, 1))                           // 1 s is on the 30 fps grid
        await e.waitForDecodes()
        #expect(rig.tick() == 30)
        #expect(e.position == Time(1, 1))
        e.seek(to: Time(1, 1) + Time(1, 100))            // between frames 30 and 31
        await e.waitForDecodes()
        _ = e.tick()
        #expect(e.position == Time(1, 1))
        e.seek(to: fd * 31 - Time(1, 1_000_000))         // just before frame 31: still 30
        await e.waitForDecodes()
        _ = e.tick()
        #expect(e.position == fd * 30)
    }
}

private final class Hook: Sendable {
    private let fn = Mutex<(@Sendable () -> Void)?>(nil)
    func set(_ f: @escaping @Sendable () -> Void) { fn.withLock { $0 = f } }
    func fire() { fn.withLock { $0 }?() }
}

/// Every media is offline; each lookup fires the hook.
private struct HookResolver: MediaResolver {
    let hook: Hook
    func demuxer(for media: UUID) throws -> any Demuxing { hook.fire(); throw MediaResolverError.unknownMedia(media) }
    func audio(for media: UUID) throws -> any AudioSource { throw MediaResolverError.unknownMedia(media) }
}

private final class Flaky: Sendable {
    private let failing = Mutex(false)
    func set(_ v: Bool) { failing.withLock { $0 = v } }
    var isFailing: Bool { failing.withLock { $0 } }
}

private struct FlakyDemuxer: Demuxing {
    let inner: any Demuxing
    let flaky: Flaky
    var index: SampleIndex { inner.index }
    var formatDescription: CMFormatDescription { inner.formatDescription }
    func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] {
        if flaky.isFailing { throw MediaError.truncated }
        return try await inner.samples(for: range)
    }
}
