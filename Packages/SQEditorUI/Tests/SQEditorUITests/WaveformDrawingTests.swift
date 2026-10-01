import CoreGraphics
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQEditorUI

/// 1 kHz-rate fake: one base bucket per 10 frames, 2 channels; bucket i of ch0 has peak (i+1)/buckets (symmetric), ch1 half of it.
private func makeData(buckets: Int = 100) -> WaveformData {
    var l0: [Float] = []
    for i in 0..<buckets {
        let v = Float(i + 1) / Float(buckets)
        l0 += [-v, v, -v / 2, v / 2]
    }
    return WaveformData(sampleRate: 1000, channelCount: 2, totalFrames: buckets * 10, baseBucketSize: 10, levels: [l0])
}

private func input(_ data: WaveformData, width: CGFloat = 100, style: WaveformStyle = .init(), offset: Int64 = 0,
                   volume: @escaping @Sendable (Double) -> Double = { _ in 0 }) -> WaveformPath.Input {
    WaveformPath.Input(data: data, source: TimeRange(start: Time(offset, 1000), duration: Time(1000, 1000)),
                       clipWidth: width, visibleColumns: 0..<Int(width), style: style, volumeDB: volume)
}

@Suite struct WaveformDrawingTests {
    @Test func mixedRectifiedColumns() {
        let cols = WaveformPath.columns(input(makeData()))
        #expect(cols.count == 1)
        #expect(cols[0].count == 100)
        #expect(cols[0][0].lo == 0)
        #expect(abs(cols[0][99].hi - 1) < 1e-6)
        #expect(abs(cols[0][49].hi - 0.5) < 1e-6)       // mixed = max over channels
        #expect(cols[0].allSatisfy { !$0.clipped })
    }

    @Test func stackedGivesTwoLanes() {
        var st = WaveformStyle(); st.channels = .stacked
        let cols = WaveformPath.columns(input(makeData(), style: st))
        #expect(cols.count == 2)
        #expect(abs(cols[1][49].hi - 0.25) < 1e-6)
    }

    @Test func bipolarKeepsSign() {
        var st = WaveformStyle(); st.shape = .bipolar
        let cols = WaveformPath.columns(input(makeData(), style: st))
        #expect(abs(cols[0][49].lo + 0.5) < 1e-6 && abs(cols[0][49].hi - 0.5) < 1e-6)
    }

    @Test func volumeScalesAndClips() {
        let cols = WaveformPath.columns(input(makeData(), volume: { _ in 6.0206 }))   // x2
        #expect(abs(cols[0][24].hi - 0.5) < 1e-3)
        #expect(!cols[0][24].clipped)
        #expect(cols[0][60].clipped)
        #expect(cols[0][60].hi == 1)                    // clamped
    }

    @Test func keyframedVolumeFollowsClipTime() {
        let cols = WaveformPath.columns(input(makeData(), volume: { $0 < 0.5 ? 0 : -120 }))
        #expect(cols[0][10].hi > 0.05)
        #expect(cols[0][90].hi < 0.001)
    }

    @Test func sourceOffsetShifts() {
        let c = WaveformPath.columns(WaveformPath.Input(
            data: makeData(), source: TimeRange(start: Time(500, 1000), duration: Time(500, 1000)),
            clipWidth: 100, visibleColumns: 0..<100, volumeDB: { _ in 0 }))
        #expect(c[0][0].hi > 0.49)
        #expect(abs(c[0][99].hi - 1) < 1e-6)
    }

    @Test func visibleRangeOnlyAndOutsideSilent() {
        var i = input(makeData())
        i.visibleColumns = 50..<60
        let cols = WaveformPath.columns(i)
        #expect(cols[0].count == 10)
        #expect(abs(cols[0][0].hi - 0.51) < 0.02)
        let c = WaveformPath.columns(input(makeData(buckets: 50)))   // 0.5 s of audio, clip shows 1 s
        #expect(c[0][90].hi == 0)
    }

    @Test func pathRectifiedGrowsFromBottom() {
        let cols = WaveformPath.columns(input(makeData()))
        let rect = CGRect(x: 10, y: 20, width: 100, height: 40)
        let b = WaveformPath.path(columns: cols, rect: rect, style: .init()).boundingBox
        #expect(abs(b.maxY - rect.maxY) < 1e-6)
        #expect(abs(b.minY - rect.minY) < 1.5)
        #expect(b.minX >= rect.minX - 1e-6 && b.maxX <= rect.maxX + 1e-6)
    }

    @Test func pathStackedUsesLanes() {
        var st = WaveformStyle(); st.channels = .stacked
        let cols = WaveformPath.columns(input(makeData(), style: st))
        let p = WaveformPath.path(columns: cols, rect: CGRect(x: 0, y: 0, width: 100, height: 40), style: st)
        #expect(p.boundingBox.maxY <= 40 + 1e-6)
        #expect(p.contains(CGPoint(x: 99.5, y: 19)))       // lane 0 (top) bottom edge
        #expect(p.contains(CGPoint(x: 99.5, y: 39)))       // lane 1 bottom edge
        #expect(!p.contains(CGPoint(x: 0.5, y: 39)))       // quiet start of lane 1
    }

    @Test func clipMarksOnlyWhereClipped() {
        let cols = WaveformPath.columns(input(makeData(), volume: { _ in 6.0206 }))
        let m = WaveformPath.clipMarks(columns: cols, rect: CGRect(x: 0, y: 0, width: 100, height: 40), style: .init())
        #expect(!m.isEmpty)
        #expect(m.boundingBox.minX >= 45)
    }

    @Test func cacheBucketsZoomAndReuses() {
        let cache = WaveformCache()
        #expect(WaveformCache.zoomBucket(pointsPerSecond: 100) == WaveformCache.zoomBucket(pointsPerSecond: 101))
        #expect(WaveformCache.zoomBucket(pointsPerSecond: 100) != WaveformCache.zoomBucket(pointsPerSecond: 400))
        let id = UUID()
        let a = cache.resampled(media: id, data: makeData(), pointsPerSecond: 100)
        let b = cache.resampled(media: id, data: makeData(), pointsPerSecond: 101)
        #expect(a === b)
        #expect(cache.count == 1)
    }

    @Test func cachedColumnsMatchDirect() {
        let cache = WaveformCache()
        var i = input(makeData())
        let direct = WaveformPath.columns(i)
        i.cache = (cache, UUID())
        let cached = WaveformPath.columns(i)
        #expect(cached[0].count == direct[0].count)
        for k in stride(from: 0, to: 100, by: 9) { #expect(abs(cached[0][k].hi - direct[0][k].hi) < 0.03) }
    }
}
