import AVFoundation
import CoreVideo
import Foundation
import SQCore
import SQMedia
import Synchronization
import Testing
@testable import SQAnalysis

/// Magic masks: follower rule, matte store (nearest frame, files, LRU), edge, and Track on a written movie with a fake
/// segmenter (the patch is the only object). Vision cost: `MagicMaskBenchTests` (opt-in, real media).
@Suite struct MagicMaskTests {
    /// Labels of a w x h frame with one object covering columns x0..<x1 of rows y0..<y1.
    static func frame(_ w: Int, _ h: Int, objects: [(UInt8, Int, Int, Int, Int)]) -> InstanceFrame {
        var l = [UInt8](repeating: 0, count: w * h)
        for (id, x0, x1, y0, y1) in objects { for y in y0..<y1 { for x in x0..<x1 { l[y * w + x] = id } } }
        return InstanceFrame(labels: InstanceLabels(width: w, height: h, labels: l))
    }

    @Test func followerPicksThenFollowsAndStopsWhenLost() throws {
        var f = MagicFollower()
        let click = [MagicPoint(position: Vec2(0.25, 0.5), subtract: false, sourceTime: .zero)]
        let a0 = f.step(Self.frame(20, 10, objects: [(1, 2, 8, 2, 8), (2, 12, 18, 2, 8)]), points: click)
        let a = try #require(a0)
        #expect(a[4, 4] == 1 && a[14, 4] == 0)
        // Next frame: numbers swapped, object moved 1 px right.
        let b0 = f.step(Self.frame(20, 10, objects: [(2, 3, 9, 2, 8), (1, 12, 18, 2, 8)]), points: click)
        let b = try #require(b0)
        #expect(b[8, 4] > 0.4 && b[14, 4] == 0)
        #expect(f.lastConfidence > 0.6)
        // Gone.
        let c0 = f.step(Self.frame(20, 10, objects: [(1, 12, 18, 2, 8)]), points: click)
        #expect(c0 == nil)
    }

    /// A frame without the subject changes nothing in the follower: the subject is found again where it was last seen.
    @Test func followerFindsTheSubjectAgainAfterFramesWithoutIt() throws {
        var f = MagicFollower()
        let click = [MagicPoint(position: Vec2(0.25, 0.5), subtract: false, sourceTime: .zero)]
        #expect(f.step(Self.frame(20, 10, objects: [(1, 2, 8, 2, 8)]), points: click) != nil)
        for _ in 0..<3 { #expect(f.step(Self.frame(20, 10, objects: [(1, 13, 18, 2, 8)]), points: click) == nil) }
        let found = f.step(Self.frame(20, 10, objects: [(3, 3, 9, 2, 8)]), points: click)
        let back = try #require(found)
        #expect(back[5, 4] == 1 && back[15, 4] == 0)
    }

    /// Continuing from a frame stored as "subject not found" (an empty matte): only points made on that frame pick
    /// there, never the pick's points of another frame.
    @Test func followerStartingOnALostFramePicksOnlyByPointsMadeThere() throws {
        let empty = SubjectMatte(width: 1, height: 1, values: [0])
        let frame = Self.frame(20, 10, objects: [(1, 2, 8, 2, 8)])
        let pick = MagicPoint(position: Vec2(0.25, 0.5), subtract: false, sourceTime: .zero)
        var a = MagicFollower(start: empty)
        #expect(a.step(frame, points: [pick], pts: 1, span: 0.04) == nil)
        var b = MagicFollower(start: empty)
        let here = MagicPoint(position: Vec2(0.25, 0.5), subtract: false, sourceTime: Time(1, 1))
        let picked = b.step(frame, points: [pick, here], pts: 1, span: 0.04)
        let m = try #require(picked)
        #expect(m[5, 4] == 1)
    }

    /// A mid-clip click on a frame whose tracked mask already answers it keeps the tracked mask (SubjectCorrectionRule);
    /// one it does not answer is corrected by the segmenter's pick.
    @Test func midClipClickKeepsAMaskThatAlreadyAnswersIt() throws {
        let frame = Self.frame(20, 10, objects: [(1, 2, 8, 2, 8), (2, 12, 18, 2, 8)])
        var v = [Float](repeating: 0, count: 200)
        for y in 2..<8 { for x in 3..<9 { v[y * 20 + x] = 1 } }           // tracked: shifted one column from label 1
        let tracked = SubjectMatte(width: 20, height: 10, values: v)
        let on = MagicPoint(position: Vec2(0.25, 0.5), subtract: false, sourceTime: Time(1, 1))
        let kept = try #require(MagicMaskTracker.pickMatte(frame, pts: 1, points: [on], start: tracked, span: 0.04))
        #expect(kept.values == tracked.values)
        let off = MagicPoint(position: Vec2(0.75, 0.5), subtract: true, sourceTime: Time(1, 1))
        let cut = try #require(MagicMaskTracker.pickMatte(frame, pts: 1, points: [on, off], start: tracked, span: 0.04))
        #expect(cut.values == tracked.values)                              // the removed spot is off the mask already
        let add = MagicPoint(position: Vec2(0.75, 0.5), subtract: false, sourceTime: Time(1, 1))
        let grown = try #require(MagicMaskTracker.pickMatte(frame, pts: 1, points: [add], start: tracked, span: 0.04))
        #expect(grown[14, 4] > 0.4 && grown.values != tracked.values)
    }

    @Test func followerWithoutAHitPicksNothing() {
        var f = MagicFollower()
        let click = [MagicPoint(position: Vec2(0.5, 0.05), subtract: false, sourceTime: .zero)]
        let r = f.step(Self.frame(20, 10, objects: [(1, 2, 8, 2, 8)]), points: click)
        #expect(r == nil)
    }

    @Test func storeFindsTheNearestFrameOnlyWithinHalfAFrame() throws {
        let s = MagicMatteStore(directory: nil)
        let m = SubjectMatte(width: 2, height: 1, values: [1, 0])
        for i in 0..<5 { s.put(m, key: "k", pts: Double(i) / 25) }
        #expect(s.times(key: "k").count == 5)
        #expect(s.matte(key: "k", pts: 0.081) != nil)          // frame 2 at 0.08
        #expect(s.matte(key: "k", pts: 0.3) == nil)            // past the tracked span
        #expect(s.matte(key: "other", pts: 0) == nil)
        let back = try #require(s.matte(key: "k", pts: 0.04))
        #expect(back[0, 0] == 1 && back[1, 0] == 0)
    }

    @Test func storeWritesAndReadsItsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-magic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = MagicMatteStore(directory: dir)
        let m = SubjectMatte(width: 64, height: 36, values: (0..<(64 * 36)).map { Float($0 % 64) / 63 })
        a.put(m, key: "abc", pts: 1.0)
        a.put(m, key: "abc", pts: 1.04)
        a.save(key: "abc")
        let b = MagicMatteStore(directory: dir)
        #expect(b.times(key: "abc") == [1.0, 1.04])
        let r = try #require(b.matte(key: "abc", pts: 1.0))
        #expect(abs(r[63, 0] - 1) < 0.01 && abs(r[32, 5] - Float(32) / 63) < 0.01)
        b.remove(key: "abc")
        // The frames are gone at once, the file goes on the save queue.
        #expect(b.times(key: "abc").isEmpty)
        b.waitForSaves()
        #expect(MagicMatteStore(directory: dir).times(key: "abc").isEmpty)
    }

    @Test func playbackFillsAShortHoleWithTheNearestTrackedFrame() throws {
        // Frames 0...11 at 25 fps, frame i is i + 1 texels wide. Missing: 4 and 5 (a short hole), 8 (one frame).
        let s = MagicMatteStore(directory: nil)
        func frame(_ i: Int) -> SubjectMatte {
            SubjectMatte(width: 16, height: 1, values: (0..<16).map { $0 <= i ? 1 : 0 })
        }
        for i in 0..<12 where ![4, 5, 8].contains(i) { s.put(frame(i), key: "k", pts: Double(i) / 25) }
        func shown(_ i: Double, key: String = "k") -> Double? {
            s.matte(key: key, pts: i / 25, feather: 0, expansion: 0, frameWidth: 16, fills: true)?.area
        }
        #expect(shown(3) == 4 && shown(6) == 7)                    // tracked frames: their own matte
        // holes: the nearer neighbor (a tie: the earlier one), moved toward the other one (`MagicMatteGapFillTests`); this
        // left-anchored blob loses a bit of area at the border it is moved into.
        func near(_ a: Double?, _ b: Double) -> Bool { abs((a ?? -9) - b) <= 1 }
        #expect(near(shown(4), 4) && near(shown(5), 7) && near(shown(8), 8))
        let before = s.decodes
        _ = (shown(4), shown(5))                                   // ... from the LRU, nothing is decoded again
        #expect(s.decodes == before)
        // Not tracked there stays not tracked: outside the span, and for everything that asks what is stored.
        #expect(shown(-2) == nil)
        #expect(shown(14) == nil)
        #expect(s.matte(key: "k", pts: 4.0 / 25) == nil)
        #expect(s.matte(key: "k", pts: 4.0 / 25, feather: 0, expansion: 0, frameWidth: 16) == nil)
        // A longer hole (3 frames and more) is a part that was never tracked: it stays open.
        for i in [0, 1, 2, 6, 7, 8] { s.put(frame(i), key: "long", pts: Double(i) / 25) }
        #expect(shown(3, key: "long") == nil)
        #expect(shown(4, key: "long") == nil)
        #expect(shown(2, key: "long") == 3)
    }

    @Test func storeEdgesAreCachedPerFrameAndEdge() throws {
        let s = MagicMatteStore(directory: nil)
        var v = [Float](repeating: 0, count: 40 * 20)
        for y in 5..<15 { for x in 10..<30 { v[y * 40 + x] = 1 } }
        s.put(SubjectMatte(width: 40, height: 20, values: v), key: "k", pts: 0)
        let grown = try #require(s.matte(key: "k", pts: 0, feather: 0, expansion: 40, frameWidth: 400))   // 4 matte px
        #expect(grown.area > 200 + 4 * 30 * 2)
        _ = s.matte(key: "k", pts: 0, feather: 0, expansion: 40, frameWidth: 400)
        #expect(s.decodes == 1)
        let shrunk = try #require(s.matte(key: "k", pts: 0, feather: 0, expansion: -20, frameWidth: 400))
        #expect(shrunk.area < 200)
        let soft = try #require(s.matte(key: "k", pts: 0, feather: 60, expansion: 0, frameWidth: 400))
        #expect(soft[10, 10] > 0.2 && soft[10, 10] < 0.8)       // the edge column is half way
        #expect(abs(soft.area - 200) < 20)                      // a soft edge keeps the area
    }

    @Test func untrackedFramesCountsTheMagicFramesExportWouldMiss() throws {
        let s = MagicMatteStore(directory: nil)
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: Time(2, 1), duration: Time(1, 1)), start: .zero)
        let m = ClipMask.makeMagic(name: "Mask (1)", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: Time(2, 1))])
        clip.masks = [m]
        func timeline(_ c: Clip) throws -> Timeline {
            var track = Track(kind: .video)
            try track.overwrite(c)
            return Timeline(name: "t", frameDuration: Time(1, 25), tracks: [track])
        }
        let tl = try timeline(clip)
        #expect(s.untrackedFrames(in: tl) == 25)
        let key = m.magic!.cacheKey(media: clip.media)
        let matte = SubjectMatte(width: 2, height: 1, values: [1, 0])
        for i in 0..<15 { s.put(matte, key: key, pts: 2 + Double(i) / 25) }
        #expect(s.untrackedFrames(in: tl) == 10)
        // A disabled mask or one nothing uses is not exported.
        clip.masks[0].usedByOpacity = false
        #expect(s.untrackedFrames(in: try timeline(clip)) == 0)
    }

    /// Thresholds the frame: the checker patch (pure black/white) is object 1, the gray background is nothing.
    struct PatchSegmenter: InstanceSegmenting {
        func segment(_ pb: CVPixelBuffer) throws -> InstanceFrame? {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let base = try #require(CVPixelBufferGetBaseAddress(pb))
            let stride = CVPixelBufferGetBytesPerRow(pb)
            var l = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    let g = Int(row[x * 4 + 1])
                    if g < 40 || g > 215 { l[y * w + x] = 1 }
                }
            }
            return InstanceFrame(labels: InstanceLabels(width: w, height: h, labels: l))
        }
    }

    @Test func tracksTheMovingPatchForwardAndBackward() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
        let click = [MagicPoint(position: Vec2(80.0 / 320, 90.0 / 180), subtract: false, sourceTime: .zero)]
        let r = try await tracker.track(key: "p", points: click, from: 0, to: 23.0 / 24, store: store)
        #expect(r.frames == 24 && !r.lost)
        // Patch center moves 4 px of 320 per frame.
        for i in [0, 12, 23] {
            let m = try #require(store.matte(key: "p", pts: Double(i) / 24))
            let c = try #require(m.centroid)
            let x = c.x / Double(m.width) * 320
            #expect(abs(x - Double(80 + 4 * i)) < 6, "frame \(i) at \(x)")
        }
        // Backward from frame 12 under another key: continues the pick, frames 12...0.
        let back = try await MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
            .track(key: "q", points: [MagicPoint(position: Vec2(128.0 / 320, 90.0 / 180), subtract: false, sourceTime: Time(12, 24))],
                   from: 12.0 / 24, to: 0, store: store)
        #expect(back.frames == 13)
        #expect(store.times(key: "q").first.map { abs($0) < 1e-3 } == true)
        // A click's immediate pick: the frame shown at 0.52 s is frame 12.
        let seg = try #require(try await tracker.segment(at: 0.52))
        #expect(abs(seg.pts - 0.5) < 1e-3)
        let pt = [MagicPoint(position: Vec2(128.0 / 320, 90.0 / 180), subtract: false, sourceTime: Time(12, 24))]
        #expect(MagicMaskTracker.pick(seg.frame, pts: seg.pts, key: "r", points: pt, store: store))
        #expect(store.matte(key: "r", pts: 0.5) != nil)
        let miss = [MagicPoint(position: Vec2(0.05, 0.05), subtract: false, sourceTime: Time(12, 24))]
        #expect(!MagicMaskTracker.pick(seg.frame, pts: seg.pts, key: "s", points: miss, store: store))
    }

    /// Notes the queue every segmentation ran on; can hang from its `hangAt`-th call until `release`.
    /// The patch is the object, except on the calls in `blind` (the subject is hidden there).
    final class BlinkingSegmenter: InstanceSegmenting, @unchecked Sendable {
        let blind: ClosedRange<Int>
        let calls = Mutex(0)
        init(blind: ClosedRange<Int>) { self.blind = blind }
        func segment(_ frame: CVPixelBuffer) throws -> InstanceFrame? {
            let n = calls.withLock { $0 += 1; return $0 }
            return blind.contains(n) ? nil : try PatchSegmenter().segment(frame)
        }
    }

    /// A subject lost for some frames does not end the track: those frames are stored empty (the health strip shows
    /// them weak) and the track goes on and finds it again.
    @Test func aLostSubjectIsStoredEmptyAndTheTrackGoesOn() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        // Calls 9...10 = frames 8 and 9 (the patch moves 4 px per frame and is 40 wide: found again after two).
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: BlinkingSegmenter(blind: 9...10))
        let click = [MagicPoint(position: Vec2(80.0 / 320, 90.0 / 180), subtract: false, sourceTime: .zero)]
        let r = try await tracker.track(key: "p", points: click, from: 0, to: 23.0 / 24, store: store)
        #expect(r.frames == 22 && r.lost && r.lostTimes.count == 2)
        #expect(store.times(key: "p").count == 24)
        #expect(store.matte(key: "p", pts: 8.0 / 24)?.isBlank == true)
        #expect(store.matte(key: "p", pts: 8.0 / 24, feather: 4, expansion: 2, frameWidth: 320)?.isBlank == true)
        let after = try #require(store.matte(key: "p", pts: 20.0 / 24))
        let c = try #require(after.centroid)
        #expect(abs(c.x / Double(after.width) * 320 - 160) < 6)
        let weak = MagicTrackHealth.weakSpans(store.healthSamples(key: "p"))
        #expect(weak.contains { $0.start <= 8.0 / 24 + 1e-6 && $0.end >= 9.0 / 24 - 1e-6 })
        // Track again from a frame stored empty: nothing to follow there, and nothing is overwritten.
        let again = try await tracker.track(key: "p", points: click, from: 8.0 / 24, to: 23.0 / 24, store: store)
        #expect(again.frames == 0 && store.matte(key: "p", pts: 20.0 / 24)?.isBlank == false)
        // A mask that must cover (Anonymize) gets no empty frame: its lookup falls back to the enlarged cover.
        let cover = MagicMatteStore(directory: nil)
        let blink = MagicMaskTracker(url: url, limits: .current, segmenter: BlinkingSegmenter(blind: 9...10))
        let s = try await blink.track(key: "c", points: click, from: 0, to: 23.0 / 24, store: cover, marksLost: false)
        #expect(s.frames == 22 && s.lostTimes.count == 2 && cover.times(key: "c").count == 22)
    }

    final class WatchedSegmenter: InstanceSegmenting, @unchecked Sendable {
        let queues = Mutex<[String]>([])
        let hangAt: Int?
        let release = DispatchSemaphore(value: 0)
        init(hangAt: Int? = nil) { self.hangAt = hangAt }
        func segment(_ pb: CVPixelBuffer) throws -> InstanceFrame? {
            let n = queues.withLock { $0.append(String(cString: __dispatch_queue_get_label(nil))); return $0.count }
            if let hangAt, n >= hangAt { release.wait() }
            return try PatchSegmenter().segment(pb)
        }
    }

    /// Every Vision call of a track blocks: all of them run on the frame lane, also the ones made after a read ended
    /// (the last frame of a forward run, the frames of a backward chunk). Before: those ran on the cooperative pool.
    @Test func everyTrackedFrameIsSegmentedOnTheFrameLane() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        for (from, to) in [(0.0, 23.0 / 24), (12.0 / 24, 0.0)] {
            let seg = WatchedSegmenter()
            let point = MagicPoint(position: Vec2((80 + 96 * from) / 320, 0.5), subtract: false, sourceTime: Time(Int64((from * 24).rounded()), 24))
            let r = try await MagicMaskTracker(url: url, limits: .current, segmenter: seg)
                .track(key: "lane\(from)", points: [point], from: from, to: to, store: store)
            let queues = seg.queues.withLock { $0 }
            #expect(r.frames == queues.count && r.frames >= 13)
            #expect(queues.allSatisfy { $0 == "sq.lane.frames" }, "\(Set(queues))")
        }
    }

    /// Vision that never returns must not hold a slot of the frame lane for the rest of the app run: the track ends
    /// with `Stalled`, and the call that comes back late stores nothing.
    @Test func aTrackWhoseSegmenterHangsEndsAndStoresNothingMore() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let seg = WatchedSegmenter(hangAt: 3)
        var tracker = MagicMaskTracker(url: url, limits: .current, segmenter: seg)
        // Far above what the first read and two frames cost when the whole suite runs beside it (3 s was not:
        // the read itself was given up and no frame stored).
        tracker.stallAfter = 12
        let click = [MagicPoint(position: Vec2(80.0 / 320, 90.0 / 180), subtract: false, sourceTime: .zero)]
        await #expect(throws: BlockingLane.Stalled.self) {
            _ = try await tracker.track(key: "hung", points: click, from: 0, to: 23.0 / 24, store: store)
        }
        #expect(store.times(key: "hung").count == 2)
        for _ in 0..<8 { seg.release.signal() }
        try await Task.sleep(for: .milliseconds(600))
        #expect(store.times(key: "hung").count == 2)
    }

    /// Review 2026-10-09: tracking again over frames that have a matte (or the backward leg reading the pick's frame
    /// again) with one frame the segmenter misses must not blank the stored matte.
    @Test func aLostFrameNeverReplacesAStoredMatte() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let click = [MagicPoint(position: Vec2(80.0 / 320, 90.0 / 180), subtract: false, sourceTime: .zero)]
        let first = try await MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
            .track(key: "p", points: click, from: 0, to: 23.0 / 24, store: store)
        #expect(first.frames == 24)
        let before = try #require(store.matte(key: "p", pts: 8.0 / 24))
        let again = try await MagicMaskTracker(url: url, limits: .current, segmenter: BlinkingSegmenter(blind: 9...10))
            .track(key: "p", points: click, from: 0, to: 23.0 / 24, store: store)
        #expect(again.lostTimes.count == 2 && again.frames == 22)
        #expect(store.matte(key: "p", pts: 8.0 / 24) == before)
        #expect(store.matte(key: "p", pts: 9.0 / 24)?.isBlank == false)
        #expect(store.times(key: "p").count == 24)
        // The store's own rule: a blank frame may be marked again, a frame with something in it stays.
        #expect(store.putLost(key: "p", pts: 2) && store.putLost(key: "p", pts: 2))
        #expect(!store.putLost(key: "p", pts: 8.0 / 24))
    }

    /// A clip with one Magic mask cutting the picture, on a 25 fps timeline.
    static func maskedClip(seconds: Int64) throws -> (clip: Clip, mask: ClipMask, key: String, timeline: Timeline) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(seconds, 1)), start: .zero)
        let m = ClipMask.makeMagic(name: "Mask (1)", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero)])
        clip.masks = [m]
        var track = Track(kind: .video)
        try track.overwrite(clip)
        return (clip, m, m.magic!.cacheKey(media: clip.media), Timeline(name: "t", frameDuration: Time(1, 25), tracks: [track]))
    }

    /// The export warning counts by the rule the picture is drawn by: a short hole that is filled is not "untracked".
    @Test func theExportWarningAgreesWithWhatIsDrawn() throws {
        let s = MagicMatteStore(directory: nil)
        let (clip, m, key, tl) = try Self.maskedClip(seconds: 1)
        let fx = clip.effects(at: .zero)
        let matte = SubjectMatte(width: 2, height: 1, values: [1, 0])
        // Missing: 6 and 7 (a short hole, drawn with a neighbor) and 12...15 (four frames: stays open).
        for i in 0..<25 where ![6, 7, 12, 13, 14, 15].contains(i) { s.put(matte, key: key, pts: Double(i) / 25) }
        #expect(s.untrackedFrames(in: tl) == 4)
        for i in 0..<25 {
            let draws = s.mattes(for: fx, pts: Double(i) / 25, frameWidth: 2)[m.id] != nil
            #expect(draws == !s.missesMatte(for: fx, pts: Double(i) / 25), "frame \(i)")
            #expect(draws == !(12...15).contains(i), "frame \(i)")
        }
    }

    /// Variable frame rate: playback and export ask with the decoded frame's own time, which is found exactly whatever
    /// the spacing around it; a frame held long is no hole, and the frames next to it do not reach into it.
    @Test func framesOfVariableLengthAreFoundAtTheirOwnTimes() throws {
        let s = MagicMatteStore(directory: nil)
        // 30 fps, then one frame held for a second, then 30 fps again.
        let times = [0, 1.0 / 30, 2.0 / 30, 3.0 / 30, 3.0 / 30 + 1, 3.0 / 30 + 1 + 1.0 / 30, 3.0 / 30 + 1 + 2.0 / 30]
        for (i, t) in times.enumerated() {
            s.put(SubjectMatte(width: 8, height: 1, values: (0..<8).map { $0 <= i ? 1 : 0 }), key: "v", pts: t)
        }
        for (i, t) in times.enumerated() {
            #expect(s.matte(key: "v", pts: t)?.area == Double(i + 1))
            #expect(s.matte(key: "v", pts: t, feather: 0, expansion: 0, frameWidth: 8, fills: true)?.area == Double(i + 1))
        }
        // A time inside a frame finds it; a rounded time (Double from a rational) just before a frame finds that frame.
        // Ten milliseconds before the long one is still the frame before it, as on the monitor (SampleIndex.frame(at:)).
        #expect(s.matte(key: "v", pts: 3.0 / 30 + 0.01)?.area == 4)
        #expect(s.matte(key: "v", pts: 3.0 / 30 + 1 - 1e-9)?.area == 5)
        #expect(s.matte(key: "v", pts: 3.0 / 30 + 1 - 0.01) == nil)
        // The middle of the held frame is nobody's by the stored times alone (the store does not know how long a frame
        // is shown): a caller must ask with the frame's time, as playback and export do.
        #expect(s.matte(key: "v", pts: 3.0 / 30 + 0.5, feather: 0, expansion: 0, frameWidth: 8, fills: true) == nil)
    }

    /// Playback reads what the look-ahead prepared: nothing is decoded by the read itself. A frame the look-ahead
    /// missed is decoded on the spot: every frame with a stored matte shows its own, never a neighbor's.
    @Test func playbackReadsPreparedMattesAndDecodesAMissedFrameItself() throws {
        let s = MagicMatteStore(directory: nil)
        let (clip, m, key, _) = try Self.maskedClip(seconds: 2)
        let fx = clip.effects(at: .zero)
        for i in 0..<40 { s.put(SubjectMatte(width: 64, height: 1, values: (0..<64).map { $0 <= i ? 1 : 0 }), key: key, pts: Double(i) / 25) }
        func play(_ i: Int) -> Double? { s.mattes(for: fx, pts: Double(i) / 25, frameWidth: 64, wait: false, playing: true)[m.id]?.area }
        // The first frame of a playback has nothing prepared: decoded on the spot, once.
        #expect(play(0) == 1 && s.inlineDecodes == 1)
        for i in 0..<30 {
            s.prepare(for: fx, pts: (1...4).map { Double(i + $0) / 25 }, frameWidth: 64)
            s.waitForCovers()
            #expect(play(i + 1) == Double(i + 2))
        }
        #expect(s.inlineDecodes == 1)
        #expect(s.decodes == 34)                                 // each frame once: 0, then 1...33 ahead
        // The look-ahead is behind (nothing prepared for 34 and 35, their neighbor 33 is): each shows its own matte.
        #expect(play(34) == 35 && s.inlineDecodes == 2)
        #expect(play(35) == 36 && s.inlineDecodes == 3)
        #expect(play(39) == 40 && s.inlineDecodes == 4)          // a jump
        // Not tracked stays not drawn.
        #expect(play(60) == nil)
    }

    /// A frame tracked without the subject and its neighbors with it never stand in for each other, whichever of them
    /// the look-ahead has ready; only a real hole (no stored frame) shows the nearer tracked frame.
    @Test func aLostFrameAndAGoodNeighborNeverStandInForEachOther() throws {
        let s = MagicMatteStore(directory: nil)
        let (clip, m, key, _) = try Self.maskedClip(seconds: 2)
        let fx = clip.effects(at: .zero)
        // Frames 0...39 at 25 fps; 20 is tracked without the subject, 30 and 31 are not stored.
        for i in 0..<40 where ![20, 30, 31].contains(i) {
            s.put(SubjectMatte(width: 64, height: 1, values: (0..<64).map { $0 <= i ? 1 : 0 }), key: key, pts: Double(i) / 25)
        }
        #expect(s.putLost(key: key, pts: 20.0 / 25))
        func ahead(_ frames: [Int]) { s.prepare(for: fx, pts: frames.map { Double($0) / 25 }, frameWidth: 64); s.waitForCovers() }
        func play(_ i: Int) -> Double? { s.mattes(for: fx, pts: Double(i) / 25, frameWidth: 64, wait: false, playing: true)[m.id]?.area }
        // Only the good neighbors are ready: the lost frame still draws nothing of the picture.
        ahead([19, 21])
        #expect(play(20) == 0 && s.inlineDecodes == 1)
        #expect(play(19) == 20 && play(21) == 22 && s.inlineDecodes == 1)
        // Only the lost frame is ready: its neighbors still draw their own subject.
        let t = MagicMatteStore(directory: nil)
        for i in 0..<40 where i != 20 {
            t.put(SubjectMatte(width: 64, height: 1, values: (0..<64).map { $0 <= i ? 1 : 0 }), key: key, pts: Double(i) / 25)
        }
        #expect(t.putLost(key: key, pts: 20.0 / 25))
        t.prepare(for: fx, pts: [20.0 / 25], frameWidth: 64); t.waitForCovers()
        func playT(_ i: Int) -> Double? { t.mattes(for: fx, pts: Double(i) / 25, frameWidth: 64, wait: false, playing: true)[m.id]?.area }
        #expect(playT(19) == 20 && playT(21) == 22 && playT(22) == 23 && t.inlineDecodes == 3)
        #expect(playT(20) == 0 && t.inlineDecodes == 3)
        // A real hole: the nearer tracked frame, the one the look-ahead prepared for that time.
        ahead([30, 31])
        let before = s.inlineDecodes
        let p30 = play(30), p31 = play(31)
        #expect(abs((p30 ?? -9) - 30) <= 1 && abs((p31 ?? -9) - 33) <= 1 && s.inlineDecodes == before)
    }

    /// Several masks on one clip in steady playback: the decoded mattes kept grow with what the masks ask for, so the
    /// next frames are not pushed out before they are shown. No decode on the calling thread, each frame its own matte.
    @Test(arguments: [4, 8]) func steadyPlaybackOfSeveralMasksNeverDecodesOnTheCallingThread(masks: Int) throws {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        clip.masks = (0..<masks).map { i in
            ClipMask.makeMagic(name: "Mask (\(i + 1))", points: [MagicPoint(position: Vec2(0.1 * Double(i + 1), 0.5), subtract: false, sourceTime: .zero)])
        }
        let fx = clip.effects(at: .zero)
        let s = MagicMatteStore(directory: nil)
        // Frame f of mask n covers f + n + 1 texels.
        for (n, m) in clip.masks.enumerated() {
            for f in 0..<60 {
                s.put(SubjectMatte(width: 128, height: 1, values: (0..<128).map { $0 <= f + n ? 1 : 0 }),
                      key: m.magic!.cacheKey(media: clip.media), pts: Double(f) / 25)
            }
        }
        _ = s.mattes(for: fx, pts: 0, frameWidth: 128, wait: false)            // the paused frame before Play
        for f in 0..<50 {
            s.prepare(for: fx, pts: (1...4).map { Double(f + $0) / 25 }, frameWidth: 128)
            s.waitForCovers()
            let out = s.mattes(for: fx, pts: Double(f) / 25, frameWidth: 128, wait: false, playing: true)
            for (n, m) in clip.masks.enumerated() { #expect(out[m.id]?.area == Double(f + n + 1)) }
        }
        #expect(s.inlineDecodes == 0)
        #expect(s.decodes == masks * 54)                           // each frame of each mask once
        #expect(s.lruCount <= masks * 7)                           // the shown frame, four ahead, a margin of two
    }

    /// The look-ahead has its own lane: file reads and grown mattes queued on the background queue (a preload of
    /// other keys when a timeline is set) do not keep the next frames' mattes waiting, so steady playback decodes
    /// nothing on the calling thread while they are queued.
    @Test func aQueuedPreloadNeverStarvesTheLookAhead() throws {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        clip.masks = [ClipMask.makeMagic(name: "Mask (1)", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero)])]
        let fx = clip.effects(at: .zero)
        let s = MagicMatteStore(directory: nil)
        for f in 0..<60 {
            s.put(SubjectMatte(width: 128, height: 1, values: (0..<128).map { $0 <= f ? 1 : 0 }),
                  key: clip.masks[0].magic!.cacheKey(media: clip.media), pts: Double(f) / 25)
        }
        _ = s.mattes(for: fx, pts: 0, frameWidth: 128, wait: false)            // the paused frame before Play
        // A slow file read is running on the background queue, more are queued behind it.
        let gate = DispatchSemaphore(value: 0)
        s.holdWork(until: gate)
        s.preloadSoon(["other-1", "other-2"])
        for f in 0..<50 {
            s.prepare(for: fx, pts: (1...4).map { Double(f + $0) / 25 }, frameWidth: 128)
            s.waitForLookAhead()
            let out = s.mattes(for: fx, pts: Double(f) / 25, frameWidth: 128, wait: false, playing: true)
            #expect(out[clip.masks[0].id]?.area == Double(f + 1))
        }
        #expect(s.inlineDecodes == 0)
        gate.signal()
        s.waitForCovers()
    }

    /// The decoded mattes never take more than the byte limit, however many masks ask.
    @Test func theDecodedMattesStayUnderTheByteLimit() throws {
        let s = MagicMatteStore(directory: nil)
        let side = 1024                                            // 4 MB decoded each
        let one = SubjectMatte(width: side, height: side, values: [Float](repeating: 1, count: side * side))
        let count = MagicMatteStore.lruByteLimit / (side * side * 4) + 6
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(40, 1)), start: .zero)
        clip.masks = [ClipMask.makeMagic(name: "Mask", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero)])]
        let fx = clip.effects(at: .zero)
        let key = clip.masks[0].magic!.cacheKey(media: clip.media)
        for f in 0..<count { s.put(one, key: key, pts: Double(f) / 25) }
        s.prepare(for: fx, pts: (0..<count).map { Double($0) / 25 }, frameWidth: Double(side))
        s.waitForCovers()
        #expect(s.lruCount == MagicMatteStore.lruByteLimit / (side * side * 4))
    }
}

/// Magic mask bugs from the first app test: the clip start frame, blank picks, stale requests.
@Suite struct MagicMaskStartFrameTests {
    /// 2026-10-09 "works once, then never again": a hover request canceled while the file's first frame time was read
    /// left a wrong time behind for the whole app run; every later request then looked for its frame in the wrong place.
    @Test func aRequestCanceledWhileTheFirstFrameTimeIsReadLeavesNothingBehind() async throws {
        let url = try await MaskTrackerTests().writeMovie(firstPTS: CMTime(value: 1, timescale: 2))
        defer { try? FileManager.default.removeItem(at: url) }
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
        let canceled = Task {
            await FrameReader.$onOrigin.withValue({ withUnsafeCurrentTask { $0?.cancel() } }) {
                (try? await tracker.segment(at: 0)) != nil
            }
        }
        #expect(await canceled.value == false)
        // The next request finds the frames at the app's times and the subject on the first one.
        let index = try await AVDemuxer(url: url).index
        var seen: [Double] = []
        try await FrameReader(url: url, maxDimension: 320).forEach(from: 0, to: 2) { _, pts in seen.append(pts); return true }
        #expect(seen.count == index.count)
        for (a, e) in zip(seen, index.entries) { #expect(abs(a - Double(e.pts.value) / Double(e.pts.timescale)) < 1e-3) }
        let first = try #require(try await tracker.segment(at: 0))
        #expect(abs(first.pts) < 1e-3)
        #expect(first.frame.labels.label(at: Vec2(80.0 / 320, 90.0 / 180)) == 1)
    }

    /// A pick point is a fraction of the upright shown picture, origin top left. The analysis frame is that picture:
    /// row 0 is its top, a file shot turned (preferred transform) is upright, and stored pixels that are not square are
    /// shown wide. So the same fraction finds the object whatever the file's rotation and pixel shape.
    @Test func aPointFindsTheObjectWhateverTheFilesRotationAndPixelShape() async throws {
        // The patch near the top of the stored picture: x 60...100 of 320, y 20...60 of 180 (from the top).
        let on = Vec2(80.0 / 320, 40.0 / 180), mirrored = Vec2(80.0 / 320, 140.0 / 180)
        let plain = try await MaskTrackerTests().writeMovie(patchTop: 20)
        defer { try? FileManager.default.removeItem(at: plain) }
        let a = try #require(try await MagicMaskTracker(url: plain, limits: .current, segmenter: MagicMaskTests.PatchSegmenter()).segment(at: 0))
        #expect(a.frame.labels.label(at: on) == 1 && a.frame.labels.label(at: mirrored) == 0)
        // Stored pixels twice as wide as high: the frame is the shown picture (32:9), the fraction stays.
        let two = try #require(PixelAspect(2, 1))
        let wide = try #require(try await MagicMaskTracker(url: plain, limits: .current, segmenter: MagicMaskTests.PatchSegmenter(),
                                                           pixelAspect: two).segment(at: 0))
        let shape = Double(wide.frame.labels.width) / Double(wide.frame.labels.height)
        #expect(abs(shape - 2 * 320.0 / 180) < 0.05)
        #expect(wide.frame.labels.label(at: on) == 1 && wide.frame.labels.label(at: mirrored) == 0)
        // Shot turned a quarter clockwise: stored (x, y) is shown at (180 - y, x) of 180 x 320.
        let turned = try await MaskTrackerTests().writeMovie(patchTop: 20, transform: CGAffineTransform(rotationAngle: .pi / 2))
        defer { try? FileManager.default.removeItem(at: turned) }
        let t = try #require(try await MagicMaskTracker(url: turned, limits: .current, segmenter: MagicMaskTests.PatchSegmenter()).segment(at: 0))
        #expect(t.frame.labels.height > t.frame.labels.width)
        #expect(t.frame.labels.label(at: Vec2(140.0 / 180, 80.0 / 320)) == 1)
        #expect(t.frame.labels.label(at: Vec2(40.0 / 180, 80.0 / 320)) == 0)
        #expect(t.frame.labels.label(at: Vec2(140.0 / 180, 240.0 / 320)) == 0)
    }

    @Test func picksTheFrameTheMonitorShows() async throws {
        // The monitor shows the frame with pts <= t < next pts (`SampleIndex.frame(at:)`): the pick must be made on it,
        // also a hair before the next frame and on a frame that stays on screen for seconds.
        let url = try await MaskTrackerTests().writeMovie(hold: (frame: 11, seconds: 2))
        defer { try? FileManager.default.removeItem(at: url) }
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
        func pts(_ t: Double) async throws -> Double { try #require(try await tracker.segment(at: t)).pts }
        let frame = 1.0 / 24
        #expect(abs(try await pts(5 * frame) - 5 * frame) < 1e-6)                 // exactly on a frame
        #expect(abs(try await pts(5 * frame + 0.02) - 5 * frame) < 1e-6)          // inside it
        #expect(abs(try await pts(6 * frame - 0.00005) - 5 * frame) < 1e-6)       // 50 microseconds before the next one
        // Frame 11 is held 2 s: nothing in the quarter second before these times, the monitor still shows frame 11.
        let held = try await pts(11 * frame + 1), late = try await pts(12 * frame + 2 - 0.001)
        #expect(abs(held - 11 * frame) < 1e-6, "got \(held)")
        #expect(abs(late - 11 * frame) < 1e-6, "got \(late)")
        #expect(abs(try await pts(12 * frame + 2) - (12 * frame + 2)) < 1e-6)
        // Far past the end there is no frame: an error, not a pick on some old frame.
        await #expect(throws: SubjectFrameError.noFrame(60)) { _ = try await tracker.segment(at: 60) }
    }

    @Test func segmentsTheFirstFrameWhenItStartsAfterTheAskedTime() async throws {
        // Frame 0 at 1/48 s after an empty edit: the app (SQMedia) shows it at source time 0, AVAssetReader at 1/48 with a
        // filler frame before it. Picks and tracked mattes must use the app's times, and the clip start must find frame 0.
        let url = try await MaskTrackerTests().writeMovie(firstPTS: CMTime(value: 1, timescale: 48))
        defer { try? FileManager.default.removeItem(at: url) }
        let index = try await AVDemuxer(url: url).index
        #expect(index.entries.first?.pts == .zero)
        var seen: [Double] = []
        try await FrameReader(url: url, maxDimension: 320).forEach(from: 0, to: 1) { _, pts in seen.append(pts); return true }
        #expect(seen.count == index.count)
        for (a, e) in zip(seen, index.entries) {
            let app = Double(e.pts.value) / Double(e.pts.timescale)
            #expect(abs(a - app) < 1e-3, "reader \(a) app \(app)")
        }
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
        let first = try #require(try await tracker.segment(at: 0))
        #expect(abs(first.pts) < 1e-3)
        #expect(first.frame.labels.label(at: Vec2(80.0 / 320, 90.0 / 180)) == 1)
        #expect(first.frame.labels.label(at: Vec2(0.9, 0.9)) == 0)
        // A time between frames gives the frame shown there (the one at or before it).
        let mid = try #require(try await tracker.segment(at: 0.3))
        #expect(abs(mid.pts - 7.0 / 24) < 1e-3)
        // Pick at the clip start, Track forward from there: every frame, under the app's times.
        let store = MagicMatteStore(directory: nil)
        let click = [MagicPoint(position: Vec2(80.0 / 320, 90.0 / 180), subtract: false, sourceTime: .zero)]
        #expect(MagicMaskTracker.pick(first.frame, pts: first.pts, key: "k", points: click, store: store))
        let r = try await tracker.track(key: "k", points: click, from: 0, to: 23.0 / 24, store: store)
        #expect(r.frames == 24)
        #expect(!r.lost)
        for i in [0, 12, 23] {
            let m = try #require(store.matte(key: "k", pts: Double(i) / 24))
            let c = try #require(m.centroid)
            #expect(abs(c.x / Double(m.width) * 320 - Double(80 + 4 * i)) < 6, "frame \(i)")
        }
    }

    @Test func aBlankPickIsNothingFound() {
        var l = [UInt8](repeating: 0, count: 8 * 8)
        for i in 0..<16 { l[i] = 1 }
        let labels = InstanceLabels(width: 8, height: 8, labels: l)
        let blank = InstanceFrame(labels: labels) { _ in SubjectMatte(width: 8, height: 8, values: [Float](repeating: 0, count: 64)) }
        let store = MagicMatteStore(directory: nil)
        let p = [MagicPoint(position: Vec2(0.1, 0.1), subtract: false, sourceTime: .zero)]
        #expect(!MagicMaskTracker.pick(blank, pts: 0, key: "b", points: p, store: store))
        #expect(store.times(key: "b").isEmpty)
        // Tracking: a blank frame counts as the subject lost.
        var f = MagicFollower()
        #expect(f.step(blank, points: p) == nil)
    }
}

/// Opt-in real-media bench (`SQ_REAL_MEDIA=1`, `SQ_SUBJECT_CLIP`): Vision foreground instance segmentation per frame at the
/// tracking size, and the store's edged read (what playback pays per Magic mask frame).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SQ_REAL_MEDIA"] == "1"))
struct MagicMaskBenchTests {
    @Test func instanceSegmentationCost() async throws {
        let url = SubjectMatteBenchTests.clip
        try #require(FileManager.default.fileExists(atPath: url.path), "missing \(url.path)")
        let seg = VisionInstanceSegmenter()
        let store = MagicMatteStore(directory: nil)
        var times: [Double] = [], reads: [Double] = [], decodes: [Double] = []
        var frames = 0, size = (0, 0), objects = 0
        let reader = FrameReader(url: url, maxDimension: WorkLimits.current.subjectMaskDimension)
        try await reader.forEach(from: 0, to: 2) { pb, pts in
            let t0 = ContinuousClock.now
            let f = try seg.segment(pb)
            let dt = Double((ContinuousClock.now - t0) / .microseconds(1)) / 1000
            if frames > 0 { times.append(dt) }
            frames += 1
            if let f {
                size = (f.labels.width, f.labels.height)
                objects = max(objects, Int(f.labels.labels.max() ?? 0))
                let m = f.soft(Set(1...UInt8(max(1, f.labels.labels.max() ?? 1))))
                store.put(m, key: "b", pts: pts)
                let d0 = ContinuousClock.now
                _ = store.matte(key: "b", pts: pts)
                decodes.append(Double((ContinuousClock.now - d0) / .microseconds(1)) / 1000)
                let r0 = ContinuousClock.now
                _ = store.matte(key: "b", pts: pts, feather: 10, expansion: 4, frameWidth: 1920)
                reads.append(Double((ContinuousClock.now - r0) / .microseconds(1)) / 1000)
            }
            return frames < SubjectMatteBenchTests.frameCount
        }
        times.sort(); reads.sort(); decodes.sort()
        let med = times.isEmpty ? 0 : times[times.count / 2], p95 = times.isEmpty ? 0 : times[min(times.count - 1, times.count * 95 / 100)]
        let rmed = reads.isEmpty ? 0 : reads[reads.count / 2], dmed = decodes.isEmpty ? 0 : decodes[decodes.count / 2]
        SubjectMatteBenchTests.log("PERF magic segment \(url.lastPathComponent) frames \(frames) mask \(size.0)x\(size.1) objects \(objects) median \(String(format: "%.1f", med)) ms p95 \(String(format: "%.1f", p95)) ms; store decode median \(String(format: "%.2f", dmed)) ms, decode+edge median \(String(format: "%.2f", rmed)) ms (cpuOnly \(VisionInstanceSegmenter.compute.prefersCPU))")
        #expect(frames > 1)
    }

    /// What Track pays per frame at each analysis size: read, segment, follow (soft matte of the subject) and store.
    /// The subject is the largest object of the first frame.
    @Test(arguments: [480, 640, 960]) func trackedFrameCost(dimension: Int) async throws {
        let url = SubjectMatteBenchTests.clip
        try #require(FileManager.default.fileExists(atPath: url.path), "missing \(url.path)")
        let seg = VisionInstanceSegmenter()
        let store = MagicMatteStore(directory: nil)
        var follower = MagicFollower()
        var points: [MagicPoint] = []
        var work: [Double] = [], follow: [Double] = [], puts: [Double] = []
        var frames = 0, followed = 0, labelSize = (0, 0), matteSize = (0, 0), bytes = 0
        let reader = FrameReader(url: url, maxDimension: dimension)
        let start = ContinuousClock.now
        var afterFirst = start
        try await reader.forEach(from: 0, to: 4) { pb, pts in
            let t0 = ContinuousClock.now
            if let f = try seg.segment(pb) {
                labelSize = (f.labels.width, f.labels.height)
                if points.isEmpty {
                    var area = [Int](repeating: 0, count: 256)
                    for x in f.labels.labels where x != 0 { area[Int(x)] += 1 }
                    let best = UInt8(area.indices.max { area[$0] < area[$1] } ?? 0)
                    let own = f.labels.labels.indices.filter { f.labels.labels[$0] == best }
                    if let i = own.isEmpty ? nil : own[own.count / 2] {
                        let p = Vec2((Double(i % f.labels.width) + 0.5) / Double(f.labels.width),
                                     (Double(i / f.labels.width) + 0.5) / Double(f.labels.height))
                        points = [MagicPoint(position: p, subtract: false, sourceTime: .zero)]
                    }
                }
                let t1 = ContinuousClock.now
                if let m = follower.step(f, points: points) {
                    let t2 = ContinuousClock.now
                    matteSize = (m.width, m.height)
                    store.put(m, key: "t\(dimension)", pts: pts)
                    followed += 1
                    if frames > 0 {
                        follow.append(Double((t2 - t1) / .microseconds(1)) / 1000)
                        puts.append(Double((ContinuousClock.now - t2) / .microseconds(1)) / 1000)
                    }
                }
            }
            if frames > 0 { work.append(Double((ContinuousClock.now - t0) / .microseconds(1)) / 1000) } else { afterFirst = .now }
            frames += 1
            return frames < SubjectMatteBenchTests.frameCount
        }
        let wall = Double((ContinuousClock.now - afterFirst) / .microseconds(1)) / 1000 / Double(max(frames - 1, 1))
        let key = "t\(dimension)"
        bytes = store.snapshotFrames(key: key, times: store.times(key: key)).frames.reduce(0) { $0 + $1.data.count }
        // What playback pays the first time it shows a frame: decode plus the mask's edge (feather, expansion).
        var reads: [Double] = []
        for t in store.times(key: key) {
            let r0 = ContinuousClock.now
            _ = store.matte(key: key, pts: t, feather: 10, expansion: 4, frameWidth: 1920)
            reads.append(Double((ContinuousClock.now - r0) / .microseconds(1)) / 1000)
        }
        reads.sort()
        SubjectMatteBenchTests.log("PERF magic playback read \(dimension): matte \(matteSize.0)x\(matteSize.1) decode+edge median \(String(format: "%.2f", reads.isEmpty ? 0 : reads[reads.count / 2])) ms")
        work.sort(); follow.sort(); puts.sort()
        let med = work.isEmpty ? 0 : work[work.count / 2]
        let fmed = follow.isEmpty ? 0 : follow[follow.count / 2], pmed = puts.isEmpty ? 0 : puts[puts.count / 2]
        SubjectMatteBenchTests.log("PERF magic track \(dimension): frames \(frames) followed \(followed) labels \(labelSize.0)x\(labelSize.1) matte \(matteSize.0)x\(matteSize.1) segment+follow+store median \(String(format: "%.1f", med)) ms (follow \(String(format: "%.1f", fmed)), store \(String(format: "%.1f", pmed))), with read \(String(format: "%.1f", wall)) ms per frame, stored \(bytes / max(followed, 1)) bytes per frame")
        #expect(frames > 1)
    }

    /// What the calling (render) thread pays per playback tick for the mattes of `masks` Magic masks, at 30 fps: reading
    /// each frame itself (before the look-ahead) and with the look-ahead. Mattes of the size a 4K vertical clip is
    /// tracked at (540 x 960), feathered; no media needed.
    @Test(arguments: [1, 3, 4]) func playbackTickCost(masks: Int) throws {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        clip.masks = (0..<masks).map { i in
            var m = ClipMask.makeMagic(name: "Mask (\(i + 1))", points: [MagicPoint(position: Vec2(0.3 + 0.2 * Double(i), 0.5), subtract: false, sourceTime: .zero)])
            m.feather = AnimatedProperty(20)
            return m
        }
        let fx = clip.effects(at: .zero)
        let w = 540, h = 960, frames = 75
        var base = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dx = (Double(x) - 270) / 130, dy = (Double(y) - 480) / 320
                base[y * w + x] = Float(min(1, max(0, (1 - dx * dx - dy * dy) * 8)))
            }
        }
        func run(playing: Bool) -> (median: Double, worst: Double, inline: Int) {
            let s = MagicMatteStore(directory: nil)
            for (n, m) in clip.masks.enumerated() {
                for f in 0..<frames {
                    let k = ((f * 3 + n * 40) % h) * w      // the shape moves three rows per frame
                    s.put(SubjectMatte(width: w, height: h, values: Array(base[k...] + base[..<k])), key: m.magic!.cacheKey(media: clip.media), pts: Double(f) / 30)
                }
            }
            _ = s.mattes(for: fx, pts: 0, frameWidth: 2160, wait: false)       // the paused frame before Play
            var ms: [Double] = []
            for f in 0..<(frames - 4) {                                         // Play starts on the paused frame
                let t0 = ContinuousClock.now
                if playing { s.prepare(for: fx, pts: (1...4).map { Double(f + $0) / 30 }, frameWidth: 2160) }
                let out = s.mattes(for: fx, pts: Double(f) / 30, frameWidth: 2160, wait: false, playing: playing)
                ms.append(Double((ContinuousClock.now - t0) / .microseconds(1)) / 1000)
                #expect(out.count == masks)
                Thread.sleep(forTimeInterval: 1.0 / 30)
            }
            ms.sort()
            return (ms[ms.count / 2], ms[ms.count - 1], s.inlineDecodes)
        }
        let before = run(playing: false), after = run(playing: true)
        SubjectMatteBenchTests.log(String(format: "PERF magic playback tick, %d mask(s), 540x960 mattes, feather 20: read on the calling thread median %.2f ms worst %.2f ms; with look-ahead median %.3f ms worst %.3f ms, decodes on the calling thread %d",
                                          masks, before.median, before.worst, after.median, after.worst, after.inline))
        #expect(after.inline == 0)
    }
}
