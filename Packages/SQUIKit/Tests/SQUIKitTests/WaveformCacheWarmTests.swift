import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQUIKit

/// Cold-start behavior of `WaveformCache`: the draw path never resamples a whole file; a background build fills the buckets.
@Suite struct WaveformCacheWarmTests {
    private func data() -> WaveformData {
        let l0 = (0..<4000).flatMap { i -> [Float] in let a = Float(i % 50) / 60; return [-a, a] }
        return WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: 4000 * 10, baseBucketSize: 10, levels: [l0])
    }

    private func waitUntil(_ timeout: Double = 30, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func coldLookupMissesAndDoesNotBuild() {
        let cache = WaveformCache()
        #expect(cache.cached(media: UUID(), pointsPerSecond: 100) == nil)
        #expect(cache.count == 0)
    }

    @Test func requestBuildFillsBucketAndNeighboursInBackground() async {
        let cache = WaveformCache()
        let id = UUID()
        cache.requestBuild(media: id, data: data(), pointsPerSecond: 100, radius: 1)
        await waitUntil { cache.count == 3 }
        #expect(cache.count == 3)
        #expect(cache.cached(media: id, pointsPerSecond: 100) != nil)
        #expect(cache.cached(media: id, pointsPerSecond: 100 * 1.42) != nil)
        #expect(cache.cached(media: id, pointsPerSecond: 100 / 1.42) != nil)
    }

    @Test func requestBuildSkipsBucketsAlreadyCachedOrBeyondTheColumnLimit() async {
        let cache = WaveformCache()
        let id = UUID()
        _ = cache.resampled(media: id, data: data(), pointsPerSecond: 100)
        cache.requestBuild(media: id, data: data(), pointsPerSecond: 100, radius: 0)
        cache.requestBuild(media: id, data: data(), pointsPerSecond: WaveformCache.maxColumnsPerSecond * 4, radius: 0)
        await cache.waitForIdle()
        #expect(cache.count == 1)
    }

    /// Eviction is least recently used, not first built: a bucket the view keeps drawing from survives the prefetch of its
    /// neighbors (which used to evict it, leaving the view on a fallback picture and rebuilding it).
    @Test func evictionKeepsTheBucketInUse() {
        let cache = WaveformCache(limit: 2)
        let a = UUID(), b = UUID(), c = UUID()
        _ = cache.resampled(media: a, data: data(), pointsPerSecond: 100)
        _ = cache.resampled(media: b, data: data(), pointsPerSecond: 100)
        #expect(cache.cached(media: a, pointsPerSecond: 100) != nil)            // a is in use
        _ = cache.resampled(media: c, data: data(), pointsPerSecond: 100)
        #expect(cache.cached(media: a, pointsPerSecond: 100) != nil)
        #expect(cache.cached(media: b, pointsPerSecond: 100) == nil)
        #expect(cache.cached(media: c, pointsPerSecond: 100) != nil)
    }

    @Test func buildNotifiesOnceBuilt() async {
        let cache = WaveformCache()
        let flag = Flag()
        cache.onBuilt = { flag.set() }
        cache.requestBuild(media: UUID(), data: data(), pointsPerSecond: 50, radius: 0)
        await waitUntil { flag.value }
        #expect(flag.value)
    }

    @Test func drawPathOnColdCacheReadsDirectlyThenWarms() async {
        let cache = WaveformCache()
        let id = UUID()
        var i = WaveformPath.Input(data: data(), source: TimeRange(start: .zero, duration: Time(4, 1)), clipWidth: 400,
                                   visibleColumns: 0..<400)
        i.cache = (cache, id)
        let cold = WaveformPath.columns(i)
        #expect(cache.count <= 1)                       // nothing was resampled inline (a background build may have landed)
        #expect(cold[0].count == 400)
        await waitUntil { cache.count >= 1 }
        let warm = WaveformPath.columns(i)
        #expect(warm[0].count == 400)
        for k in stride(from: 0, to: 400, by: 37) { #expect(abs(warm[0][k].hi - cold[0][k].hi) < 0.05) }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool { lock.withLock { v } }
    func set() { lock.withLock { v = true } }
}

extension WaveformCacheWarmTests {
    @Test func finerBucketIsUsedWhileExactOneBuilds() {
        let cache = WaveformCache()
        let id = UUID()
        let l0 = (0..<4000).flatMap { i -> [Float] in let a = Float(i % 50) / 60; return [-a, a] }
        let d = WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: 40_000, baseBucketSize: 10, levels: [l0])
        #expect(cache.cachedFiner(media: id, pointsPerSecond: 100) == nil)
        _ = cache.resampled(media: id, data: d, pointsPerSecond: 100 * 1.42)
        #expect(cache.cachedFiner(media: id, pointsPerSecond: 100) != nil)
        #expect(cache.cachedFiner(media: id, pointsPerSecond: 100 * 1.42) == nil)   // not finer than itself
    }
}
