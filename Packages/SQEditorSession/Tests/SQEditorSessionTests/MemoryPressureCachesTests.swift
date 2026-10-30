import AppKit
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQEditorSession

/// Memory audit 2026-10-04: the editor's caches follow the `MemoryPressureRegistry` and size themselves from `WorkLimits`.
@Suite struct MemoryPressureCachesTests {
    private func data(_ seconds: Int) -> WaveformData {
        let l0 = (0..<(seconds * 100)).flatMap { i -> [Float] in let a = Float(i % 50) / 60; return [-a, a] }
        return WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: seconds * 1000, baseBucketSize: 10, levels: [l0])
    }

    @Test func waveformCacheCriticalKeepsAQuarterAndNormalLiftsTheCap() {
        let reg = MemoryPressureRegistry()
        let one = WaveformCache(limit: 64, maxBytes: 1 << 30, pressure: nil)
        _ = one.resampled(media: UUID(), data: data(60), pointsPerSecond: 100)
        let entry = one.byteCount
        let cache = WaveformCache(limit: 64, maxBytes: entry * 4, pressure: reg)
        for _ in 0..<4 { _ = cache.resampled(media: UUID(), data: data(60), pointsPerSecond: 100) }
        reg.post(.critical)
        #expect(cache.count == 1)
        reg.post(.normal)
        for _ in 0..<3 { _ = cache.resampled(media: UUID(), data: data(60), pointsPerSecond: 100) }
        #expect(cache.count == 4)
    }

    @Test func waveformCacheWarningHalvesTheByteCap() {
        let reg = MemoryPressureRegistry()
        let one = WaveformCache(limit: 64, maxBytes: 1 << 30, pressure: nil)
        _ = one.resampled(media: UUID(), data: data(60), pointsPerSecond: 100)
        let entry = one.byteCount
        let cache = WaveformCache(limit: 64, maxBytes: entry * 4, pressure: reg)
        for _ in 0..<4 { _ = cache.resampled(media: UUID(), data: data(60), pointsPerSecond: 100) }
        #expect(cache.count == 4)
        reg.post(.warning)
        #expect(cache.count == 2 && cache.byteCount <= entry * 2)
        _ = cache.resampled(media: UUID(), data: data(60), pointsPerSecond: 100)
        #expect(cache.count == 2)               // the halved cap holds while the warning lasts
    }

    @MainActor @Test func projectThumbnailsDropClipFramesOnWarningAndOffscreenPostersOnCritical() {
        let reg = MemoryPressureRegistry()
        let t = ProjectThumbnails(limits: MachineResources(memoryBytes: 8 << 30, cores: 8).limits, pressure: reg)
        #expect(t.posterCostLimit == 32 << 20)
        let shown = UUID(), hidden = UUID()
        let img = NSImage(size: NSSize(width: 4, height: 4))
        t.storePosterForTesting(shown, img); t.storePosterForTesting(hidden, img)
        t.storeFrameForTesting(shown, at: .zero, height: 10, img)
        t.setVisible([shown])
        reg.post(.warning)
        #expect(t.cachedFrame(shown, at: .zero, height: 10) == nil)
        #expect(t.cachedPoster(shown) != nil && t.cachedPoster(hidden) != nil)
        reg.post(.critical)
        #expect(t.cachedPoster(shown) != nil && t.cachedPoster(hidden) == nil)
        #expect(t.posterCostLimit == 8 << 20)
        reg.post(.normal)
        #expect(t.posterCostLimit == 32 << 20)
    }

    @MainActor @Test func bigMacKeepsTheOldSizes() {
        let t = ProjectThumbnails(limits: MachineResources(memoryBytes: 32 << 30, cores: 10).limits, pressure: nil)
        #expect(t.posterCostLimit == 64 << 20)
        #expect(t.frameCostLimit == 48 << 20)
    }
}
