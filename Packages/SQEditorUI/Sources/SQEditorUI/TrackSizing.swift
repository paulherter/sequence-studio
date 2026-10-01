import CoreGraphics
import Foundation
import SQCore

/// Track height editing (Premiere behaviour): resizing one track or a whole kind, the V/A split, minimize / expand,
/// and the stepped height commands. Pure functions over the rows as drawn. Every result is a FULL set of height
/// overrides (all tracks), so a resize freezes the layout and the other rows do not re-stretch under the pointer;
/// `expandedAll` (no overrides) hands the space back to the automatic fit.
public enum TrackSizing {
    /// A minimized track: colour and name only.
    public static let minimizedHeight: CGFloat = 18
    public static let maxHeight: CGFloat = 240
    /// One step of the height commands.
    public static let step: CGFloat = 8
    /// Rows thinner than this draw no waveform (colour and name only).
    public static let thinThreshold: CGFloat = 22
    /// Grab distance around a row boundary.
    public static let grab: CGFloat = 3

    public static func clamp(_ h: CGFloat) -> CGFloat { min(max(h, minimizedHeight), maxHeight) }

    public static func isThin(_ height: CGFloat) -> Bool { height < thinThreshold }

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

    /// `direction` +1 / -1 changes the height of the tracks of `kind` (nil = all tracks) by one step.
    public static func stepped(rows: [TrackRow], kind: TrackKind?, direction: Int) -> [Track.ID: CGFloat] {
        var out = frozen(rows)
        for r in rows where kind == nil || r.kind == kind { out[r.track] = clamp(r.height + step * CGFloat(direction)) }
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

    public func save(_ heights: [Track.ID: CGFloat], for sequence: UUID) {
        if heights.isEmpty { defaults.removeObject(forKey: Self.key(sequence)); return }
        let raw = Dictionary(uniqueKeysWithValues: heights.map { ($0.key.uuidString, Double($0.value)) })
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: Self.key(sequence)) }
    }
}
