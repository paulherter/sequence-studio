import CoreVideo
import Foundation
import Testing
import SQCore
@testable import SQAnalysis

/// W9.8 review #3/#5/#7: person mattes off the render thread. A request never runs Vision on the caller: it returns the
/// cached matte of that frame (exact) or the last good matte of the same clip and source while the frame is segmented on
/// the scheduler's queue.
@Suite(.serialized) struct SubjectMatteSchedulerTests {
    static func frame(_ w: Int = 96, _ h: Int = 64, gray: UInt8 = 120) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
        memset(base, Int32(gray), CVPixelBufferGetBytesPerRow(pb!) * h)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        return pb!
    }

    final class Counter: @unchecked Sendable { let lock = NSLock(); var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test func firstRequestDoesNotWaitThenTheFrameIsExact() async {
        let ready = Counter()
        let s = SubjectMatteScheduler()
        s.setOnReady { ready.bump() }
        let key = SubjectMatteScheduler.Key(clip: UUID(), source: UUID())
        let pb = Self.frame()
        let first = s.matte(for: pb, rotationDegrees: 0, key: key, frameIndex: 5, quality: .fast)
        #expect(!first.exact)
        #expect(first.matte == nil)            // nothing segmented for this clip yet
        await s.waitUntilIdle()
        #expect(ready.value >= 1)              // the loop is told to redraw
        let second = s.matte(for: pb, rotationDegrees: 0, key: key, frameIndex: 5, quality: .fast)
        #expect(second.exact)
        #expect(second.matte != nil)
        #expect(s.segmentations == 1)
        #expect(!s.timings.isEmpty)
    }

    @Test func pendingFrameShowsTheLastGoodMatteOfTheSameClip() async {
        let s = SubjectMatteScheduler()
        let key = SubjectMatteScheduler.Key(clip: UUID(), source: UUID())
        let pb = Self.frame()
        _ = s.matte(for: pb, rotationDegrees: 0, key: key, frameIndex: 0, quality: .fast)
        await s.waitUntilIdle()
        let next = s.matte(for: pb, rotationDegrees: 0, key: key, frameIndex: 1, quality: .fast)
        #expect(!next.exact)
        #expect(next.matte != nil)             // frame 0's matte stands in
        // Another source of the same clip (proxy vs original) never borrows it.
        let proxy = SubjectMatteScheduler.Key(clip: key.clip, source: UUID())
        #expect(s.matte(for: pb, rotationDegrees: 0, key: proxy, frameIndex: 1, quality: .fast).matte == nil)
        await s.waitUntilIdle()
    }

    @Test func qualitiesAreSeparate() async {
        let s = SubjectMatteScheduler()
        let key = SubjectMatteScheduler.Key(clip: UUID(), source: UUID())
        _ = s.matte(for: Self.frame(), rotationDegrees: 0, key: key, frameIndex: 3, quality: .fast)
        await s.waitUntilIdle()
        #expect(s.cached(key: key, frameIndex: 3, quality: .fast) != nil)
        #expect(s.cached(key: key, frameIndex: 3, quality: .balanced) == nil)
    }

    @Test func aheadFramesAreSegmentedToo() async {
        let s = SubjectMatteScheduler()
        let key = SubjectMatteScheduler.Key(clip: UUID(), source: UUID())
        let pb = Self.frame()
        _ = s.matte(for: pb, rotationDegrees: 0, key: key, frameIndex: 10, quality: .fast, ahead: [(pb, 11), (pb, 12)])
        await s.waitUntilIdle()
        #expect(s.cached(key: key, frameIndex: 11, quality: .fast) != nil)
        #expect(s.cached(key: key, frameIndex: 12, quality: .fast) != nil)
        #expect(s.matte(for: pb, rotationDegrees: 0, key: key, frameIndex: 11, quality: .fast).exact)
    }

    @Test func retainAndForgetReleaseState() async {
        let s = SubjectMatteScheduler()
        let a = SubjectMatteScheduler.Key(clip: UUID(), source: UUID())
        let b = SubjectMatteScheduler.Key(clip: UUID(), source: UUID())
        let pb = Self.frame()
        _ = s.matte(for: pb, rotationDegrees: 0, key: a, frameIndex: 0, quality: .fast)
        _ = s.matte(for: pb, rotationDegrees: 0, key: b, frameIndex: 0, quality: .balanced)
        await s.waitUntilIdle()
        #expect(s.keys == [a, b])
        s.retain(clips: [b.clip])              // clip a left the timeline (or lost its subject mask)
        #expect(s.keys == [b])
        #expect(s.cached(key: a, frameIndex: 0, quality: .fast) == nil)
        #expect(s.matte(for: pb, rotationDegrees: 0, key: a, frameIndex: 1, quality: .fast).matte == nil)
        await s.waitUntilIdle()
        s.forget(sources: [a.source, b.source])   // relinked / proxy changed
        #expect(s.keys.isEmpty)
        #expect(s.cached(key: b, frameIndex: 0, quality: .balanced) == nil)
    }
}
