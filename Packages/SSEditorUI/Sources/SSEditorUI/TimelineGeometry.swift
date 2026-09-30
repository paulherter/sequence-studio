import CoreGraphics
import Foundation
import SSCore

public enum ClipZone: Sendable, Hashable { case body, head, tail }

public enum TimelineHit: Sendable, Hashable {
    case ruler
    case toolColumn
    case header(Track.ID)
    case clip(Clip.ID, zone: ClipZone)
    /// A caption item on a caption track (same zones as clips: edges trim).
    case caption(CaptionItem.ID, zone: ClipZone)
    /// Empty space on a caption track.
    case captionGap(CaptionTrack.ID, Time)
    case captionHeader(CaptionTrack.ID)
    /// Empty space on a track; `Time` is the frame-snapped time under the pointer (never negative).
    case gap(Track.ID, Time)
    /// Below the last track row.
    case none
}

/// One laid-out track row. `y` is in view coordinates (y down, origin top-left, after scroll).
public struct TrackRow: Sendable, Hashable {
    public var track: Track.ID
    public var kind: TrackKind
    /// "V1", "A2", ...
    public var label: String
    public var y: CGFloat
    public var height: CGFloat
    public var maxY: CGFloat { y + height }
}

/// One laid-out caption track row (above the video rows).
public struct CaptionRow: Sendable, Hashable {
    public var track: CaptionTrack.ID
    /// "C1", "C2", ...
    public var label: String
    public var y: CGFloat
    public var height: CGFloat
    public var maxY: CGFloat { y + height }
}

/// Timeline view geometry. Model time is rational (`Time`); `CGFloat` only appears at the view edge.
///
/// View coordinates: origin top-left, y down. Columns: tool column `0..<38`, track headers `38..<162`, content from 162.
/// Time 0 sits at `contentOriginX - scrollX`. Rows: ruler, then video tracks top to bottom V(n)...V1, then audio A1...A(n)
/// (video/audio order inside `Timeline.tracks` is bottom-up per kind).
public struct TimelineGeometry: Sendable, Equatable {
    public static let rulerHeight: CGFloat = 22
    public static let toolColumnWidth = Theme.Metrics.toolColumn
    public static let headerWidth = Theme.Metrics.trackHeader
    public static let contentOriginX = toolColumnWidth + headerWidth
    public static let captionRowHeight: CGFloat = 22
    public static let maxTrimHandleWidth: CGFloat = 6
    public static let defaultSnapThresholdPoints: CGFloat = 8
    /// Resolution of un-snapped times and thresholds (1 microsecond).
    public static let tickScale: Int64 = 1_000_000

    public var frameDuration: Time
    /// Zoom: points per second of sequence time.
    public var pointsPerSecond: Double
    public var scrollX: CGFloat = 0
    public var scrollY: CGFloat = 0
    /// User row heights. `Track.height` (a 48 pt model hint) is deliberately ignored.
    public var heightOverrides: [Track.ID: CGFloat] = [:]
    /// Height of the track area's viewport (the whole view). When set and taller than the rows, the spare height is
    /// shared out over the tracks (see `stretchedHeights`) so the panel has no dead space. 0 disables stretching.
    public var viewportHeight: CGFloat = 0

    public init(frameDuration: Time, pointsPerSecond: Double) {
        precondition(pointsPerSecond > 0 && pointsPerSecond.isFinite)
        self.frameDuration = frameDuration
        self.pointsPerSecond = pointsPerSecond
    }

    public init(frameDuration: Time, pointsPerFrame: Double) {
        self.init(frameDuration: frameDuration,
                  pointsPerSecond: pointsPerFrame / (Double(frameDuration.value) / Double(frameDuration.timescale)))
    }

    // MARK: Time <-> x

    private static func seconds(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

    /// Width of a duration in points.
    public func width(of duration: Time) -> CGFloat { CGFloat(Self.seconds(duration) * pointsPerSecond) }

    /// View x of a time.
    public func x(for time: Time) -> CGFloat { Self.contentOriginX - scrollX + width(of: time) }

    /// Time under view x, snapped to the nearest frame.
    public func time(atX x: CGFloat) -> Time {
        let frames = (Double(x - Self.contentOriginX + scrollX) / pointsPerSecond / Self.seconds(frameDuration)).rounded()
        return frameDuration * Int64(frames)
    }

    /// Time under view x, not snapped (rounded to 1 microsecond).
    public func unsnappedTime(atX x: CGFloat) -> Time {
        let s = Double(x - Self.contentOriginX + scrollX) / pointsPerSecond
        return Time((s * Double(Self.tickScale)).rounded().int64, Self.tickScale)
    }

    /// A pixel distance as a duration, for snapping. At least one tick.
    public func snapThreshold(points: CGFloat = TimelineGeometry.defaultSnapThresholdPoints) -> Time {
        let ticks = (Double(points) / pointsPerSecond * Double(Self.tickScale)).rounded().int64
        return Time(max(ticks, 1), Self.tickScale)
    }

    // MARK: Rows

    /// Default row height, uniform per kind: video 32, audio 26.
    public static func defaultHeight(kind: TrackKind, indexInKind: Int) -> CGFloat {
        kind == .video ? Theme.Metrics.trackV1 : Theme.Metrics.trackA1
    }

    /// Largest height stretching may give a row, uniform per kind: video 120, audio 90.
    public static func maxStretchHeight(kind: TrackKind, indexInKind: Int) -> CGFloat {
        kind == .video ? 120 : 90
    }

    /// Spreads `extra` points over rows with water-filling: every row grows in proportion to its weight until it
    /// reaches its cap; what a capped row cannot take goes to the others. Rows with `cap == base` stay fixed.
    /// The result never exceeds a cap and sums to `base + min(extra, total headroom)`.
    public static func stretchedHeights(base: [CGFloat], caps: [CGFloat], weights: [CGFloat], extra: CGFloat) -> [CGFloat] {
        var h = base
        var left = max(extra, 0)
        var open = h.indices.filter { caps[$0] > h[$0] + 0.001 && weights[$0] > 0 }
        while left > 0.001 && !open.isEmpty {
            let total = open.reduce(CGFloat(0)) { $0 + weights[$1] }
            var used: CGFloat = 0
            for i in open {
                let add = min(left * weights[i] / total, caps[i] - h[i])
                h[i] += add
                used += add
            }
            left -= used
            open = open.filter { caps[$0] > h[$0] + 0.001 }
            if used < 0.0001 { break }
        }
        return h
    }

    /// Caption rows, directly under the ruler (above V tracks), in model order (first track on top).
    public func captionRows(for timeline: Timeline) -> [CaptionRow] {
        var y = Self.rulerHeight - scrollY
        return timeline.captionTracks.enumerated().map { i, t in
            defer { y += Self.captionRowHeight }
            return CaptionRow(track: t.id, label: "C\(i + 1)", y: y, height: Self.captionRowHeight)
        }
    }

    /// Total height of all caption rows.
    public func captionHeight(for timeline: Timeline) -> CGFloat {
        CGFloat(timeline.captionTracks.count) * Self.captionRowHeight
    }

    /// Media track rows; they start below the caption rows.
    public func rows(for timeline: Timeline) -> [TrackRow] {
        var entries: [(Track, String, Int)] = []   // track, label, indexInKind
        var v = 0, a = 0
        var video: [(Track, String, Int)] = [], audio: [(Track, String, Int)] = []
        for t in timeline.tracks {
            switch t.kind {
            case .video: video.append((t, "V\(v + 1)", v)); v += 1
            case .audio: audio.append((t, "A\(a + 1)", a)); a += 1
            }
        }
        entries = video.reversed() + audio
        let base = entries.map { t, _, idx in heightOverrides[t.id] ?? Self.defaultHeight(kind: t.kind, indexInKind: idx) }
        var heights = base
        let spare = viewportHeight - Self.rulerHeight - captionHeight(for: timeline) - base.reduce(0, +)
        if viewportHeight > 0, spare > 0 {
            let caps = entries.enumerated().map { i, e in
                heightOverrides[e.0.id] != nil ? base[i] : Self.maxStretchHeight(kind: e.0.kind, indexInKind: e.2)
            }
            let weights = entries.map { CGFloat($0.0.kind == .video ? 3 : 2) }
            heights = Self.stretchedHeights(base: base, caps: caps, weights: weights, extra: spare)
        }
        var y = Self.rulerHeight - scrollY + captionHeight(for: timeline)
        return entries.enumerated().map { i, e in
            let (t, label, _) = e
            defer { y += heights[i] }
            return TrackRow(track: t.id, kind: t.kind, label: label, y: y, height: heights[i])
        }
    }

    /// Total content height (ruler plus all rows, ignoring scroll).
    public func contentHeight(for timeline: Timeline) -> CGFloat {
        rows(for: timeline).reduce(Self.rulerHeight + captionHeight(for: timeline)) { $0 + $1.height }
    }

    // MARK: Trim handles

    /// Trim handle width for a clip of the given width: 6 pt, shrinking to a third of the clip on narrow clips so the
    /// body (at least the middle third) stays clickable. Zero-width clips have no handles.
    public static func trimHandleWidth(forClipWidth w: CGFloat) -> CGFloat {
        max(0, min(maxTrimHandleWidth, w / 3))
    }

    // MARK: Hit test

    /// `point` is in view coordinates. Clip edges are half-open: the start pixel belongs to the clip, the end pixel to the next.
    public func hitTest(_ point: CGPoint, in timeline: Timeline) -> TimelineHit {
        if point.y < Self.rulerHeight { return point.x < Self.toolColumnWidth ? .toolColumn : .ruler }
        if point.x < Self.toolColumnWidth { return .toolColumn }
        if let crow = captionRows(for: timeline).first(where: { point.y >= $0.y && point.y < $0.maxY }),
           let ctrack = timeline.captionTrack(crow.track) {
            if point.x < Self.contentOriginX { return .captionHeader(ctrack.id) }
            for item in ctrack.items {
                let x0 = x(for: item.range.start), x1 = x(for: item.range.end)
                guard point.x >= x0 && point.x < x1 else { continue }
                let h = Self.trimHandleWidth(forClipWidth: x1 - x0)
                let zone: ClipZone = point.x < x0 + h ? .head : (point.x >= x1 - h ? .tail : .body)
                return .caption(item.id, zone: zone)
            }
            return .captionGap(ctrack.id, max(time(atX: point.x), .zero))
        }
        guard let row = rows(for: timeline).first(where: { point.y >= $0.y && point.y < $0.maxY }),
              let track = timeline.track(row.track) else { return .none }
        if point.x < Self.contentOriginX { return .header(track.id) }
        for clip in track.clips {
            let x0 = x(for: clip.timeline.start), x1 = x(for: clip.timeline.end)
            guard point.x >= x0 && point.x < x1 else { continue }
            let h = Self.trimHandleWidth(forClipWidth: x1 - x0)
            let zone: ClipZone = point.x < x0 + h ? .head : (point.x >= x1 - h ? .tail : .body)
            return .clip(clip.id, zone: zone)
        }
        return .gap(track.id, max(time(atX: point.x), .zero))
    }
}

private extension Double {
    var int64: Int64 { Int64(self) }
}
