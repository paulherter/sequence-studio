import Foundation
import Synchronization
import Testing
import SQCore
@testable import SQAnalysis

/// F7.11: a mask that must cover on stills, under mixed frames (frame blending, optical flow, temporal filters), with a
/// proxy's frame times and on the render thread of playback, where nothing may wait. Larger, never missing.
@Suite struct AnonymizeCoverTests {
    private func box(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, width: Int = 100, height: Int = 100) -> SubjectMatte {
        var v = [Float](repeating: 0, count: width * height)
        for y in y0..<y1 { for x in x0..<x1 { v[y * width + x] = 1 } }
        return SubjectMatte(width: width, height: height, values: v)
    }

    private struct Scene {
        var store: MagicMatteStore
        var clip: Clip
        var mask: UUID
        var base: String
        var part: String
        var fx: ClipEffects { clip.effects(at: .zero) }
    }

    /// A clip with one Face mask and its cover. `frames` > 0: that many frames at 24 fps are stored, the person at
    /// x 30..<70 and the face at x 40..<60, both moving right by `step` px per frame.
    private func scene(frames: Int = 12, step: Int = 0, store: MagicMatteStore = MagicMatteStore(directory: nil), points: Bool = true) throws -> Scene {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let pick = MagicSelection(points: [MagicPoint(position: Vec2(0.5, 0.3), subtract: false, sourceTime: .zero)], part: .face)
        let ids = c.addAnonymize([pick], target: .face, cover: .mosaic, subjectWidth: 20, frameWidth: 100, frameHeight: 100)
        let id = try #require(ids.first)
        if !points { c.updateMask(id) { $0.magic?.points = [] } }
        let sel = try #require(c.masks.first?.magic)
        let base = sel.cacheKey(media: c.media), part = try #require(sel.partKey(media: c.media))
        for i in 0..<frames {
            store.put(box(30 + i * step, 70 + i * step, 10, 100), key: base, pts: Double(i) / 24)
            store.put(box(40 + i * step, 60 + i * step, 10, 40), key: part, pts: Double(i) / 24)
        }
        return Scene(store: store, clip: c, mask: id, base: base, part: part)
    }

    private func covered(_ m: SubjectMatte, _ x: Double, _ y: Double) -> Bool {
        m.values[min(Int(y * Double(m.height)), m.height - 1) * m.width + min(Int(x * Double(m.width)), m.width - 1)] > 0.5
    }

    private func isWhole(_ m: SubjectMatte) -> Bool { m.values.allSatisfy { $0 == 1 } }

    // MARK: Stills

    @Test func aStillTakesItsTrackedMatteWhateverTheTime() throws {
        let s = try scene(frames: 1)
        let m = try #require(s.store.mattes(for: s.fx, pts: 0, frameWidth: 100, still: true)[s.mask])
        #expect(covered(m, 0.5, 0.2) && !covered(m, 0.35, 0.2) && !isWhole(m))
        // Only the whole person is stored: that.
        s.store.remove(key: s.part)
        let p = try #require(s.store.mattes(for: s.fx, pts: 0, frameWidth: 100, still: true)[s.mask])
        #expect(covered(p, 0.35, 0.8) && !isWhole(p))
    }

    @Test func aStillWithoutAMatteIsCoveredWhole() throws {
        let s = try scene(frames: 0)
        let m = try #require(s.store.mattes(for: s.fx, pts: 0, frameWidth: 100, still: true)[s.mask])
        #expect(isWhole(m))
        #expect(isWhole(try #require(s.store.mattes(for: s.fx, pts: 0, frameWidth: 100, still: true, wait: false)[s.mask])))
    }

    // MARK: No pick

    @Test func aMaskWithoutAPickCoversTheWholeFrame() throws {
        let s = try scene(frames: 0, points: false)
        #expect(s.fx.magicMattes.count == 1)
        #expect(isWhole(try #require(s.store.mattes(for: s.fx, pts: 1, frameWidth: 100)[s.mask])))
        #expect(isWhole(try #require(s.store.mattes(for: s.fx, pts: 1, frameWidth: 100, wait: false)[s.mask])))
    }

    // MARK: Mixed frames

    @Test func mixedFramesAreCoveredByTheUnionOfTheirMattes() throws {
        let s = try scene(step: 2)                                   // frame 4: face 48..<68, frame 5: 50..<70, frame 6: 52..<72
        let own = try #require(s.store.mattes(for: s.fx, pts: 4.0 / 24, frameWidth: 100)[s.mask])
        #expect(covered(own, 0.5, 0.2) && !covered(own, 0.7, 0.2))
        let mix = try #require(s.store.mattes(for: s.fx, pts: 4.0 / 24, frameWidth: 100, neighbors: [5.0 / 24, 6.0 / 24])[s.mask])
        #expect(covered(mix, 0.5, 0.2) && covered(mix, 0.7, 0.2) && !covered(mix, 0.3, 0.2) && !covered(mix, 0.6, 0.8))
        // A neighbor outside the tracked range brings its larger estimate (the whole person, grown).
        let edge = try #require(s.store.mattes(for: s.fx, pts: 11.0 / 24, frameWidth: 100, neighbors: [12.0 / 24])[s.mask])
        #expect(covered(edge, 0.7, 0.8) && edge.area > own.area)
        // Nothing known about a neighbor: everything.
        let lone = try scene(frames: 0)
        lone.store.put(box(40, 60, 10, 40), key: lone.part, pts: 0)
        lone.store.remove(key: lone.part)
        #expect(isWhole(try #require(lone.store.mattes(for: lone.fx, pts: 0, frameWidth: 100, neighbors: [1.0 / 24])[lone.mask])))
    }

    @Test func opticalFlowCoversTheBoxAroundBothFrames() throws {
        let a = box(10, 20, 10, 20), b = box(60, 70, 50, 60)
        let plain = MagicMatteStore.union([a, b], spanning: false)
        #expect(covered(plain, 0.15, 0.15) && covered(plain, 0.65, 0.55) && !covered(plain, 0.4, 0.35))
        let span = MagicMatteStore.union([a, b], spanning: true)
        #expect(covered(span, 0.4, 0.35) && covered(span, 0.15, 0.55) && !covered(span, 0.8, 0.8) && !covered(span, 0.05, 0.05))
        // Different sizes: the larger one's grid; the whole frame stays the whole frame.
        let small = SubjectMatte(width: 10, height: 10, values: box(0, 5, 0, 10, width: 10, height: 10).values)
        let mixed = MagicMatteStore.union([b, small], spanning: false)
        #expect(mixed.width == 100 && covered(mixed, 0.2, 0.9) && covered(mixed, 0.65, 0.55) && !covered(mixed, 0.8, 0.9))
        #expect(isWhole(MagicMatteStore.union([a, AnonymizeFallback.wholeFrame], spanning: false)))
    }

    // MARK: Proxy times

    /// A proxy's frame times can sit a little off the original's: within the tolerance the frame's own matte, past it
    /// the larger estimate.
    @Test func aFrameTimeOffTheTrackedOneIsCoveredAtLeastAsWell() throws {
        let s = try scene()
        let exact = try #require(s.store.mattes(for: s.fx, pts: 5.0 / 24, frameWidth: 100)[s.mask])
        let off = try #require(s.store.mattes(for: s.fx, pts: 5.0 / 24 + 0.012, frameWidth: 100)[s.mask])
        #expect(off == exact)
        // Past the last tracked frame by more than its frame (the store answers the frame shown at a time, up to the next
        // frame's time): no exact frame, so the person, grown.
        let miss = try #require(s.store.mattes(for: s.fx, pts: 11.0 / 24 + 0.05, frameWidth: 100)[s.mask])
        #expect(miss.area > exact.area && covered(miss, 0.5, 0.2) && covered(miss, 0.35, 0.8))
        // Every time between two tracked frames lands on one of them.
        for i in 0..<40 {
            let m = try #require(s.store.mattes(for: s.fx, pts: 5.0 / 24 + Double(i) / 24 / 40, frameWidth: 100)[s.mask])
            #expect(covered(m, 0.5, 0.2))
        }
    }

    // MARK: Playback never waits

    private func onDisk(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-cover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test func playbackShowsTheWholeFrameUntilTheFileIsReadAndTheGrownMatteIsMade() throws {
        try onDisk { dir in
            let written = try scene(store: MagicMatteStore(directory: dir))
            written.store.save(key: written.base)
            written.store.save(key: written.part)
            let store = MagicMatteStore(directory: dir)              // a new session: nothing read yet
            let fired = Atomic<Int>(0)
            let token = store.observeReady { fired.wrappingAdd(1, ordering: .relaxed) }
            let gap = 2.0
            let first = try #require(store.mattes(for: written.fx, pts: gap, frameWidth: 100, wait: false)[written.mask])
            #expect(isWhole(first))
            store.waitForCovers()
            #expect(store.isLoaded(written.base) && store.isLoaded(written.part) && fired.load(ordering: .relaxed) == 1)
            // Read: the grown matte is being made. Until it is there playback shows everything; the read's own warm-up
            // may have made it already (both are right, so either is accepted: this was a race of the test).
            let second = try #require(store.mattes(for: written.fx, pts: gap, frameWidth: 100, wait: false)[written.mask])
            #expect(isWhole(second) || (covered(second, 0.35, 0.8) && covered(second, 0.2, 0.5)))
            store.waitForCovers()
            #expect((1...2).contains(fired.load(ordering: .relaxed)))
            let n = store.decodes
            let grown = try #require(store.mattes(for: written.fx, pts: gap, frameWidth: 100, wait: false)[written.mask])
            #expect(!isWhole(grown) && covered(grown, 0.35, 0.8) && covered(grown, 0.2, 0.5) && store.decodes == n)
            // The same as export draws (it waits).
            #expect(grown == store.mattes(for: written.fx, pts: gap, frameWidth: 100)[written.mask])
            store.removeObserver(token)
        }
    }

    /// Playing toward the end of the tracking: the grown mattes of the gap are made while tracked frames still show, so
    /// the first frame of the gap has one.
    @Test func theGrownMattesAreMadeBeforePlaybackReachesTheGap() throws {
        let s = try scene()
        let last = try #require(s.store.mattes(for: s.fx, pts: 11.0 / 24, frameWidth: 100, wait: false)[s.mask])
        #expect(!isWhole(last) && !covered(last, 0.35, 0.8))
        s.store.waitForCovers()
        let n = s.store.decodes
        for pts in [12.0 / 24, 0.9, 1.2, 3.0] {                      // all three steps
            let m = try #require(s.store.mattes(for: s.fx, pts: pts, frameWidth: 100, wait: false)[s.mask])
            #expect(!isWhole(m) && covered(m, 0.35, 0.8), "\(pts)")
        }
        #expect(s.store.decodes == n)
        // A changed frame drops what was grown from it.
        s.store.put(box(0, 10, 0, 10), key: s.base, pts: 11.0 / 24)
        let fresh = try #require(s.store.mattes(for: s.fx, pts: 3, frameWidth: 100)[s.mask])
        #expect(covered(fresh, 0.05, 0.05) && !covered(fresh, 0.5, 0.8))
    }

    /// Eight covers near one gap want more grown mattes than the cache holds: they settle (finite redraws) and all get theirs.
    @Test func manyCoversNearAGapSettleAndAllGetTheirGrownMatte() throws {
        let store = MagicMatteStore(directory: nil)
        var uses: [MagicMatteUse] = []
        for i in 0..<8 {
            let key = "k\(i)"
            for f in 0..<12 { store.put(box(30, 70, 10, 100), key: key, pts: Double(f) / 24) }
            uses.append(MagicMatteUse(mask: UUID(), cacheKey: key, feather: 0, expansion: 0, mustCover: true))
        }
        let fired = Atomic<Int>(0)
        let token = store.observeReady { fired.wrappingAdd(1, ordering: .relaxed) }
        for _ in 0..<2 {                                             // a paused monitor redrawing
            for u in uses { _ = store.covering(u, pts: 11.0 / 24, frameWidth: 100, wait: false) }
            store.waitForCovers()
        }
        let settled = fired.load(ordering: .relaxed)
        #expect(settled <= 16)
        for _ in 0..<6 {
            for u in uses { _ = store.covering(u, pts: 11.0 / 24, frameWidth: 100, wait: false) }
            store.waitForCovers()
        }
        #expect(fired.load(ordering: .relaxed) == settled)
        for u in uses { _ = store.covering(u, pts: 11.0 / 24, frameWidth: 100, wait: false) }
        store.waitForCovers()
        #expect(fired.load(ordering: .relaxed) == settled)
        for u in uses {
            let m = store.covering(u, pts: 11.0 / 24, frameWidth: 100, wait: false)
            #expect(!isWhole(m) && covered(m, 0.5, 0.8))
        }
        store.removeObserver(token)
    }

    /// A paused frame whose grown mattes take longer than the asked-for window (a full cache, a slow batch): the mattes
    /// that are made first are not evicted by the ones that come later, so the redraws settle and nothing is rebuilt.
    @Test func aSlowBatchOnAPausedFrameDoesNotEvictItsOwnMattes() throws {
        let store = MagicMatteStore(directory: nil)
        store.setWantedWindow(.milliseconds(30))
        var uses: [MagicMatteUse] = []
        for i in 0..<40 {                                            // more than `grownCapacity`
            let key = "s\(i)"
            for f in 0..<2 { store.put(box(120, 280, 40, 400, width: 400, height: 400), key: key, pts: Double(f) / 24) }
            uses.append(MagicMatteUse(mask: UUID(), cacheKey: key, feather: 0, expansion: 0, mustCover: true))
        }
        func redraw() {
            for u in uses { _ = store.covering(u, pts: 2.0, frameWidth: 400, wait: false) }
            store.waitForCovers()
        }
        for _ in 0..<4 { redraw() }                                  // the batch, then redraws until it is complete
        let n = store.decodes
        for _ in 0..<3 { redraw() }
        #expect(store.decodes == n, "a settled paused frame decoded \(store.decodes - n) more mattes")
    }

    /// Two clips (two monitors) ask for covers at different source times of one frame: together they want more than the
    /// cache holds, and must not evict each other (no redraw loop).
    @Test func coversAtDifferentSourceTimesDoNotEvictEachOther() throws {
        let store = MagicMatteStore(directory: nil)
        func uses(_ prefix: String) -> [MagicMatteUse] {
            (0..<8).map { i in
                let key = "\(prefix)\(i)"
                for f in 0..<12 { store.put(box(30, 70, 10, 100), key: key, pts: Double(f) / 24) }
                return MagicMatteUse(mask: UUID(), cacheKey: key, feather: 0, expansion: 0, mustCover: true)
            }
        }
        let a = uses("a"), b = uses("b")
        let fired = Atomic<Int>(0)
        let token = store.observeReady { fired.wrappingAdd(1, ordering: .relaxed) }
        func frame() {
            for u in a { _ = store.covering(u, pts: 11.0 / 24, frameWidth: 100, wait: false) }
            for u in b { _ = store.covering(u, pts: 10.0 / 24, frameWidth: 100, wait: false) }
            store.waitForCovers()
        }
        for _ in 0..<3 { frame() }
        let settled = fired.load(ordering: .relaxed)
        let n = store.decodes
        for _ in 0..<4 { frame() }
        #expect(fired.load(ordering: .relaxed) == settled)
        #expect(store.decodes == n)
        store.removeObserver(token)
    }

    /// A stored frame that does not decode stays whole frame and is not rescheduled on every redraw.
    @Test func aFrameThatFailsToDecodeIsRememberedAsFailed() throws {
        try onDisk { dir in
            let writer = MagicMatteStore(directory: dir)
            writer.put(box(30, 70, 10, 100), key: "bad", pts: 0)
            writer.save(key: "bad")
            // Same file, but the frame's bytes are cut short.
            let url = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
            var out = Data("SQMT".utf8)
            func put<T>(_ v: T) { withUnsafeBytes(of: v) { out.append(contentsOf: $0) } }
            put(MagicMatteStore.fileVersion); put(UInt32(1)); put(Double(0)); put(UInt32(100)); put(UInt32(100)); put(UInt32(5))
            out.append(Data([1, 2, 3, 4, 5]))
            try out.write(to: url)
            let store = MagicMatteStore(directory: dir)
            store.preload("bad")
            let use = MagicMatteUse(mask: UUID(), cacheKey: "bad", feather: 0, expansion: 0, mustCover: true)
            let fired = Atomic<Int>(0)
            let token = store.observeReady { fired.wrappingAdd(1, ordering: .relaxed) }
            for _ in 0..<5 {
                #expect(isWhole(store.covering(use, pts: 3, frameWidth: 100, wait: false)))
                store.waitForCovers()
            }
            #expect(fired.load(ordering: .relaxed) == 0)
            #expect(isWhole(store.covering(use, pts: 3, frameWidth: 100)))
            store.removeObserver(token)
        }
    }

    /// A version 1 file (pts one frame early on edit-listed B-frame files) is dropped, so the mask is tracked again;
    /// the current version reads back.
    @Test func aVersionOneMatteFileIsDropped() throws {
        try onDisk { dir in
            let writer = MagicMatteStore(directory: dir)
            writer.put(box(30, 70, 10, 100), key: "old", pts: 0.5)
            writer.save(key: "old")
            let url = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
            var d = try Data(contentsOf: url)
            #expect(MagicMatteStore.parse(d).map(\.pts) == [0.5])
            withUnsafeBytes(of: UInt32(1)) { d.replaceSubrange(4..<8, with: $0) }
            #expect(MagicMatteStore.parse(d).isEmpty)
        }
    }

    /// The cost of the first frame of a gap on the thread that asks: before, the render thread read the file and grew
    /// the matte itself.
    @Test func firstFallbackFrameCost() throws {
        try onDisk { dir in
            let a = MagicMatteStore(directory: dir)
            var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(60, 1)), start: .zero)
            let pick = MagicSelection(points: [MagicPoint(position: Vec2(0.5, 0.3), subtract: false, sourceTime: .zero)], part: .face)
            let id = try #require(c.addAnonymize([pick], target: .face, cover: .mosaic, subjectWidth: 400, frameWidth: 1920, frameHeight: 1080).first)
            let sel = try #require(c.masks.first?.magic)
            let base = sel.cacheKey(media: c.media), part = try #require(sel.partKey(media: c.media))
            let person = box(300, 500, 100, 432, width: 768, height: 432), face = box(360, 440, 100, 200, width: 768, height: 432)
            for i in 0..<240 {                                       // 10 s tracked
                a.put(person, key: base, pts: Double(i) / 24)
                a.put(face, key: part, pts: Double(i) / 24)
            }
            a.save(key: base); a.save(key: part)
            let fx = c.effects(at: .zero)
            let clock = ContinuousClock()
            let waiting = MagicMatteStore(directory: dir)
            var m: SubjectMatte?
            let before = clock.measure { m = waiting.mattes(for: fx, pts: 12, frameWidth: 1920)[id] }
            #expect(m.map { !isWhole($0) } == true)
            let playback = MagicMatteStore(directory: dir)
            let after = clock.measure { m = playback.mattes(for: fx, pts: 12, frameWidth: 1920, wait: false)[id] }
            #expect(m.map(isWhole) == true)
            playback.waitForCovers()
            _ = playback.mattes(for: fx, pts: 12, frameWidth: 1920, wait: false)
            playback.waitForCovers()
            let ready = clock.measure { m = playback.mattes(for: fx, pts: 12, frameWidth: 1920, wait: false)[id] }
            #expect(m.map { !isWhole($0) } == true)
            func ms(_ d: Duration) -> String { String(format: "%.3f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
            print("PERF first fallback frame 768x432, 240 frames on disk: \(ms(before)) ms waiting, \(ms(after)) ms playback, \(ms(ready)) ms ready")
            #expect(after < .milliseconds(5))
        }
    }
}
