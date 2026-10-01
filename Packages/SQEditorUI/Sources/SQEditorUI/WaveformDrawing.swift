import CoreGraphics
import Foundation
import SQCore
import SQMedia

public struct WaveformStyle: Sendable, Hashable {
    public enum Shape: Sendable, Hashable { case rectified, bipolar }
    public enum Channels: Sendable, Hashable { case mixed, stacked }
    /// Rectified grows from the bottom of the clip (DESIGN.md); bipolar is centred.
    public var shape: Shape = .rectified
    /// Mixed draws one envelope (union of channels); stacked gives each channel its own lane.
    public var channels: Channels = .mixed
    public init() {}
}

/// One pixel column of waveform, already volume-scaled and clamped to -1...1.
public struct WaveformColumn: Sendable, Hashable {
    public var lo: Float
    public var hi: Float
    /// Scaled peak exceeded 0 dBFS.
    public var clipped: Bool
}

/// Pure waveform geometry: peaks -> per-pixel columns -> CGPath. No drawing state.
public enum WaveformPath {
    public struct Input: @unchecked Sendable {
        public var data: WaveformData
        /// Source range shown by the whole clip (offset + duration).
        public var source: TimeRange
        /// Width of the whole clip in pixels (columns); column i covers source time i/clipWidth of `source`.
        public var clipWidth: CGFloat
        /// Columns to produce (clip-local, clamped to the clip).
        public var visibleColumns: Range<Int>
        public var style: WaveformStyle
        /// Clip volume in dB at seconds since clip start (keyframes sampled by the caller).
        public var volumeDB: @Sendable (Double) -> Double
        /// Optional cache to reuse resampled peaks while zooming/scrolling.
        public var cache: (WaveformCache, UUID)?
        /// Reversed clip: the picture is the mirror image of the source's peaks.
        public var reversed = false
        /// Clip with a speed track: source seconds since `source.start` at a fraction 0...1 of the clip's width. When set, every
        /// column reads the peaks of the source it plays (variable speed, direction changes) instead of the linear mapping.
        public var sourceMap: (@Sendable (Double) -> Double)?

        public init(data: WaveformData, source: TimeRange, clipWidth: CGFloat, visibleColumns: Range<Int>,
                    style: WaveformStyle = .init(), volumeDB: @escaping @Sendable (Double) -> Double = { _ in 0 },
                    cache: (WaveformCache, UUID)? = nil) {
            self.data = data; self.source = source; self.clipWidth = clipWidth
            self.visibleColumns = visibleColumns; self.style = style; self.volumeDB = volumeDB; self.cache = cache
        }
    }

    /// `result[lane][column]`; one lane when mixed, one per source channel when stacked.
    public static func columns(_ input: Input) -> [[WaveformColumn]] {
        let total = max(Int(input.clipWidth.rounded()), 1)
        let vis = max(input.visibleColumns.lowerBound, 0)..<min(input.visibleColumns.upperBound, total)
        let lanes = input.style.channels == .stacked ? max(input.data.channelCount, 1) : 1
        guard !vis.isEmpty else { return Array(repeating: [], count: lanes) }
        if let map = input.sourceMap { return mappedColumns(input, map: map, total: total, vis: vis, lanes: lanes) }
        if input.reversed {                  // mirrored: compute the mirrored columns forwards, then flip them
            var mirrored = input
            mirrored.reversed = false
            mirrored.visibleColumns = (total - vis.upperBound)..<(total - vis.lowerBound)
            return columns(mirrored).map { Array($0.reversed()) }
        }

        let src = input.source
        func time(_ col: Int) -> Time { src.start + Time(src.duration.value * Int64(col), src.duration.timescale * Int64(total)) }
        let range = TimeRange(start: time(vis.lowerBound), end: time(vis.upperBound))
        let srcSeconds = max(Double(src.duration.value) / Double(src.duration.timescale), 1e-9)

        let peaks: [[WaveformPeak]]
        if let (cache, media) = input.cache {
            let r = cache.resampled(media: media, data: input.data, pointsPerSecond: Double(total) / srcSeconds)
            peaks = r.peaks(in: range, buckets: vis.count)
        } else {
            peaks = input.data.peaks(in: range, buckets: vis.count)
        }
        guard !peaks.isEmpty else { return Array(repeating: [], count: lanes) }

        let secondsPerColumn = srcSeconds / Double(total)
        var out = Array(repeating: [WaveformColumn](), count: lanes)
        for lane in 0..<lanes { out[lane].reserveCapacity(vis.count) }
        for (n, col) in vis.enumerated() {
            let db = input.volumeDB((Double(col) + 0.5) * secondsPerColumn)
            let gain = Float(db <= -120 ? 0 : pow(10, db / 20))
            for lane in 0..<lanes {
                var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                if input.style.channels == .stacked {
                    let p = peaks[min(lane, peaks.count - 1)][n]; lo = p.min; hi = p.max
                } else {
                    for ch in peaks { lo = min(lo, ch[n].min); hi = max(hi, ch[n].max) }
                }
                lo *= gain; hi *= gain
                let clipped = max(abs(lo), abs(hi)) > 1
                if input.style.shape == .rectified {
                    hi = min(max(abs(lo), abs(hi)), 1); lo = 0
                } else {
                    lo = max(lo, -1); hi = min(hi, 1)
                }
                out[lane].append(WaveformColumn(lo: lo, hi: hi, clipped: clipped))
            }
        }
        return out
    }

    /// Columns of a clip with a speed track: column `i` shows the peaks of the source range between the mapped times of its two edges.
    static func mappedColumns(_ input: Input, map: @Sendable (Double) -> Double, total: Int, vis: Range<Int>, lanes: Int) -> [[WaveformColumn]] {
        var out = Array(repeating: [WaveformColumn](), count: lanes)
        let base = Double(input.source.start.value) / Double(input.source.start.timescale)
        let fine: Int64 = 1_000_000
        func t(_ sec: Double) -> Time { Time(Int64(((base + sec) * Double(fine)).rounded()), fine) }
        for col in vis {
            let a = map(Double(col) / Double(total)), b = map(Double(col + 1) / Double(total))
            let lo = min(a, b), hi = max(max(a, b), min(a, b) + 1e-6)
            let peaks = input.data.peaks(in: TimeRange(start: t(lo), end: t(hi)), buckets: 1)
            let db = input.volumeDB(map((Double(col) + 0.5) / Double(total)))
            let gain = Float(db <= -120 ? 0 : pow(10, db / 20))
            for lane in 0..<lanes {
                var l = Float.greatestFiniteMagnitude, h = -Float.greatestFiniteMagnitude
                if peaks.isEmpty { l = 0; h = 0 }
                else if input.style.channels == .stacked { let p = peaks[min(lane, peaks.count - 1)][0]; l = p.min; h = p.max }
                else { for ch in peaks { l = min(l, ch[0].min); h = max(h, ch[0].max) } }
                l *= gain; h *= gain
                let clipped = max(abs(l), abs(h)) > 1
                if input.style.shape == .rectified { h = min(max(abs(l), abs(h)), 1); l = 0 } else { l = max(l, -1); h = min(h, 1) }
                out[lane].append(WaveformColumn(lo: l, hi: h, clipped: clipped))
            }
        }
        return out
    }

    /// Lane rectangles inside `rect` (top to bottom).
    static func laneRects(_ rect: CGRect, lanes: Int) -> [CGRect] {
        let n = max(lanes, 1)
        let h = rect.height / CGFloat(n)
        return (0..<n).map { CGRect(x: rect.minX, y: rect.minY + h * CGFloat($0), width: rect.width, height: h) }
    }

    /// Filled waveform: one 1 pt wide bar per column starting at `rect.minX + firstColumn` (y down, view coordinates).
    public static func path(columns: [[WaveformColumn]], rect: CGRect, style: WaveformStyle, firstColumn: Int = 0) -> CGPath {
        let p = CGMutablePath()
        for (lane, laneRect) in laneRects(rect, lanes: columns.count).enumerated() where lane < columns.count {
            for (i, c) in columns[lane].enumerated() {
                let x = rect.minX + CGFloat(firstColumn + i)
                guard x >= rect.minX, x + 1 <= rect.maxX + 0.001 else { continue }
                let (top, bottom) = yRange(c, laneRect, style)
                if bottom - top < 0.5 { continue }
                p.addRect(CGRect(x: x, y: top, width: 1, height: bottom - top))
            }
        }
        return p
    }

    /// Small 2 pt marks at the peak end of columns that exceed 0 dBFS.
    public static func clipMarks(columns: [[WaveformColumn]], rect: CGRect, style: WaveformStyle, firstColumn: Int = 0) -> CGPath {
        let p = CGMutablePath()
        for (lane, laneRect) in laneRects(rect, lanes: columns.count).enumerated() where lane < columns.count {
            for (i, c) in columns[lane].enumerated() where c.clipped {
                let x = rect.minX + CGFloat(firstColumn + i)
                guard x >= rect.minX, x + 1 <= rect.maxX + 0.001 else { continue }
                let (top, bottom) = yRange(c, laneRect, style)
                p.addRect(CGRect(x: x, y: top, width: 1, height: 2))
                if style.shape == .bipolar { p.addRect(CGRect(x: x, y: bottom - 2, width: 1, height: 2)) }
            }
        }
        return p
    }

    private static func yRange(_ c: WaveformColumn, _ lane: CGRect, _ style: WaveformStyle) -> (CGFloat, CGFloat) {
        switch style.shape {
        case .rectified:
            return (lane.maxY - CGFloat(c.hi) * lane.height, lane.maxY)
        case .bipolar:
            let mid = lane.midY, half = lane.height / 2
            return (mid - CGFloat(c.hi) * half, mid - CGFloat(c.lo) * half)
        }
    }

    /// Draws waveform and clip marks into `ctx`. `rect` is the clip rect in view coordinates (y down).
    public static func draw(in ctx: CGContext, input: Input, rect: CGRect, color: CGColor, clipColor: CGColor) {
        let cols = columns(input)
        let first = max(input.visibleColumns.lowerBound, 0)
        ctx.saveGState()
        ctx.addPath(path(columns: cols, rect: rect, style: input.style, firstColumn: first))
        ctx.setFillColor(color); ctx.fillPath()
        ctx.addPath(clipMarks(columns: cols, rect: rect, style: input.style, firstColumn: first))
        ctx.setFillColor(clipColor); ctx.fillPath()
        ctx.restoreGState()
    }
}

/// Whole-file peaks resampled to a zoom bucket, so scrolling and small zoom changes do not re-read the mip pyramid.
public final class ResampledPeaks: @unchecked Sendable {
    let columnsPerSecond: Double
    /// `channels[channel][column]`
    let channels: [[WaveformPeak]]

    init(columnsPerSecond: Double, channels: [[WaveformPeak]]) {
        self.columnsPerSecond = columnsPerSecond; self.channels = channels
    }

    /// Same contract as `WaveformData.peaks(in:buckets:)`, merged from the resampled columns.
    func peaks(in range: TimeRange, buckets: Int) -> [[WaveformPeak]] {
        let start = Double(range.start.value) / Double(range.start.timescale)
        let span = Double(range.duration.value) / Double(range.duration.timescale)
        let silent = WaveformPeak(min: 0, max: 0)
        return channels.map { col in
            (0..<buckets).map { i in
                let a = Int(((start + span * Double(i) / Double(buckets)) * columnsPerSecond).rounded(.down))
                let b = Int(((start + span * Double(i + 1) / Double(buckets)) * columnsPerSecond).rounded(.up))
                let lo = max(a, 0), hi = min(max(b, a + 1), col.count)
                guard lo < hi else { return silent }
                var mn = Float.greatestFiniteMagnitude, mx = -Float.greatestFiniteMagnitude
                for k in lo..<hi { mn = min(mn, col[k].min); mx = max(mx, col[k].max) }
                return WaveformPeak(min: mn, max: mx)
            }
        }
    }
}

/// Small cache keyed by (media, zoom bucket). Thread-safe; evicts oldest entries beyond `limit`.
public final class WaveformCache: @unchecked Sendable {
    struct Key: Hashable { var media: UUID; var bucket: Int }
    private let lock = NSLock()
    private var store: [Key: ResampledPeaks] = [:]
    private var order: [Key] = []
    private let limit: Int

    public init(limit: Int = 24) { self.limit = max(limit, 1) }

    public var count: Int { lock.withLock { store.count } }
    public func removeAll() { lock.withLock { store.removeAll(); order.removeAll() } }
    public func remove(media: UUID) {
        lock.withLock { store = store.filter { $0.key.media != media }; order.removeAll { $0.media == media } }
    }

    /// Half-octave zoom buckets: pps within a factor of ~1.41 share a bucket.
    public static func zoomBucket(pointsPerSecond: Double) -> Int { Int((log2(max(pointsPerSecond, 1e-6)) * 2).rounded()) }

    /// Resampled resolution for a bucket: at least as fine as the requested zoom.
    static func columnsPerSecond(bucket: Int) -> Double { pow(2, Double(bucket + 1) / 2) }

    public func resampled(media: UUID, data: WaveformData, pointsPerSecond: Double) -> ResampledPeaks {
        let key = Key(media: media, bucket: Self.zoomBucket(pointsPerSecond: pointsPerSecond))
        if let hit = lock.withLock({ store[key] }) { return hit }
        let seconds = Double(data.totalFrames) / Double(max(data.sampleRate, 1))
        let n = max(Int((seconds * Self.columnsPerSecond(bucket: key.bucket)).rounded(.up)), 1)
        let whole = data.peaks(in: TimeRange(start: .zero, duration: Time(Int64(data.totalFrames), Int64(max(data.sampleRate, 1)))), buckets: n)
        let r = ResampledPeaks(columnsPerSecond: Double(n) / max(seconds, 1e-9), channels: whole)
        lock.withLock {
            if store[key] == nil { order.append(key) }
            store[key] = r
            while order.count > limit { store[order.removeFirst()] = nil }
        }
        return r
    }
}
