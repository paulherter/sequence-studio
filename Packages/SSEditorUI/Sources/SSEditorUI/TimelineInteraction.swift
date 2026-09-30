import CoreGraphics
import Foundation
import SSCore

/// Pure gesture reducer for the timeline (no AppKit). The view forwards mouse events in view coordinates plus the
/// modifier state; the reducer owns selection, a live `preview` timeline and, on `mouseUp`, hands back ONE
/// `TimelineCommit` (edit list + resulting timeline + undo name) per gesture.
///
/// Flow: `mouseDown` picks the gesture from tool + hit test, `mouseDragged` recomputes `preview` from the ORIGINAL
/// `timeline` (never incrementally), `mouseUp` commits (or returns nil when nothing changed / the edit was refused).
/// `cancel()` (Escape) drops the gesture. `timeline` only changes on commit, so the caller can snapshot for undo.
public struct TimelineInteraction: Sendable {
    /// Committed timeline (what undo snapshots).
    public private(set) var timeline: Timeline
    public var geometry: TimelineGeometry
    public var toolState = ToolState()
    public var playhead: Time?
    public var markers: [Time] = []

    public private(set) var selection: Set<Clip.ID> = []
    /// What the view should draw: `timeline` with the in-flight gesture applied.
    public private(set) var preview: Timeline
    /// Edits of the in-flight gesture.
    public private(set) var pendingEdits: [TimelineEdit] = []
    public private(set) var pendingUndoName: String?
    /// Time the dragged edge/clip is snapped to (snap line in the view), nil when nothing is snapped.
    public private(set) var snapTime: Time?
    /// Marquee rectangle in view coordinates while one is being dragged.
    public private(set) var marquee: CGRect?
    /// The last drag position was refused by SSCore (locked track, collision...). Nothing will be committed.
    public private(set) var isRejected = false

    /// Pixels the pointer must travel before a press becomes a drag.
    public static let dragThreshold: CGFloat = 3

    private struct Gesture {
        enum Kind { case click, marquee, move, trim, rippleTrim, roll, slip, slide, razor, hand }
        var kind: Kind
        var downPoint: CGPoint
        var downTime: Time
        var clip: Clip.ID?
        var edge: ClipEdge = .tail
        var active = false
        var newTrack: Track?
        var baseSelection: Set<Clip.ID> = []
        var reduceTo: Set<Clip.ID>?
        var scrollOrigin = CGPoint.zero
    }
    private var gesture: Gesture?

    public init(timeline: Timeline, geometry: TimelineGeometry) {
        self.timeline = timeline
        self.preview = timeline
        self.geometry = geometry
    }

    /// Replaces the committed timeline (undo/redo, external edits). Drops any gesture and prunes the selection.
    public mutating func reset(timeline: Timeline) {
        self.timeline = timeline
        cancel()
        let alive = Set(timeline.tracks.flatMap(\.clips).map(\.id))
        selection.formIntersection(alive)
    }

    public mutating func setSelection(_ ids: Set<Clip.ID>) { selection = ids }

    public mutating func cancel() {
        gesture = nil
        preview = timeline
        pendingEdits = []
        pendingUndoName = nil
        snapTime = nil
        marquee = nil
        isRejected = false
    }

    // MARK: Lookup helpers

    private func clip(_ id: Clip.ID) -> Clip? {
        for t in timeline.tracks { if let c = t.clips.first(where: { $0.id == id }) { return c } }
        return nil
    }

    private func trackID(of id: Clip.ID) -> Track.ID? {
        timeline.tracks.first { $0.clips.contains { $0.id == id } }?.id
    }

    /// The clip plus its linked partners when `linked`.
    private func group(_ id: Clip.ID, linked: Bool) -> Set<Clip.ID> {
        guard let c = clip(id) else { return [] }
        guard linked, let l = c.link else { return [id] }
        return Set(timeline.tracks.flatMap(\.clips).filter { $0.link == l }.map(\.id))
    }

    private func groups(_ ids: Set<Clip.ID>, linked: Bool) -> Set<Clip.ID> {
        ids.reduce(into: Set<Clip.ID>()) { $0.formUnion(group($1, linked: linked)) }
    }

    private func linked(_ m: GestureModifiers) -> Bool { toolState.linkedSelection != m.contains(.option) }

    private func clipX(_ c: Clip) -> (CGFloat, CGFloat) { (geometry.x(for: c.timeline.start), geometry.x(for: c.timeline.end)) }

    private func snapPoints(excluding: Set<Clip.ID>) -> [SnapPoint] {
        timeline.snapPoints(excluding: excluding, playhead: playhead, markers: markers)
    }

    // MARK: Mouse

    public mutating func mouseDown(_ p: CGPoint, modifiers m: GestureModifiers) {
        cancel()
        let hit = geometry.hitTest(p, in: timeline)
        let downTime = geometry.time(atX: p.x)
        var g = Gesture(kind: .click, downPoint: p, downTime: downTime)
        let tool = toolState.tool

        if tool == .hand {
            g.kind = .hand
            g.scrollOrigin = CGPoint(x: geometry.scrollX, y: geometry.scrollY)
            gesture = g
            return
        }

        switch (tool, hit) {
        case (.selection, .clip(let id, let zone)):
            g.clip = id
            let grp = group(id, linked: linked(m))
            if zone != .body {
                g.kind = .trim
                g.edge = zone == .head ? .head : .tail
                if !selection.contains(id) { selection = m.contains(.shift) ? selection.union(grp) : grp }
            } else if m.contains(.shift) {
                if selection.contains(id) { selection.subtract(grp) } else { selection.formUnion(grp) }
            } else {
                g.kind = .move
                if selection.contains(id) { g.reduceTo = grp } else { selection = grp }
            }
        case (.selection, .gap), (.selection, .none):
            if !m.contains(.shift) { selection = [] }
            g.kind = .marquee
            g.baseSelection = selection
        case (.trackSelectForward, .clip(let id, _)):
            selectForward(from: timeline.tracks.first { $0.clips.contains { $0.id == id } }?.id,
                          pivot: clip(id)?.start ?? .zero, allTracks: m.contains(.shift), linked: linked(m))
        case (.trackSelectForward, .gap(let track, let t)):
            selectForward(from: track, pivot: t, allTracks: m.contains(.shift), linked: linked(m))
        case (.rippleEdit, .clip(let id, let zone)), (.rollEdit, .clip(let id, let zone)):
            g.clip = id
            g.kind = tool == .rippleEdit ? .rippleTrim : .roll
            g.edge = nearestEdge(of: id, zone: zone, x: p.x)
        case (.slip, .clip(let id, _)):
            g.kind = .slip; g.clip = id
        case (.slide, .clip(let id, _)):
            g.kind = .slide; g.clip = id
        case (.razor, .clip(let id, _)):
            g.kind = .razor; g.clip = id
            g.active = true
            gesture = g
            razorPreview(at: p, clip: id, modifiers: m)
            return
        default:
            return
        }
        gesture = g
    }

    public mutating func mouseDragged(_ p: CGPoint, modifiers m: GestureModifiers) {
        guard var g = gesture else { return }
        if !g.active {
            guard hypot(p.x - g.downPoint.x, p.y - g.downPoint.y) >= Self.dragThreshold else { return }
            g.active = true
        }
        gesture = g
        switch g.kind {
        case .click, .razor: break
        case .hand:
            geometry.scrollX = max(0, g.scrollOrigin.x - (p.x - g.downPoint.x))
            geometry.scrollY = max(0, g.scrollOrigin.y - (p.y - g.downPoint.y))
        case .marquee: updateMarquee(to: p, modifiers: m)
        case .move: updateMove(p, modifiers: m)
        case .trim, .rippleTrim: updateTrim(p)
        case .roll: updateRoll(p)
        case .slip: updateSlip(p)
        case .slide: updateSlide(p)
        }
    }

    /// Finishes the gesture. Returns the commit when the gesture changed the timeline.
    @discardableResult
    public mutating func mouseUp(_ p: CGPoint, modifiers m: GestureModifiers) -> TimelineCommit? {
        guard let g = gesture else { return nil }
        if g.active && g.kind != .razor { mouseDragged(p, modifiers: m) }
        defer {
            gesture = nil
            marquee = nil
            snapTime = nil
            pendingEdits = []
            pendingUndoName = nil
            isRejected = false
            preview = timeline
        }
        if !g.active, let r = g.reduceTo { selection = r }
        guard g.active, !isRejected, !pendingEdits.isEmpty, let name = pendingUndoName, preview != timeline else { return nil }
        let commit = TimelineCommit(timeline: preview, edits: pendingEdits, undoName: name, selection: selection)
        timeline = preview
        let alive = Set(timeline.tracks.flatMap(\.clips).map(\.id))
        selection.formIntersection(alive)
        return commit
    }

    // MARK: Delete

    /// Delete (lift, leaves a gap) or Shift+Delete (ripple). One commit; selection is cleared.
    public mutating func deleteSelection(ripple: Bool) -> TimelineCommit? {
        guard gesture == nil, !selection.isEmpty else { return nil }
        let ids = Array(selection)
        let edits: [TimelineEdit] = [ripple ? .rippleDelete(ids) : .lift(ids)]
        guard let out = try? TimelineEdit.apply(edits, to: timeline) else { return nil }
        let commit = TimelineCommit(timeline: out, edits: edits, undoName: ripple ? "Ripple Delete" : "Delete",
                                    selection: [])
        timeline = out
        preview = out
        selection = []
        return commit
    }

    // MARK: Selection tools

    private mutating func selectForward(from track: Track.ID?, pivot: Time, allTracks: Bool, linked: Bool) {
        var ids = Set<Clip.ID>()
        for t in timeline.tracks where allTracks || t.id == track {
            for c in t.clips where c.timeline.end > pivot { ids.insert(c.id) }
        }
        selection = linked ? groups(ids, linked: true) : ids
    }

    private mutating func updateMarquee(to p: CGPoint, modifiers m: GestureModifiers) {
        guard let g = gesture else { return }
        let rect = CGRect(x: min(g.downPoint.x, p.x), y: min(g.downPoint.y, p.y),
                          width: abs(p.x - g.downPoint.x), height: abs(p.y - g.downPoint.y))
        marquee = rect
        var hits = Set<Clip.ID>()
        for row in geometry.rows(for: timeline) {
            guard let t = timeline.track(row.track) else { continue }
            for c in t.clips {
                let (x0, x1) = clipX(c)
                if rect.intersects(CGRect(x: x0, y: row.y, width: max(x1 - x0, 0.001), height: row.height)) { hits.insert(c.id) }
            }
        }
        selection = g.baseSelection.union(linked(m) ? groups(hits, linked: true) : hits)
    }

    // MARK: Edge helpers

    private func nearestEdge(of id: Clip.ID, zone: ClipZone, x: CGFloat) -> ClipEdge {
        switch zone {
        case .head: return .head
        case .tail: return .tail
        case .body:
            guard let c = clip(id) else { return .tail }
            let (x0, x1) = clipX(c)
            return x < (x0 + x1) / 2 ? .head : .tail
        }
    }

    private mutating func publish(_ edits: [TimelineEdit], _ name: String) {
        pendingEdits = edits
        pendingUndoName = name
        isRejected = false
        guard !edits.isEmpty else { preview = timeline; return }
        do { preview = try TimelineEdit.apply(edits, to: timeline) } catch {
            preview = timeline
            pendingEdits = []
            isRejected = true
        }
    }

    /// Frame-snapped pointer travel since mouse down.
    private func travel(_ p: CGPoint, _ g: Gesture) -> Time { geometry.time(atX: p.x) - g.downTime }

    // MARK: Move

    private enum DropRow { case row(Int), newTrack }

    /// Row the pointer drags `kind` onto. Above the first row adds a video track, below the last an audio track.
    private func dropRow(kind: TrackKind, y: CGFloat, rows: [TrackRow]) -> (index: Int, isNew: Bool) {
        if kind == .video, let first = rows.first, y < first.y { return (-1, true) }
        if kind == .audio, let last = rows.last, y >= last.maxY { return (rows.count, true) }
        let candidates = rows.indices.filter { rows[$0].kind == kind }
        if let hit = candidates.first(where: { y >= rows[$0].y && y < rows[$0].maxY }) { return (hit, false) }
        func dist(_ i: Int) -> CGFloat { y < rows[i].y ? rows[i].y - y : y - rows[i].maxY }
        if let near = candidates.min(by: { dist($0) < dist($1) }) { return (near, false) }
        return (kind == .video ? -1 : rows.count, true)
    }

    private mutating func updateMove(_ p: CGPoint, modifiers m: GestureModifiers) {
        guard var g = gesture, let anchorID = g.clip, let anchor = clip(anchorID) else { return }
        let insert = m.contains(.command)
        let movers: [Clip.ID] = (!insert && selection.contains(anchorID)) ? Array(selection) : [anchorID]
        let everything = groups(Set(movers), linked: true)
        let minStart = everything.compactMap { clip($0)?.start }.min() ?? anchor.start

        var d = travel(p, g)
        snapTime = nil
        if toolState.snapping {
            let r = snapMove(start: anchor.start + d, duration: anchor.timeline.duration,
                             to: snapPoints(excluding: everything), threshold: geometry.snapThreshold(),
                             frameDuration: geometry.frameDuration)
            d += r.delta
            snapTime = r.hit?.time
        }
        d = max(d, .zero - minStart)

        let rows = geometry.rows(for: timeline)
        let anchorRow = rows.firstIndex { $0.track == trackID(of: anchorID) } ?? 0
        let drop = dropRow(kind: anchor.kind, y: p.y, rows: rows)
        var edits: [TimelineEdit] = []
        var anchorTrack: Track.ID?
        if drop.isNew {
            let t = g.newTrack ?? Track(kind: anchor.kind)
            g.newTrack = t
            gesture = g
            edits.append(.addTrack(t))
            anchorTrack = t.id
        } else if drop.index != anchorRow {
            anchorTrack = rows[drop.index].track
        }
        let offset = drop.isNew ? 0 : drop.index - anchorRow

        if insert {
            if d != .zero || anchorTrack != nil {
                edits.append(.moveInsert(anchorID, to: anchor.start + d, track: anchorTrack))
            } else { edits = [] }
            publish(edits, "Insert Move")
            return
        }

        let ordered = movers.compactMap(clip).sorted { d < .zero ? $0.start < $1.start : $0.start > $1.start }
        var done = Set<Clip.ID>()
        var moves: [TimelineEdit] = []
        var groupCount = 0
        for c in ordered where !done.contains(c.id) {
            done.formUnion(group(c.id, linked: true))
            groupCount += 1
            var dest: Track.ID?
            if c.id == anchorID || group(c.id, linked: true).contains(anchorID) {
                dest = c.id == anchorID ? anchorTrack : nil
            } else if offset != 0, let own = rows.firstIndex(where: { $0.track == trackID(of: c.id) }) {
                let r = own + offset
                if rows.indices.contains(r), rows[r].kind == c.kind { dest = rows[r].track }
            }
            if d != .zero || dest != nil { moves.append(.move(c.id, to: c.start + d, track: dest)) }
        }
        publish(moves.isEmpty ? [] : edits + moves, groupCount > 1 ? "Move Clips" : "Move Clip")
    }

    // MARK: Trim / ripple / roll / slip / slide

    private mutating func updateTrim(_ p: CGPoint) {
        guard let g = gesture, let id = g.clip, let c = clip(id) else { return }
        let edgeTime = g.edge == .head ? c.start : c.timeline.end
        let d = snappedDelta(travel(p, g), from: edgeTime, excluding: group(id, linked: true))
        let ripple = g.kind == .rippleTrim
        let edit: TimelineEdit = ripple ? .rippleTrim(id, edge: g.edge, by: d) : .trim(id, edge: g.edge, by: d)
        publish(d == .zero ? [] : [edit], ripple ? "Ripple Trim" : "Trim Clip")
    }

    private mutating func updateRoll(_ p: CGPoint) {
        guard let g = gesture, let id = g.clip, let c = clip(id), let track = timeline.track(trackID(of: id) ?? UUID()) else { return }
        let left: Clip?
        if g.edge == .tail { left = c } else { left = track.clips.first { $0.timeline.end == c.start } }
        guard let left else { publish([], "Roll Edit"); return }
        let d = snappedDelta(travel(p, g), from: left.timeline.end, excluding: group(left.id, linked: true))
        publish(d == .zero ? [] : [.roll(left.id, by: d)], "Roll Edit")
    }

    private mutating func updateSlip(_ p: CGPoint) {
        guard let g = gesture, let id = g.clip else { return }
        // The media follows the pointer: dragging right shows earlier material.
        let d = Time.zero - travel(p, g)
        publish(d == .zero ? [] : [.slip(id, by: d)], "Slip Clip")
    }

    private mutating func updateSlide(_ p: CGPoint) {
        guard let g = gesture, let id = g.clip, let c = clip(id) else { return }
        var d = travel(p, g)
        snapTime = nil
        if toolState.snapping {
            let r = snapMove(start: c.start + d, duration: c.timeline.duration,
                             to: snapPoints(excluding: group(id, linked: true)), threshold: geometry.snapThreshold(),
                             frameDuration: geometry.frameDuration)
            d += r.delta
            snapTime = r.hit?.time
        }
        publish(d == .zero ? [] : [.slide(id, by: d)], "Slide Clip")
    }

    /// `delta` of an edge at `edgeTime`, pulled onto a snap point when snapping is on.
    private mutating func snappedDelta(_ delta: Time, from edgeTime: Time, excluding: Set<Clip.ID>) -> Time {
        snapTime = nil
        guard toolState.snapping else { return delta }
        let r = snap(edgeTime + delta, to: snapPoints(excluding: excluding), threshold: geometry.snapThreshold(),
                     frameDuration: geometry.frameDuration)
        snapTime = r.hit?.time
        return r.time - edgeTime
    }

    // MARK: Razor

    private mutating func razorPreview(at p: CGPoint, clip id: Clip.ID, modifiers m: GestureModifiers) {
        var t = geometry.time(atX: p.x)
        snapTime = nil
        if toolState.snapping {
            let r = snap(t, to: snapPoints(excluding: []), threshold: geometry.snapThreshold(),
                         frameDuration: geometry.frameDuration)
            t = r.time
            snapTime = r.hit?.time
        }
        let own = trackID(of: id)
        var tracks: [Track.ID]?
        if !m.contains(.shift), let own {
            let partners = group(id, linked: linked(m)).compactMap(trackID(of:))
            let set = Set(partners + [own])
            tracks = [own] + timeline.tracks.map(\.id).filter { set.contains($0) && $0 != own }
        }
        publish([.addEdit(at: t, tracks: tracks)], m.contains(.shift) ? "Razor All Tracks" : "Razor")
    }
}
