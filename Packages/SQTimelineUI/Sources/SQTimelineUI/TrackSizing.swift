#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Track height editing (Premiere behavior): resizing one track or a whole kind, the V/A split, minimize / expand,
/// and the stepped height commands. Pure functions over the rows as drawn. Every result is a FULL set of height
/// overrides (all tracks), so a resize freezes the layout and the other rows do not re-stretch under the pointer;
/// `expandedAll` (no overrides) hands the space back to the automatic fit.
/// Default row height preset for tracks without a user override. `auto` stretches the rows to fill the panel.
public enum TrackHeightMode: String, Sendable, CaseIterable {
    case small, medium, large, auto

    /// Row height by kind; nil for `auto` (the stretch decides).
    public func height(kind: TrackKind) -> CGFloat? {
        switch self {
        case .small: 24
        case .medium: kind == .video ? Theme.Metrics.trackV1 : Theme.Metrics.trackA1
        case .large: kind == .video ? 72 : 56
        case .auto: nil
        }
    }
}

public enum TrackSizing {
    /// A minimized track: color and name only.
    public static let minimizedHeight: CGFloat = 18
    public static let maxHeight: CGFloat = 240
    /// One step of the height commands.
    public static let step: CGFloat = 8
    /// Smallest waveform band drawn in any audio row (the minimized row still shows 14 pt): cutting needs the waveform at every height.
    public static let minWaveformHeight: CGFloat = 10
    /// Grab distance around a row boundary.
    public static let grab: CGFloat = 3

    public static func clamp(_ h: CGFloat) -> CGFloat { min(max(h, minimizedHeight), maxHeight) }

    /// The heights as drawn, as overrides.
    public static func frozen(_ rows: [TrackRow]) -> [Track.ID: CGFloat] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.track, $0.height) })
    }

    /// Edge drag: `id` gets `height`; with `wholeKind` every track of that kind does.
    public static func resized(rows: [TrackRow], track id: Track.ID, to height: CGFloat, wholeKind: Bool) -> [Track.ID: CGFloat] {
        var out = frozen(rows)
        guard let row = rows.first(where: { $0.track == id }) else { return out }
        let h = clamp(height)
        for r in rows where r.track == id || (wholeKind && r.kind == row.kind) { out[r.track] = h }
        return out
    }

    /// V/A split drag by `dy` points (down = positive): the video tracks share +dy, the audio tracks share -dy.
    public static func splitDragged(rows: [TrackRow], dy: CGFloat) -> [Track.ID: CGFloat] {
        var out = frozen(rows)
        let nv = CGFloat(rows.filter { $0.kind == .video }.count), na = CGFloat(rows.filter { $0.kind == .audio }.count)
        guard nv > 0, na > 0 else { return out }
        for r in rows { out[r.track] = clamp(r.height + (r.kind == .video ? dy / nv : -dy / na)) }
        return out
    }

    /// Default V/A split: the exact middle of the track area.
    public static let defaultSplitFraction: CGFloat = 0.5
    /// Least height either side of the split keeps (one minimized row).
    public static let minSplitSide: CGFloat = minimizedHeight

    /// Offset of the split from the top of the track area, for a fraction of `available`; clamped so each side keeps
    /// `minSplitSide` (or half the area when it is tighter than that).
    public static func splitOffset(fraction: CGFloat, available: CGFloat) -> CGFloat {
        guard available > 0 else { return 0 }
        let margin = min(minSplitSide, available / 2)
        return min(max(fraction * available, margin), available - margin)
    }

    /// The fraction after dragging the split `dy` points (down = positive) from `startFraction`. Track heights are not
    /// part of it: the split only moves.
    public static func splitFraction(startFraction: CGFloat, dy: CGFloat, available: CGFloat) -> CGFloat {
        guard available > 0 else { return defaultSplitFraction }
        let moved = splitOffset(fraction: startFraction, available: available) + dy
        return splitOffset(fraction: moved / available, available: available) / available
    }

    /// `direction` +1 / -1 changes the height of the tracks of `kind` (nil = all tracks) by one step.
    public static func stepped(rows: [TrackRow], kind: TrackKind?, direction: Int) -> [Track.ID: CGFloat] {
        var out = frozen(rows)
        for r in rows where kind == nil || r.kind == kind { out[r.track] = clamp(r.height + step * CGFloat(direction)) }
        return out
    }

    /// Fit All Tracks: splits `available` points over tracks in proportion to `weights`, each clamped to
    /// `minimizedHeight...maxHeight` (water-filling: what a clamped track cannot take goes to the others). When even the
    /// minimum does not fit, every track gets the minimum and the timeline scrolls.
    public static func fitHeights(weights: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard !weights.isEmpty else { return [] }
        var h = [CGFloat?](repeating: nil, count: weights.count)
        var left = max(available, 0)
        var open = Array(weights.indices)
        while !open.isEmpty {
            let total = open.reduce(CGFloat(0)) { $0 + max(weights[$1], 0.0001) }
            var clampedAny = false
            for i in open {
                let share = left * max(weights[i], 0.0001) / total
                if share < minimizedHeight { h[i] = minimizedHeight; left -= minimizedHeight; clampedAny = true }
                else if share > maxHeight { h[i] = maxHeight; left -= maxHeight; clampedAny = true }
                if clampedAny { break }          // one clamp changes the shares: restart with the rest
            }
            if !clampedAny {
                for i in open { h[i] = left * max(weights[i], 0.0001) / total }
                break
            }
            open = open.filter { h[$0] == nil }
            left = max(left, 0)
        }
        return h.map { $0 ?? minimizedHeight }
    }

    /// Double-click on a track header: a track below the Large preset grows to Large, a larger one returns to Medium.
    /// `wholeKind` (Shift) does the same for every track of that kind, by the clicked track's current height.
    public static func toggled(rows: [TrackRow], track id: Track.ID, wholeKind: Bool) -> [Track.ID: CGFloat] {
        var out = frozen(rows)
        guard let row = rows.first(where: { $0.track == id }) else { return out }
        let large = TrackHeightMode.large.height(kind: row.kind) ?? row.height
        let target = row.height < large - 0.5 ? large : (TrackHeightMode.medium.height(kind: row.kind) ?? row.height)
        for r in rows where r.track == id || (wholeKind && r.kind == row.kind) { out[r.track] = clamp(target) }
        return out
    }

    public static func minimizedAll(rows: [TrackRow]) -> [Track.ID: CGFloat] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.track, minimizedHeight) })
    }

    /// No overrides: default heights, stretched to fill the panel.
    public static let expandedAll: [Track.ID: CGFloat] = [:]

    // MARK: Hit zones

    public enum Zone: Equatable, Sendable {
        /// Bottom edge of this track's header: drag to resize the track (Shift = every track of its kind).
        case trackEdge(Track.ID)
        /// The boundary between the lowest video track and the first audio track, across the whole width.
        case split
    }

    /// Zone under `p` (view coordinates). The V/A boundary is the split over the full width; every other row
    /// boundary resizes the track above it, in the header column only.
    public static func zone(at p: CGPoint, rows: [TrackRow], viewWidth: CGFloat) -> Zone? {
        guard p.x >= TimelineGeometry.toolColumnWidth, p.x < viewWidth, p.y > TimelineGeometry.rulerHeight else { return nil }
        let inHeader = p.x < TimelineGeometry.contentOriginX
        for (i, r) in rows.enumerated() where abs(p.y - r.maxY) <= grab {
            if i + 1 < rows.count, r.kind == .video, rows[i + 1].kind == .audio { return .split }
            if inHeader { return .trackEdge(r.track) }
        }
        return nil
    }
}

/// Track heights per sequence, kept in UserDefaults (the project file has no view-state slot, and heights are not
/// undoable edits). Key: `sq.trackHeights.<sequence id>`, value: JSON `{trackID: points}`.
public struct TrackHeightStore: Sendable {
    nonisolated(unsafe) private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static func key(_ sequence: UUID) -> String { "sq.trackHeights.\(sequence.uuidString)" }

    public func load(_ sequence: UUID) -> [Track.ID: CGFloat] {
        guard let data = defaults.data(forKey: Self.key(sequence)),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        var out: [Track.ID: CGFloat] = [:]
        for (k, v) in raw { if let id = UUID(uuidString: k), v.isFinite { out[id] = TrackSizing.clamp(CGFloat(v)) } }
        return out
    }

    public static func splitKey(_ sequence: UUID) -> String { "sq.trackSplit.\(sequence.uuidString)" }

    /// The V/A split fraction of a sequence; the default (middle) when none is stored.
    public func loadSplit(_ sequence: UUID) -> CGFloat {
        guard let v = defaults.object(forKey: Self.splitKey(sequence)) as? Double, v.isFinite else { return TrackSizing.defaultSplitFraction }
        return min(max(CGFloat(v), 0), 1)
    }

    public func saveSplit(_ fraction: CGFloat, for sequence: UUID) {
        if abs(fraction - TrackSizing.defaultSplitFraction) < 0.0005 { defaults.removeObject(forKey: Self.splitKey(sequence)); return }
        defaults.set(Double(fraction), forKey: Self.splitKey(sequence))
    }

    public func save(_ heights: [Track.ID: CGFloat], for sequence: UUID) {
        if heights.isEmpty { defaults.removeObject(forKey: Self.key(sequence)); return }
        let raw = Dictionary(uniqueKeysWithValues: heights.map { ($0.key.uuidString, Double($0.value)) })
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: Self.key(sequence)) }
    }
}
