#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import SQMedia

public struct WaveformStyle: Sendable, Hashable {
    public enum Shape: Sendable, Hashable { case rectified, bipolar }
    public enum Channels: Sendable, Hashable { case mixed, stacked }
    /// Rectified grows from the bottom of the clip (DESIGN.md); bipolar is centered.
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
        let sp = TimelineSignpost.log.beginInterval("waveformColumns")
        defer { TimelineSignpost.log.endInterval("waveformColumns", sp) }
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
        // Beyond ~500 columns per second the whole-file resample would be huge (hours at deep zoom): read the mip pyramid
        // for the visible range only.
        if let (cache, media) = input.cache, Double(total) / srcSeconds <= WaveformCache.maxColumnsPerSecond {
            let pps = Double(total) / srcSeconds
            if let r = cache.cached(media: media, pointsPerSecond: pps) {
                peaks = r.peaks(in: range, buckets: vis.count)
            } else if let r = cache.cachedFiner(media: media, pointsPerSecond: pps) {
                // A finer bucket is already there: same picture, no inline work. The exact bucket is built behind it.
                cache.requestBuild(media: media, data: input.data, pointsPerSecond: pps, radius: 2)
                peaks = r.peaks(in: range, buckets: vis.count)
            } else {
                // Cold bucket: never resample the whole file inside a draw (hundreds of ms on a long file). Read the visible
                // range from the mip pyramid now and let a background build fill this bucket and its neighbors.
                cache.requestBuild(media: media, data: input.data, pointsPerSecond: pps, radius: 2)
                peaks = input.data.peaks(in: range, buckets: vis.count)
            }
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
    public static func laneRects(_ rect: CGRect, lanes: Int) -> [CGRect] {
        let n = max(lanes, 1)
        let h = rect.height / CGFloat(n)
        return (0..<n).map { CGRect(x: rect.minX, y: rect.minY + h * CGFloat($0), width: rect.width, height: h) }
    }

    /// The bars of `path` as rectangles (one 1 pt column each): the canvas toolkit fills these directly.
    public static func bars(columns: [[WaveformColumn]], rect: CGRect, style: WaveformStyle, firstColumn: Int = 0) -> [CGRect] {
        var out: [CGRect] = []
        for (lane, laneRect) in laneRects(rect, lanes: columns.count).enumerated() where lane < columns.count {
            for (i, c) in columns[lane].enumerated() {
                let x = rect.minX + CGFloat(firstColumn + i)
                guard x >= rect.minX, x + 1 <= rect.maxX + 0.001 else { continue }
                let (top, bottom) = yRange(c, laneRect, style)
                if bottom - top < 0.5 { continue }
                out.append(CGRect(x: x, y: top, width: 1, height: bottom - top))
            }
        }
        return out
    }

    /// The 0 dBFS marks of `clipMarks` as rectangles.
    public static func clipMarkRects(columns: [[WaveformColumn]], rect: CGRect, style: WaveformStyle, firstColumn: Int = 0) -> [CGRect] {
        var out: [CGRect] = []
        for (lane, laneRect) in laneRects(rect, lanes: columns.count).enumerated() where lane < columns.count {
            for (i, c) in columns[lane].enumerated() where c.clipped {
                let x = rect.minX + CGFloat(firstColumn + i)
                guard x >= rect.minX, x + 1 <= rect.maxX + 0.001 else { continue }
                let (top, bottom) = yRange(c, laneRect, style)
                out.append(CGRect(x: x, y: top, width: 1, height: 2))
                if style.shape == .bipolar { out.append(CGRect(x: x, y: bottom - 2, width: 1, height: 2)) }
            }
        }
        return out
    }

    /// The step outlines of `outline` as point lists (portable: the canvas toolkit fills them as polygons).
    public static func outlinePolygons(columns: [[WaveformColumn]], rect: CGRect, style: WaveformStyle, firstColumn: Int = 0) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        var tops: [CGPoint] = [], bottoms: [CGPoint] = []
        func flush() {
            guard !tops.isEmpty else { return }
            out.append(tops + bottoms.reversed())
            tops.removeAll(keepingCapacity: true); bottoms.removeAll(keepingCapacity: true)
        }
        for (lane, laneRect) in laneRects(rect, lanes: columns.count).enumerated() where lane < columns.count {
            tops.reserveCapacity(columns[lane].count * 2); bottoms.reserveCapacity(columns[lane].count * 2)
            for (i, c) in columns[lane].enumerated() {
                let x = rect.minX + CGFloat(firstColumn + i)
                guard x >= rect.minX, x + 1 <= rect.maxX + 0.001 else { flush(); continue }
                let (top, bottom) = yRange(c, laneRect, style)
                if bottom - top < 0.5 { flush(); continue }
                let x1 = CGRect(x: x, y: top, width: 1, height: bottom - top).maxX     // the same edge `path`'s rectangle has
                if let last = tops.last, last.x != x { flush() }
                tops.append(CGPoint(x: x, y: top)); tops.append(CGPoint(x: x1, y: top))
                bottoms.append(CGPoint(x: x, y: bottom)); bottoms.append(CGPoint(x: x1, y: bottom))
            }
            flush()
        }
        return out
    }

    #if canImport(CoreGraphics)
    /// Filled waveform: one 1 pt wide bar per column starting at `rect.minX + firstColumn` (y down, view coordinates).
    public static func path(columns: [[WaveformColumn]], rect: CGRect, style: WaveformStyle, firstColumn: Int = 0) -> CGPath {
        let p = CGMutablePath()
        for r in bars(columns: columns, rect: rect, style: style, firstColumn: firstColumn) { p.addRect(r) }
        return p
    }

    /// The same area as `path` as one polygon per run of drawn columns (a step outline: top edge left to right, bottom edge
    /// back), so a fill rasterizes a few hundred points instead of one rectangle per column. Same pixels as `path`.
    public static func outline(columns: [[WaveformColumn]], rect: CGRect, style: WaveformStyle, firstColumn: Int = 0) -> CGPath {
        let p = CGMutablePath()
        for poly in outlinePolygons(columns: columns, rect: rect, style: style, firstColumn: firstColumn) {
            p.addLines(between: poly)
            p.closeSubpath()
        }
        return p
    }

    /// Small 2 pt marks at the peak end of columns that exceed 0 dBFS.
    public static func clipMarks(columns: [[WaveformColumn]], rect: CGRect, style: WaveformStyle, firstColumn: Int = 0) -> CGPath {
        let p = CGMutablePath()
        for r in clipMarkRects(columns: columns, rect: rect, style: style, firstColumn: firstColumn) { p.addRect(r) }
        return p
    }
    #endif

    public static func yRange(_ c: WaveformColumn, _ lane: CGRect, _ style: WaveformStyle) -> (CGFloat, CGFloat) {
        switch style.shape {
        case .rectified:
            return (lane.maxY - CGFloat(c.hi) * lane.height, lane.maxY)
        case .bipolar:
            let mid = lane.midY, half = lane.height / 2
            return (mid - CGFloat(c.hi) * half, mid - CGFloat(c.lo) * half)
        }
    }

    #if canImport(CoreGraphics)
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
    #endif
}

/// Whole-file peaks resampled to a zoom bucket, so scrolling and small zoom changes do not re-read the mip pyramid.
public final class ResampledPeaks: @unchecked Sendable {
    let columnsPerSecond: Double
    /// `channels[channel][column]`
    let channels: [[WaveformPeak]]

    init(columnsPerSecond: Double, channels: [[WaveformPeak]]) {
        self.columnsPerSecond = columnsPerSecond; self.channels = channels
    }

    var byteCount: Int { channels.reduce(0) { $0 + $1.count * MemoryLayout<WaveformPeak>.stride } }

    /// Same contract as `WaveformData.peaks(in:buckets:)`, merged from the resampled columns.
    func peaks(in range: TimeRange, buckets: Int) -> [[WaveformPeak]] {
        let start = Double(range.start.value) / Double(range.start.timescale)
        let span = Double(range.duration.value) / Double(range.duration.timescale)
        let silent = WaveformPeak(min: 0, max: 0)
        // Plain loops over buffers (no closures, no per-bucket bounds checks): this runs per audio clip per draw.
        var bounds = [(Int, Int)](repeating: (0, 0), count: max(buckets, 0))
        for i in 0..<max(buckets, 0) {
            let a = Int(((start + span * Double(i) / Double(buckets)) * columnsPerSecond).rounded(.down))
            let b = Int(((start + span * Double(i + 1) / Double(buckets)) * columnsPerSecond).rounded(.up))
            bounds[i] = (a, max(b, a + 1))
        }
        return channels.map { col in
            col.withUnsafeBufferPointer { c in
                var out = [WaveformPeak](repeating: silent, count: bounds.count)
                for (i, (a, b)) in bounds.enumerated() {
                    let lo = max(a, 0), hi = min(b, c.count)
                    guard lo < hi else { continue }
                    var mn = Float.greatestFiniteMagnitude, mx = -Float.greatestFiniteMagnitude
                    for k in lo..<hi { mn = min(mn, c[k].min); mx = max(mx, c[k].max) }
                    out[i] = WaveformPeak(min: mn, max: mx)
                }
                return out
            }
        }
    }
}

/// Small cache keyed by (media, zoom bucket). Thread-safe; evicts the least recently used entries beyond `limit`.
public final class WaveformCache: @unchecked Sendable {
    struct Key: Hashable { var media: UUID; var bucket: Int }
    private let lock = NSLock()
    private var store: [Key: ResampledPeaks] = [:]
    private var order: [Key] = []
    private let limit: Int
    private let maxBytes: Int
    private var bytes = 0
    /// Zoom beyond this many columns per second is not cached (the draw reads the visible range directly).
    public static let maxColumnsPerSecond: Double = 500

    /// Memory pressure in force: the byte cap is `pressure.budget(maxBytes)` (`MemoryPressureRegistry`).
    private var pressure: MemoryPressure = .normal
    private var pressureToken: MemoryPressureToken?

    /// `maxBytes`: `WorkLimits.waveformCacheBytes` (32 MB on 8 GB Macs, 64 MB from 16 GB). `pressure`: the registry it
    /// shrinks with (nil = none).
    public init(limit: Int = 24, maxBytes: Int = WorkLimits.current.waveformCacheBytes,
                pressure registry: MemoryPressureRegistry? = .shared) {
        self.limit = max(limit, 1); self.maxBytes = maxBytes
        pressureToken = registry?.register("waveforms") { [weak self] in self?.applyMemoryPressure($0) }
    }

    /// Caps the cache at its share of `maxBytes` and drops the least recently used entries beyond it; normal lifts the cap.
    public func applyMemoryPressure(_ level: MemoryPressure) {
        lock.withLock {
            pressure = level
            let cap = level.budget(maxBytes)
            while !order.isEmpty, bytes > cap {
                if let gone = store.removeValue(forKey: order.removeFirst()) { bytes -= gone.byteCount }
            }
        }
    }

    public var count: Int { lock.withLock { store.count } }
    public var byteCount: Int { lock.withLock { bytes } }
    public func removeAll() { lock.withLock { store.removeAll(); order.removeAll(); bytes = 0 } }
    public func remove(media: UUID) {
        lock.withLock {
            store = store.filter { $0.key.media != media }; order.removeAll { $0.media == media }
            bytes = store.values.reduce(0) { $0 + $1.byteCount }
        }
    }

    /// Half-octave zoom buckets: pps within a factor of ~1.41 share a bucket.
    public static func zoomBucket(pointsPerSecond: Double) -> Int { Int((log2(max(pointsPerSecond, 1e-6)) * 2).rounded()) }

    /// Resampled resolution for a bucket: at least as fine as the requested zoom.
    static func columnsPerSecond(bucket: Int) -> Double { pow(2, Double(bucket + 1) / 2) }

    /// Non-blocking lookup: the resampled peaks of the bucket, or nil when it is not built yet.
    public func cached(media: UUID, pointsPerSecond: Double) -> ResampledPeaks? {
        let key = Key(media: media, bucket: Self.zoomBucket(pointsPerSecond: pointsPerSecond))
        return lock.withLock { touch(key) }
    }

    /// The stored peaks for `key`, marked as just used (eviction is least recently used, so the buckets on screen are not
    /// evicted by the prefetch of their neighbors). Call with `lock` held.
    private func touch(_ key: Key) -> ResampledPeaks? {
        guard let hit = store[key] else { return nil }
        if order.last != key, let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
        return hit
    }

    /// A cached bucket up to two half-octaves finer than `pointsPerSecond` (at least as detailed as asked for).
    public func cachedFiner(media: UUID, pointsPerSecond: Double) -> ResampledPeaks? {
        let b = Self.zoomBucket(pointsPerSecond: pointsPerSecond)
        return lock.withLock { (1...2).lazy.compactMap { self.touch(Key(media: media, bucket: b + $0)) }.first }
    }

    /// Called on the main queue (coalesced) after a background build stored new peaks.
    public var onBuilt: (@Sendable () -> Void)? {
        get { lock.withLock { builtHandler } }
        set { lock.withLock { builtHandler = newValue } }
    }

    private var builtHandler: (@Sendable () -> Void)?
    private var inFlight: Set<Key> = []
    private var started = 0
    /// Background builds started so far (tests: a draw that started none drew from a settled cache).
    public var buildsStarted: Int { lock.withLock { started } }
    private var notifyScheduled = false
    private let builder = DispatchQueue(label: "sq.waveform.cache", qos: .utility)

    /// Builds the bucket for `pointsPerSecond` and `radius` buckets either side on a background queue (one build at a time),
    /// skipping buckets that are cached, being built, or beyond `maxColumnsPerSecond`. The requested bucket goes first.
    public func requestBuild(media: UUID, data: WaveformData, pointsPerSecond: Double, radius: Int) {
        let centre = Self.zoomBucket(pointsPerSecond: pointsPerSecond)
        var order = [centre]
        if radius > 0 { for d in 1...radius { order += [centre + d, centre - d] } }
        for bucket in order {
            let key = Key(media: media, bucket: bucket)
            guard Self.columnsPerSecond(bucket: bucket) <= Self.maxColumnsPerSecond * 1.5 else { continue }
            let start = lock.withLock { () -> Bool in
                if store[key] != nil || inFlight.contains(key) { return false }
                inFlight.insert(key); started += 1; return true
            }
            guard start else { continue }
            builder.async { [self] in
                _ = resampled(media: media, bucket: bucket, data: data)
                lock.withLock { _ = inFlight.remove(key) }
                notifyBuilt()
            }
        }
    }

    /// Suspends until every queued background build has finished (tests).
    public func waitForIdle() async {
        await withCheckedContinuation { c in builder.async { c.resume() } }
    }

    private func notifyBuilt() {
        let schedule = lock.withLock { () -> Bool in
            if notifyScheduled { return false }
            notifyScheduled = true; return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            let h = lock.withLock { () -> (@Sendable () -> Void)? in notifyScheduled = false; return builtHandler }
            h?()
        }
    }

    public func resampled(media: UUID, data: WaveformData, pointsPerSecond: Double) -> ResampledPeaks {
        resampled(media: media, bucket: Self.zoomBucket(pointsPerSecond: pointsPerSecond), data: data)
    }

    private func resampled(media: UUID, bucket: Int, data: WaveformData) -> ResampledPeaks {
        let key = Key(media: media, bucket: bucket)
        if let hit = lock.withLock({ store[key] }) { return hit }
        let sp = TimelineSignpost.log.beginInterval("waveformBucketBuild")
        defer { TimelineSignpost.log.endInterval("waveformBucketBuild", sp) }
        let seconds = Double(data.totalFrames) / Double(max(data.sampleRate, 1))
        let n = max(Int((seconds * Self.columnsPerSecond(bucket: key.bucket)).rounded(.up)), 1)
        let whole = data.peaks(in: TimeRange(start: .zero, duration: Time(Int64(data.totalFrames), Int64(max(data.sampleRate, 1)))), buckets: n)
        let r = ResampledPeaks(columnsPerSecond: Double(n) / max(seconds, 1e-9), channels: whole)
        lock.withLock {
            if let old = store[key] { bytes -= old.byteCount } else { order.append(key) }
            store[key] = r
            bytes += r.byteCount
            // Least recently used first, by count and by bytes; the entry just made always stays.
            while order.count > 1, order.count > limit || bytes > pressure.budget(maxBytes) {
                if let gone = store.removeValue(forKey: order.removeFirst()) { bytes -= gone.byteCount }
            }
        }
        return r
    }
}
