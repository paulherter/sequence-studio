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
    /// Selected caption items (separate from clips; a click on one kind clears the other).
    public private(set) var captionSelection: Set<CaptionItem.ID> = []
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
    /// Why the last command (nest, ...) was refused; nil otherwise. Cleared by the next mouse down / cancel.
    public private(set) var rejectionMessage: String?

    /// Pixels the pointer must travel before a press becomes a drag.
    public static let dragThreshold: CGFloat = 3

    private struct Gesture {
        enum Kind { case click, marquee, move, captionMove, captionTrim, trim, rippleTrim, roll, slip, slide, razor, hand }
        var kind: Kind
        var downPoint: CGPoint
        var downTime: Time
        var clip: Clip.ID?
        var caption: CaptionItem.ID?
        var edge: ClipEdge = .tail
        var active = false
        var newTrack: Track?
        var newTracks: [TrackKind: [Track]] = [:]
        var stickyRow: Int?
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
        let aliveCaptions = Set(timeline.captionTracks.flatMap(\.items).map(\.id))
        captionSelection.formIntersection(aliveCaptions)
    }

    public mutating func setSelection(_ ids: Set<Clip.ID>) { selection = ids }
    public mutating func setCaptionSelection(_ ids: Set<CaptionItem.ID>) { captionSelection = ids }

    /// Caption item under a view point (for double-click to edit text), nil elsewhere.
    public func captionItem(at p: CGPoint) -> CaptionItem.ID? {
        if case .caption(let id, _) = geometry.hitTest(p, in: timeline) { return id }
        return nil
    }

    private func captionItem(_ id: CaptionItem.ID) -> CaptionItem? {
        for t in timeline.captionTracks { if let i = t.item(id) { return i } }
        return nil
    }

    public mutating func cancel() {
        gesture = nil
        preview = timeline
        pendingEdits = []
        pendingUndoName = nil
        snapTime = nil
        marquee = nil
        isRejected = false
        rejectionMessage = nil
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
        case (.selection, .caption(let id, let zone)):
            g.caption = id
            g.kind = zone == .body ? .captionMove : .captionTrim
            g.edge = zone == .head ? .head : .tail
            selection = []
            if m.contains(.shift) && zone == .body {
                if captionSelection.contains(id) { captionSelection.remove(id) } else { captionSelection.insert(id) }
            } else if !captionSelection.contains(id) { captionSelection = [id] }
        case (.selection, .captionGap), (.selection, .captionHeader):
            if !m.contains(.shift) { selection = []; captionSelection = [] }
            g.kind = .marquee
            g.baseSelection = selection
        case (.selection, .clip(let id, let zone)):
            g.clip = id
            if !m.contains(.shift) { captionSelection = [] }
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
            if !m.contains(.shift) { selection = []; captionSelection = [] }
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
        case (.razor, .gap) where m.contains(.shift):
            // Shift+click cuts all tracks at that time, also when the pointer is over an empty spot of one track.
            g.kind = .razor
            g.active = true
            gesture = g
            razorPreview(at: p, clip: nil, modifiers: m)
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
        case .captionMove: updateCaptionMove(p)
        case .captionTrim: updateCaptionTrim(p)
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
        let commit = TimelineCommit(timeline: preview, edits: pendingEdits, undoName: name, selection: selection,
                                    captionSelection: captionSelection)
        timeline = preview
        let alive = Set(timeline.tracks.flatMap(\.clips).map(\.id))
        selection.formIntersection(alive)
        captionSelection.formIntersection(Set(timeline.captionTracks.flatMap(\.items).map(\.id)))
        return commit
    }

    // MARK: Delete

    /// Delete (lift, leaves a gap) or Shift+Delete (ripple). One commit; selection is cleared.
    public mutating func deleteSelection(ripple: Bool) -> TimelineCommit? {
        guard gesture == nil, !selection.isEmpty || !captionSelection.isEmpty else { return nil }
        var edits: [TimelineEdit] = []
        if !selection.isEmpty { let ids = Array(selection); edits.append(ripple ? .rippleDelete(ids) : .lift(ids)) }
        edits += captionSelection.sorted { $0.uuidString < $1.uuidString }.map { .deleteCaption($0) }
        guard let out = try? TimelineEdit.apply(edits, to: timeline) else { return nil }
        let commit = TimelineCommit(timeline: out, edits: edits, undoName: ripple && !selection.isEmpty ? "Ripple Delete" : "Delete",
                                    selection: [])
        timeline = out
        preview = out
        selection = []
        captionSelection = []
        return commit
    }

    // MARK: Context menu

    /// Right-click: a clip or caption under the pointer that is not selected becomes the selection (its linked
    /// group for clips); a click on a selected item keeps the selection; empty space keeps everything.
    public mutating func contextSelect(at p: CGPoint, modifiers m: GestureModifiers = []) {
        guard gesture == nil else { return }
        switch geometry.hitTest(p, in: timeline) {
        case .clip(let id, _):
            captionSelection = []
            if !selection.contains(id) { selection = group(id, linked: linked(m)) }
        case .caption(let id, _):
            selection = []
            if !captionSelection.contains(id) { captionSelection = [id] }
        default: break
        }
    }

    // MARK: Nest

    /// Result of `nest(name:in:)`: the edited project, the commit for the outer timeline and the new sequence.
    public struct NestResult: Sendable, Equatable {
        public var project: Project
        public var commit: TimelineCommit
        public var sequence: Timeline.ID
    }

    /// Premiere "Nest": replaces the selected clips with one nested clip (`Project.nest`). Needs the whole project
    /// because a new sequence is added. An empty or blank name uses "Nested Sequence NN". Nothing selected, or an
    /// SSCore error (locked track, collision...), returns nil and sets `isRejected` + `rejectionMessage`.
    /// The commit's `edits` are empty: a nest is not replayable as a timeline edit, undo with `project` snapshots.
    public mutating func nest(name: String, in project: Project) -> NestResult? {
        guard gesture == nil else { return nil }
        rejectionMessage = nil
        isRejected = false
        guard !selection.isEmpty else { return reject("Select clips to nest.") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = project
        let seq: Timeline.ID
        do {
            seq = try p.nest(clips: Array(selection), in: timeline.id, name: trimmed.isEmpty ? nil : trimmed)
        } catch {
            return reject(Self.message(for: error))
        }
        guard let out = p.timeline(timeline.id) else { return reject("Sequence not found.") }
        let newClips = Set(out.tracks.flatMap(\.clips).filter { $0.sequence == seq }.map(\.id))
        let commit = TimelineCommit(timeline: out, edits: [], undoName: "Nest", selection: newClips)
        timeline = out
        preview = out
        selection = newClips
        captionSelection = []
        return NestResult(project: p, commit: commit, sequence: seq)
    }

    private mutating func reject(_ message: String) -> NestResult? {
        isRejected = true
        rejectionMessage = message
        return nil
    }

    static func message(for error: Error) -> String {
        switch error as? EditError {
        case .trackLocked: "A selected clip is on a locked track."
        case .collision: "Another clip is in the way on the target track."
        case .nestingCycle: "A sequence cannot contain itself."
        case .clipNotFound, .timelineNotFound: "The selected clips no longer exist."
        case .emptyClip: "Nothing to nest."
        case .wrongTrackKind: "Clips do not fit that track."
        case nil: "Nest failed."
        }
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

    /// Extra points the pointer may leave the previous target row before the target changes (no flicker at row edges).
    public static let rowHysteresis: CGFloat = 6

    /// Row the pointer drags `kind` onto. Above the first row adds a video track, below the last an audio track.
    /// `sticky` (the row chosen last) is kept while the pointer stays within `rowHysteresis` of it.
    private func dropRow(kind: TrackKind, y: CGFloat, rows: [TrackRow], sticky: Int? = nil) -> (index: Int, isNew: Bool) {
        if let s = sticky, rows.indices.contains(s), rows[s].kind == kind,
           y >= rows[s].y - Self.rowHysteresis, y < rows[s].maxY + Self.rowHysteresis { return (s, false) }
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
        if g.stickyRow == nil { g.stickyRow = anchorRow }
        let drop = dropRow(kind: anchor.kind, y: p.y, rows: rows, sticky: g.stickyRow)
        if !drop.isNew { g.stickyRow = drop.index }
        gesture = g

        if insert {
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
            if d != .zero || anchorTrack != nil {
                edits.append(.moveInsert(anchorID, to: anchor.start + d, track: anchorTrack))
            } else { edits = [] }
            publish(edits, "Insert Move")
            return
        }

        // Track lanes per kind, bottom-up (index 0 = V1 / A1). A track change of k lanes applies to every moved clip of
        // either kind: video up k = audio down k, because both indices grow away from the centre (Premiere mirrors).
        var lists: [TrackKind: [Track.ID]] = [.video: [], .audio: []]
        for t in timeline.tracks { lists[t.kind, default: []].append(t.id) }
        func lane(of id: Clip.ID) -> (kind: TrackKind, index: Int)? {
            guard let tid = trackID(of: id), let t = timeline.track(tid),
                  let i = lists[t.kind]?.firstIndex(of: tid) else { return nil }
            return (t.kind, i)
        }
        guard let anchorLane = lane(of: anchorID) else { return }
        let targetLane = drop.isNew ? (lists[anchor.kind]?.count ?? 0)
            : (lists[anchor.kind]?.firstIndex(of: rows[drop.index].track) ?? anchorLane.index)
        let k = targetLane - anchorLane.index

        var usedNew: [TrackKind: Int] = [:]
        func destTrack(kind: TrackKind, index: Int) -> Track.ID {
            let existing = lists[kind] ?? []
            if index < existing.count { return existing[index] }
            var fresh = g.newTracks[kind] ?? []
            while existing.count + fresh.count <= index { fresh.append(Track(kind: kind)) }
            g.newTracks[kind] = fresh
            usedNew[kind] = max(usedNew[kind] ?? -1, index - existing.count)
            return fresh[index - existing.count].id
        }
        func dest(of id: Clip.ID) -> Track.ID? {
            guard let l = lane(of: id) else { return nil }
            let target = id == anchorID ? targetLane : max(0, l.index + k)
            let t = destTrack(kind: l.kind, index: target)
            return t == trackID(of: id) ? nil : t
        }

        let ordered = movers.compactMap(clip).sorted { a, b in
            let la = lane(of: a.id)?.index ?? 0, lb = lane(of: b.id)?.index ?? 0
            if k != 0 && la != lb { return k > 0 ? la > lb : la < lb }
            return d < .zero ? a.start < b.start : a.start > b.start
        }
        var done = Set<Clip.ID>()
        var moves: [TimelineEdit] = []
        var groupCount = 0
        for c in ordered where !done.contains(c.id) {
            let grp = group(c.id, linked: true)
            done.formUnion(grp)
            groupCount += 1
            let own = dest(of: c.id)
            var partners: [Clip.ID: Track.ID] = [:]
            for other in grp where other != c.id { if let t = dest(of: other) { partners[other] = t } }
            guard d != .zero || own != nil || !partners.isEmpty else { continue }
            moves.append(partners.isEmpty ? .move(c.id, to: c.start + d, track: own)
                                          : .moveGroup(c.id, to: c.start + d, track: own, partners: partners))
        }
        gesture = g
        var edits: [TimelineEdit] = []
        for kind in [TrackKind.video, .audio] {
            if let top = usedNew[kind] { edits += (g.newTracks[kind] ?? []).prefix(top + 1).map { .addTrack($0) } }
        }
        publish(moves.isEmpty ? [] : edits + moves, groupCount > 1 ? "Move Clips" : "Move Clip")
    }

    // MARK: Captions

    private mutating func updateCaptionMove(_ p: CGPoint) {
        guard let g = gesture, let id = g.caption, let item = captionItem(id) else { return }
        var d = travel(p, g)
        snapTime = nil
        if toolState.snapping {
            let r = snapMove(start: item.range.start + d, duration: item.range.duration, to: snapPoints(excluding: []),
                             threshold: geometry.snapThreshold(), frameDuration: geometry.frameDuration)
            d += r.delta
            snapTime = r.hit?.time
        }
        publish(d == .zero ? [] : [.moveCaption(id, to: max(item.range.start + d, .zero))], "Move Caption")
    }

    private mutating func updateCaptionTrim(_ p: CGPoint) {
        guard let g = gesture, let id = g.caption, let item = captionItem(id) else { return }
        let edgeTime = g.edge == .head ? item.range.start : item.range.end
        let d = snappedDelta(travel(p, g), from: edgeTime, excluding: [])
        publish(d == .zero ? [] : [.trimCaption(id, edge: g.edge, to: edgeTime + d)], "Trim Caption")
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

    private mutating func razorPreview(at p: CGPoint, clip id: Clip.ID?, modifiers m: GestureModifiers) {
        var t = geometry.time(atX: p.x)
        snapTime = nil
        if toolState.snapping {
            let r = snap(t, to: snapPoints(excluding: []), threshold: geometry.snapThreshold(),
                         frameDuration: geometry.frameDuration)
            t = r.time
            snapTime = r.hit?.time
        }
        let own = id.flatMap { trackID(of: $0) }
        var tracks: [Track.ID]?
        if !m.contains(.shift), let id, let own {
            let partners = group(id, linked: linked(m)).compactMap(trackID(of:))
            let set = Set(partners + [own])
            tracks = [own] + timeline.tracks.map(\.id).filter { set.contains($0) && $0 != own }
        }
        publish([.addEdit(at: t, tracks: tracks)], m.contains(.shift) ? "Razor All Tracks" : "Razor")
    }
}
