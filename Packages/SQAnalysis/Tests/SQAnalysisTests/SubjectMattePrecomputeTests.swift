import CoreVideo
import Foundation
import SQCore
import Synchronization
import Testing
@testable import SQAnalysis

/// Subject masks are precomputed like Magic mattes: the person matte of every source frame lands in a matte store in the
/// background, so playback reads it instead of running Vision per frame. Fake segmenter (the checker patch is the person)
/// on the 24-frame test movie of `MaskTrackerTests`.
@Suite struct SubjectMattePrecomputeTests {
    /// The checker patch (pure black/white) is the person, the gray background is not; counts its runs.
    final class PatchPerson: PersonSegmenting, @unchecked Sendable {
        let runs = Mutex(0)
        func segment(_ pb: CVPixelBuffer) throws -> SubjectMatte? {
            runs.withLock { $0 += 1 }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let base = try #require(CVPixelBufferGetBaseAddress(pb))
            let stride = CVPixelBufferGetBytesPerRow(pb)
            var v = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    let g = Int(row[x * 4 + 1])
                    if g < 40 || g > 215 { v[y * w + x] = 1 }
                }
            }
            return SubjectMatte(width: w, height: h, values: v)
        }
    }

    private func make(_ seg: PatchPerson = PatchPerson()) -> (SubjectMattePrecompute, MagicMatteStore, PatchPerson) {
        let store = MagicMatteStore(directory: nil)
        return (SubjectMattePrecompute(store: store, segmenter: seg, maxDimension: 320), store, seg)
    }

    @Test func storesASmoothedMatteForEveryFrameFromThePlayheadOn() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let (pre, store, seg) = make()
        let media = UUID()
        let key = SubjectMattePrecompute.cacheKey(media: media, path: url.path)
        let ready = Mutex(0)
        pre.setOnProgress { ready.withLock { $0 += 1 } }
        #expect(pre.request(media: media, url: url, from: 0, to: 23.0 / 24, start: 12.0 / 24))
        await pre.waitUntilIdle()
        #expect(store.times(key: key).count == 24)
        #expect(seg.runs.withLock { $0 } == 24)
        #expect(ready.withLock { $0 } >= 1)
        // Patch center moves 4 px of 320 per frame.
        for i in [0, 12, 23] {
            let m = try #require(store.matte(key: key, pts: Double(i) / 24))
            let c = try #require(m.centroid)
            #expect(abs(c.x / Double(m.width) * 320 - Double(80 + 4 * i)) < 6, "frame \(i)")
        }
    }

    struct Failing: PersonSegmenting {
        struct Busy: Error {}
        func segment(_ pb: CVPixelBuffer) throws -> SubjectMatte? { throw Busy() }
    }

    @Test func aFailedSegmentationIsNotStoredAsNoPerson() async throws {
        // Vision throwing (busy Neural Engine) is not "no person": nothing is stored, the live path tries that frame.
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let pre = SubjectMattePrecompute(store: store, segmenter: Failing(), maxDimension: 320)
        let media = UUID()
        pre.request(media: media, url: url, from: 0, to: 23.0 / 24, start: 0)
        await pre.waitUntilIdle()
        #expect(store.times(key: SubjectMattePrecompute.cacheKey(media: media, path: url.path)).isEmpty)
    }

    @Test func aRangeAlreadyAskedForIsNotSegmentedAgain() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let (pre, _, seg) = make()
        let media = UUID()
        #expect(pre.request(media: media, url: url, from: 0, to: 23.0 / 24, start: 0))
        await pre.waitUntilIdle()
        #expect(!pre.request(media: media, url: url, from: 0.1, to: 0.5, start: 0.2))
        await pre.waitUntilIdle()
        #expect(seg.runs.withLock { $0 } == 24)
        // A new instance (next launch) finds the frames in the store and decodes nothing new.
        let again = SubjectMattePrecompute(store: pre.store, segmenter: seg, maxDimension: 320)
        _ = again.request(media: media, url: url, from: 0, to: 23.0 / 24, start: 0)
        await again.waitUntilIdle()
        #expect(seg.runs.withLock { $0 } == 24)
    }

    @Test func retainStopsWorkForMediaNoLongerShown() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let (pre, store, _) = make()
        let media = UUID()
        _ = pre.request(media: media, url: url, from: 0, to: 23.0 / 24, start: 0)
        pre.retain(media: [])
        await pre.waitUntilIdle()
        #expect(store.times(key: SubjectMattePrecompute.cacheKey(media: media, path: url.path)).count < 24)
        // Asked again later: runs (the earlier request was dropped with the media).
        #expect(pre.request(media: media, url: url, from: 0, to: 23.0 / 24, start: 0))
        await pre.waitUntilIdle()
        #expect(store.times(key: SubjectMattePrecompute.cacheKey(media: media, path: url.path)).count == 24)
    }

    /// Calls `onFirst` inside its first segmentation (a `forget` that arrives while a job reads).
    final class Interrupting: PersonSegmenting, @unchecked Sendable {
        let onFirst = Mutex<(@Sendable () -> Void)?>(nil)
        let runs = Mutex(0)
        func segment(_ pb: CVPixelBuffer) throws -> SubjectMatte? {
            if runs.withLock({ $0 += 1; return $0 }) == 1 { onFirst.withLock { $0 }?() }
            return SubjectMatte(width: 1, height: 1, values: [1])
        }
    }

    /// `forget` / `retain` cancel the running job's read itself (a read that hangs in the decoder never reaches the
    /// check at its next frame), also when that media has nothing queued and was never dropped before.
    @Test func forgetStopsTheRunningRead() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let seg = Interrupting()
        let pre = SubjectMattePrecompute(store: MagicMatteStore(directory: nil), segmenter: seg, maxDimension: 320)
        let media = UUID()
        let stopped = Mutex<Bool?>(nil)
        seg.onFirst.withLock {
            $0 = { [pre] in
                let stop = pre.runningStop
                pre.forget(media: [media])
                stopped.withLock { $0 = stop?.isStopped }
            }
        }
        _ = pre.request(media: media, url: url, from: 0, to: 23.0 / 24, start: 0)
        await pre.waitUntilIdle()
        #expect(stopped.withLock { $0 } == true)
        #expect(seg.runs.withLock { $0 } == 1 && pre.runningStop == nil)
    }

    @Test func cacheKeyFollowsMediaAndFile() {
        let a = UUID()
        #expect(SubjectMattePrecompute.cacheKey(media: a, path: "/x.mov") == SubjectMattePrecompute.cacheKey(media: a, path: "/x.mov"))
        #expect(SubjectMattePrecompute.cacheKey(media: a, path: "/x.mov") != SubjectMattePrecompute.cacheKey(media: a, path: "/y.mov"))
        #expect(SubjectMattePrecompute.cacheKey(media: a, path: "/x.mov") != SubjectMattePrecompute.cacheKey(media: UUID(), path: "/x.mov"))
    }

    @Test func sweepRemovesOnlyWrittenKeysTheProjectNoLongerUses() {
        let s = MagicMatteStore(directory: nil)
        let m = SubjectMatte(width: 1, height: 1, values: [1])
        s.put(m, key: "old", pts: 0)
        s.put(m, key: "new", pts: 0)
        #expect(s.sweep(keeping: ["new"]) == ["old"])
        #expect(s.times(key: "old").isEmpty)
        #expect(s.times(key: "new").count == 1)
        #expect(s.writtenKeys.isEmpty)
        s.put(m, key: "other", pts: 0)
        s.forgetWritten()
        #expect(s.sweep(keeping: []).isEmpty)
        #expect(s.times(key: "other").count == 1)
    }
}

@Suite struct SubjectMatteCoverageTests {
    @Test func coverageNeedsBothEndsAndNoHole() {
        let all = (0..<24).map { Double($0) / 24 }
        #expect(SubjectMattePrecompute.covers(all, from: 0, to: 23.0 / 24))
        #expect(SubjectMattePrecompute.covers(all, from: 0.2, to: 0.5))
        #expect(!SubjectMattePrecompute.covers(all.filter { $0 < 0.3 || $0 > 0.4 }, from: 0, to: 23.0 / 24))
        #expect(!SubjectMattePrecompute.covers(Array(all.prefix(12)), from: 0, to: 23.0 / 24))
        #expect(!SubjectMattePrecompute.covers([], from: 0, to: 1))
    }
}
