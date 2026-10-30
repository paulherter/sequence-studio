#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Pure gesture reducer for the timeline (no AppKit). The view forwards mouse events in view coordinates plus the
/// modifier state; the reducer owns selection, a live `preview` timeline and, on `mouseUp`, hands back ONE
/// `TimelineCommit` (edit list + resulting timeline + undo name) per gesture.
///
/// Flow: `mouseDown` picks the gesture from tool + hit test, `mouseDragged` recomputes `preview` from the ORIGINAL
/// `timeline` (never incrementally), `mouseUp` commits (or returns nil when nothing changed / the edit was refused).
/// `cancel()` (Escape) drops the gesture. `timeline` only changes on commit, so the caller can snapshot for undo.
public struct TimelineInteraction: Sendable {
    /// Committed timeline (what undo snapshots).
    public private(set) var timeline: Timeline { didSet { index = TimelineClipIndex(timeline); snapCache = nil } }
    /// Clip ID -> track/position of `timeline` (rebuilt whenever `timeline` changes: init, reset, commit). Drag events
    /// look clips up many times per event; a scan over all tracks was about a third of the drag cost.
    private var index: TimelineClipIndex
    public var geometry: TimelineGeometry
    public var toolState = ToolState()
    public var playhead: Time?
    public var markers: [Time] = []

    public private(set) var selection: Set<Clip.ID> = []
    /// Selected caption items (separate from clips; a click on one kind clears the other).
    public private(set) var captionSelection: Set<CaptionItem.ID> = []
    /// Selected clip edges (click on a head or tail); a click elsewhere clears them.
    public private(set) var edgeSelection: EdgeSelection?
    /// Selected gap between two clips (Delete closes it).
    public private(set) var gapSelection: GapSelection?
    /// What the view should draw: `timeline` with the in-flight gesture applied.
    public private(set) var preview: Timeline
    /// Edits of the in-flight gesture.
    public private(set) var pendingEdits: [TimelineEdit] = []
    public private(set) var pendingUndoName: String?
    /// Time the dragged edge/clip is snapped to (snap line in the view), nil when nothing is snapped.
    public private(set) var snapTime: Time?
    /// Option-drag on a cut (audio-only roll): the cut and the applied audio offset (negative = audio leads, J cut). The view draws
    /// the ghost edge at the cut and the label; nil outside that gesture.
    public private(set) var splitRollGhost: SplitRollGhost?
    /// Marquee rectangle in view coordinates while one is being dragged.
    public private(set) var marquee: CGRect?
    /// The last drag position was refused by SQCore (locked track, collision...). Nothing will be committed.
    public private(set) var isRejected = false
    /// Why the last command (nest, ...) was refused; nil otherwise. Cleared by the next mouse down / cancel.
    public private(set) var rejectionMessage: String?
    /// Why the gesture that just ended with `mouseUp` was refused (nil: it was not). The host shows it in the status bar.
    public private(set) var releasedRejection: String?

    /// Pixels the pointer must travel before a press becomes a drag.
    public static let dragThreshold: CGFloat = 3

    private struct Gesture {
        enum Kind { case click, marquee, move, captionMove, captionTrim, wordRetime, trim, rippleTrim, rateStretch, roll, splitRoll, slip, slide, razor, hand }
        var kind: Kind
        var downPoint: CGPoint
        var downTime: Time
        var clip: Clip.ID?
        var caption: CaptionItem.ID?
        /// `.wordRetime`: the word whose edge is dragged.
        var word = 0
        var edge: ClipEdge = .tail
        /// `.splitRoll`: the cut whose audio edit is dragged.
        var cut: Time = .zero
        var active = false
        var newTrack: Track?
        var newTracks: [TrackKind: [Track]] = [:]
        var stickyRow: Int?
        var baseSelection: Set<Clip.ID> = []
        /// Captions selected before a marquee started (a Shift marquee keeps them).
        var baseCaptions: Set<CaptionItem.ID> = []
        /// Everything selected before the press (clips, captions, gap, edges): Esc on a marquee puts it back.
        var beforePress: (clips: Set<Clip.ID>, captions: Set<CaptionItem.ID>, gap: GapSelection?, edges: EdgeSelection?)?
        var reduceTo: Set<Clip.ID>?
        var scrollOrigin = CGPoint.zero
        /// Option-drag: identities of the copies, stable for the whole gesture.
        var copyIDs: [Clip.ID: Clip.ID] = [:]
        var copyLinks: [UUID: UUID] = [:]
        /// Shift while moving: the axis the pointer moved along first.
        var axisLock = AxisLock()
        /// Option went down before Command: a later Command makes it an insert copy, not a rearrange.
        var copyLatched = false
        /// Clips the gesture edits; linked partners outside it stay put (Option-click / Linked Selection off).
        /// nil: linked partners follow as usual.
        var scope: Set<Clip.ID>?
    }
    /// Copies the in-flight Option-drag creates (they become the selection on commit).
    private var pendingCopies: Set<Clip.ID> = []
    private var gesture: Gesture?
    /// No gesture in flight (the view may start a track resize).
    public var isIdle: Bool { gesture == nil }

    public init(timeline: Timeline, geometry: TimelineGeometry) {
        self.timeline = timeline
        self.index = TimelineClipIndex(timeline)
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
        setWordSelection(wordSelection)
        edgeSelection = edgeSelection.flatMap { EdgeEdits.pruned($0, in: timeline) }
        if let g = gapSelection, timeline.gap(on: g.track, at: g.range.start) != g.range { gapSelection = nil }
    }

    /// The selected word of a caption (caption track at word level). Its caption is selected with it; any other press
    /// clears it. Delete removes the word, a double-click types into it.
    public private(set) var wordSelection: CaptionWordRef?

    /// Selects a word (nil: none). A word that does not exist is dropped.
    public mutating func setWordSelection(_ ref: CaptionWordRef?) {
        guard let ref, let item = captionItem(ref.caption), item.tokens.indices.contains(ref.index) else { wordSelection = nil; return }
        wordSelection = ref
    }

    /// A word edit made outside a gesture (typed, inserted, deleted, split, joined, replaced): the result becomes the
    /// committed timeline. One commit, so one undo step.
    public mutating func commitCaptionEdit(_ out: Timeline, undoName: String, captions: Set<CaptionItem.ID>, word: CaptionWordRef?) -> TimelineCommit {
        cancel()
        timeline = out
        preview = out
        selection = []
        captionSelection = captions.intersection(Set(out.captionTracks.flatMap(\.items).map(\.id)))
        setWordSelection(word)
        return TimelineCommit(timeline: out, edits: [], undoName: undoName, selection: [], captionSelection: captionSelection)
    }

    /// Clears edge and gap selection (they are exclusive with clip selection).
    private mutating func clearEdgeAndGap() { edgeSelection = nil; gapSelection = nil }

    /// Escape with nothing in flight: only the selection goes (gap, edges). The timeline is not touched.
    @discardableResult
    public mutating func clearGapAndEdgeSelection() -> Bool {
        guard isIdle, gapSelection != nil || edgeSelection != nil else { return false }
        clearEdgeAndGap()
        return true
    }

    public mutating func setEdgeSelection(_ e: EdgeSelection?) { edgeSelection = e; if e != nil { gapSelection = nil } }

    /// Programmatic selection (Cmd+A, paste, undo...). A non-empty selection replaces any edge or gap selection;
    /// an empty echo after an edge click leaves it alone.
    public mutating func setSelection(_ ids: Set<Clip.ID>) {
        selection = ids
        if !ids.isEmpty { clearEdgeAndGap() }
    }
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
        // Esc during a marquee: the selection from before the press comes back (the press itself cleared it).
        if let g = gesture, g.kind == .marquee, let b = g.beforePress {
            selection = b.clips; captionSelection = b.captions; gapSelection = b.gap; edgeSelection = b.edges
        }
        snapInverted = false
        moveHint = nil
        reorderGhost = nil
        gesture = nil
        preview = timeline
        pendingEdits = []
        pendingUndoName = nil
        snapTime = nil
        marquee = nil
        isRejected = false
        rejectionMessage = nil
        pendingCopies = []
    }

    // MARK: Lookup helpers

    private func clip(_ id: Clip.ID) -> Clip? { index.clip(id, in: timeline) }

    private func trackID(of id: Clip.ID) -> Track.ID? { index.trackID(of: id) }

    /// The clip plus its linked partners when `linked`.
    private func group(_ id: Clip.ID, linked: Bool) -> Set<Clip.ID> {
        guard let c = clip(id) else { return [] }
        guard linked, let l = c.link else { return [id] }
        return Set(index.clips(linkedBy: l))
    }

    private func groups(_ ids: Set<Clip.ID>, linked: Bool) -> Set<Clip.ID> {
        ids.reduce(into: Set<Clip.ID>()) { $0.formUnion(group($1, linked: linked)) }
    }

    /// What a click selects: the clip's link group, plus its bundle (v57) and the bundle members' partners when `linked`
    /// (Option-click picks the one clip, like Premiere's groups).
    private func selectionGroup(_ id: Clip.ID, linked: Bool) -> Set<Clip.ID> {
        guard linked, let b = clip(id)?.bundle else { return group(id, linked: linked) }
        return groups(Set(index.clips(bundledBy: b)).union([id]), linked: true)
    }

    private func selectionGroups(_ ids: Set<Clip.ID>, linked: Bool) -> Set<Clip.ID> {
        ids.reduce(into: Set<Clip.ID>()) { $0.formUnion(selectionGroup($1, linked: linked)) }
    }

    private func linked(_ m: GestureModifiers) -> Bool { toolState.linkedSelection != m.contains(.option) }

    /// Scope of a tool gesture on `id` (B, N, Y, U): the selection when it holds the clip (a partner left out of it
    /// stays put), else the clip's group as Linked Selection / Option pick it.
    private func toolScope(_ id: Clip.ID, _ m: GestureModifiers) -> Set<Clip.ID> {
        selection.contains(id) ? selection : group(id, linked: linked(m))
    }

    /// The clip plus the linked partners inside `scope` (all partners without a scope).
    private func group(_ id: Clip.ID, within scope: Set<Clip.ID>?) -> Set<Clip.ID> {
        let g = group(id, linked: true)
        return scope.map { g.intersection($0).union([id]) } ?? g
    }

    private func clipX(_ c: Clip) -> (CGFloat, CGFloat) { (geometry.x(for: c.timeline.start), geometry.x(for: c.timeline.end)) }

    /// Snap points of the committed `timeline` for one exclusion set, playhead and markers. The first event of a gesture
    /// computes them; later events reuse them while the key is the same (on 2000 clips recomputing was ~60 % of a drag
    /// event). Gestures snap against `timeline`, never `preview`, so ripple/Fast Cut shifts and the moving selection (the
    /// `excluding` key) need nothing extra; `timeline` changing (commit, reset) drops the cache.
    private struct SnapCache: Sendable {
        var excluding: Set<Clip.ID>
        var playhead: Time?
        var markers: [Time]
        var points: [SnapPoint]
    }
    private var snapCache: SnapCache?
    /// Tests: false recomputes on every call (the reference the cache is checked against).
    var snapCacheEnabled = true

    private func cachedSnapPoints(excluding: Set<Clip.ID>) -> [SnapPoint]? {
        guard snapCacheEnabled, let c = snapCache, c.playhead == playhead, c.markers == markers,
              c.excluding == excluding else { return nil }
        return c.points
    }

    private mutating func snapPoints(excluding: Set<Clip.ID>) -> [SnapPoint] {
        if let pts = cachedSnapPoints(excluding: excluding) { return pts }
        let pts = timeline.snapPoints(excluding: excluding, playhead: playhead, markers: markers, includeKeyframes: true)
        if snapCacheEnabled { snapCache = SnapCache(excluding: excluding, playhead: playhead, markers: markers, points: pts) }
        return pts
    }

    /// While a Slip drag runs: first and last frame of the slipped clip for the two-up viewer (SQMonitorUI
    /// `SlipTwoUpView`); nil otherwise. Seek `preview` to `headTime` and `tailTime`.
    public var slipTwoUp: SlipTwoUp? {
        guard let g = gesture, g.kind == .slip, g.active, let id = g.clip,
              let now = index.clip(id, in: preview), let start = clip(id) else { return nil }
        return SlipTwoUp(clip: now, frameDuration: timeline.frameDuration, startSource: start.source.start)
    }

    /// What the move gesture in flight does ("Insert", "Rearrange", "Copy", "Insert copy"); the view shows it as a hint.
    public private(set) var moveHint: String?
    /// Cursor hint while the Blade is dragged: the cut was made at the click, the drag does nothing.
    public static let razorDragHint = "Cut made at the click"


    /// Fast Cut live reorder preview: while a main-track clip is dragged along V1, where the pointer holds it (the clip
    /// floats there; `preview` already shows the neighbors opened up and the slot the drop lands in). nil otherwise.
    public private(set) var reorderGhost: ReorderGhost?

    public struct ReorderGhost: Sendable, Equatable {
        public var track: Track.ID
        public var range: TimeRange
        public var name: String
    }

    /// Hold-S: snapping flipped for the gesture in flight (Premiere's momentary snap toggle). Reset by every mouse down.
    public var snapInverted = false
    private var snappingOn: Bool { toolState.snapping != snapInverted }

    // MARK: Mouse

    public mutating func mouseDown(_ p: CGPoint, modifiers m: GestureModifiers) {
        cancel()
        snapInverted = false
        let hit = geometry.hitTest(p, in: timeline)
        let downTime = geometry.time(atX: p.x)
        var g = Gesture(kind: .click, downPoint: p, downTime: downTime)
        g.beforePress = (selection, captionSelection, gapSelection, edgeSelection)
        // Position (Fast Cut): selects and drags like Selection; `publish` turns the drag into a position move.
        let tool = toolState.timelineTool == .position ? .selection : toolState.timelineTool
        let hadEdges = edgeSelection
        clearEdgeAndGap()
        wordSelection = nil

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
            // Two depths: a press selects the caption; a press on a word of the caption that already was the selection
            // selects that word. So Delete after one click removes the caption, never a word by accident.
            let wasTheSelection = captionSelection == [id] && selection.isEmpty
            selection = []
            if m.contains(.shift) && zone == .body {
                if captionSelection.contains(id) { captionSelection.remove(id) } else { captionSelection.insert(id) }
            } else if !captionSelection.contains(id) { captionSelection = [id] }
            // Word level: one of a word's inner edges retimes it (at either depth). The caption's own edges keep
            // trimming the caption, and a Shift-click only changes which captions are selected.
            if zone == .body, !m.contains(.shift), let w = CaptionWordLayout.hit(p, caption: id, in: timeline, geometry: geometry) {
                if wasTheSelection { wordSelection = w.ref }
                if w.zone != .body {
                    g.kind = .wordRetime
                    g.word = w.ref.index
                    g.edge = w.zone == .head ? .head : .tail
                }
            }
        case (.selection, .captionGap), (.selection, .captionHeader):
            if !m.contains(.shift) { selection = []; captionSelection = [] }
            g.kind = .marquee
            g.baseSelection = selection; g.baseCaptions = captionSelection
        case (.selection, .clip(let id, let zone)):
            g.clip = id
            if !m.contains(.shift) { captionSelection = [] }
            let grp = selectionGroup(id, linked: linked(m))
            if zone != .body {
                // Premiere: a click on an edge selects the edge (not the clip). Cmd = ripple trim; Shift adds the edge
                // (both sides of an edit = rolling edit).
                g.edge = zone == .head ? .head : .tail
                let ref = EdgeRef(clip: id, edge: g.edge)
                var sel = EdgeSelection(edges: [ref], ripple: m.contains(.command), linked: linked(m))
                // Bundle (v57): a plain trim also takes the same edge of every member sharing its time (the bundle's outer edge).
                if !sel.ripple, sel.linked {
                    sel.edges += timeline.bundleEdgePeers(of: id, edge: g.edge).map { EdgeRef(clip: $0, edge: g.edge) }
                }
                if m.contains(.shift), let had = hadEdges, had.ripple == sel.ripple {
                    sel.edges = had.edges.contains(ref) ? had.edges.filter { $0 != ref } : had.edges + [ref]
                } else if let had = hadEdges, had.edges.contains(ref), !m.contains(.command) {
                    sel = had                         // dragging an already selected edge keeps the selection
                }
                selection = []
                edgeSelection = sel.edges.isEmpty ? nil : sel
                if let e = edgeSelection {
                    g.kind = EdgeEdits.isRoll(e, in: timeline) ? .roll : (e.ripple ? .rippleTrim : .trim)
                    g.scope = e.scope
                }
                // Option on a cut of linked A/V: the drag moves only the audio edit (J / L cut in one gesture).
                if m.contains(.option), !m.contains(.shift), !m.contains(.command), let cut = SplitRoll.cut(for: ref, in: timeline) {
                    g.kind = .splitRoll; g.cut = cut
                }
            } else if m.contains(.shift) {
                if selection.contains(id) { selection.subtract(grp) } else { selection.formUnion(grp) }
            } else {
                g.kind = .move
                if selection.contains(id) { g.reduceTo = grp } else { selection = grp }
                g.scope = selection
            }
        case (.selection, .gap(let track, let t)):
            if !m.contains(.shift) { selection = []; captionSelection = [] }
            if let r = timeline.gap(on: track, at: t) { gapSelection = GapSelection(track: track, range: r); selection = [] }
            g.kind = .marquee
            g.baseSelection = selection; g.baseCaptions = captionSelection
        case (.selection, .none):
            if !m.contains(.shift) { selection = []; captionSelection = [] }
            g.kind = .marquee
            g.baseSelection = selection; g.baseCaptions = captionSelection
        case (.trackSelectForward, .clip(let id, _)):
            selectForward(from: timeline.tracks.first { $0.clips.contains { $0.id == id } }?.id,
                          pivot: (toolState.selectBackward ? clip(id)?.timeline.end : clip(id)?.start) ?? .zero, allTracks: !m.contains(.shift), linked: linked(m))
        case (.trackSelectForward, .gap(let track, let t)):
            selectForward(from: track, pivot: t, allTracks: !m.contains(.shift), linked: linked(m))
        case (.rippleEdit, .clip(let id, let zone)), (.rollEdit, .clip(let id, let zone)):
            g.clip = id
            g.kind = tool == .rippleEdit ? .rippleTrim : .roll
            g.edge = nearestEdge(of: id, zone: zone, x: p.x)
            g.scope = toolScope(id, m)
        case (.rateStretch, .clip(let id, let zone)):
            g.clip = id
            g.kind = .rateStretch
            g.edge = nearestEdge(of: id, zone: zone, x: p.x)
            if !selection.contains(id) { selection = selectionGroup(id, linked: linked(m)) }
            g.scope = selection
        case (.slip, .clip(let id, _)):
            g.kind = .slip; g.clip = id; g.scope = toolScope(id, m)
        case (.slide, .clip(let id, _)):
            g.kind = .slide; g.clip = id; g.scope = toolScope(id, m)
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
        case .click: break
        case .razor:
            // The Blade cut at the click already; dragging moves nothing. Say so at the cursor.
            moveHint = Self.razorDragHint
        case .hand:
            geometry.scrollX = max(0, g.scrollOrigin.x - (p.x - g.downPoint.x))
            geometry.scrollY = max(0, g.scrollOrigin.y - (p.y - g.downPoint.y))
        case .marquee: updateMarquee(to: p, modifiers: m)
        case .move: updateMove(p, modifiers: m)
        case .captionMove: updateCaptionMove(p)
        case .captionTrim: updateCaptionTrim(p)
        case .wordRetime: updateWordRetime(p, alone: m.contains(.option))
        case .trim, .rippleTrim: updateTrim(p)
        case .rateStretch: updateRateStretch(p)
        case .roll: updateRoll(p)
        case .splitRoll: updateSplitRoll(p)
        case .slip: updateSlip(p)
        case .slide: updateSlide(p)
        }
    }

    /// Finishes the gesture. Returns the commit when the gesture changed the timeline.
    @discardableResult
    public mutating func mouseUp(_ p: CGPoint, modifiers m: GestureModifiers) -> TimelineCommit? {
        releasedRejection = nil
        guard let g = gesture else { return nil }
        if g.active && g.kind != .razor { mouseDragged(p, modifiers: m) }
        releasedRejection = isRejected ? rejectionMessage : nil
        defer {
            snapInverted = false
            moveHint = nil
            reorderGhost = nil
            gesture = nil
            marquee = nil
            snapTime = nil
            splitRollGhost = nil
            pendingEdits = []
            pendingUndoName = nil
            isRejected = false
            preview = timeline
            pendingCopies = []
        }
        if !g.active, let r = g.reduceTo { selection = r }
        guard g.active, !isRejected, !pendingEdits.isEmpty, let name = pendingUndoName, preview != timeline else { return nil }
        if !pendingCopies.isEmpty { selection = pendingCopies.intersection(preview.tracks.flatMap(\.clips).map(\.id)) }
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
        if !selection.isEmpty {
            let ids = Array(selection)
            edits = TimelineEdit.scoped([ripple ? .rippleDelete(ids) : .lift(ids)], to: selection, in: timeline)
            if timeline.isFastCut { edits = TimelineEdit.fastCut(edits, in: timeline, keepAttached: toolState.keepAttached) }
        }
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
            clearEdgeAndGap()
            if !selection.contains(id) { selection = selectionGroup(id, linked: linked(m)) }
        case .gap(let track, let t):
            if let r = timeline.gap(on: track, at: t) {
                selection = []; captionSelection = []; edgeSelection = nil
                gapSelection = GapSelection(track: track, range: r)
            }
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
    /// because a new sequence is added. An empty or blank name uses "Combined NN". Nothing selected, or an
    /// SQCore error (locked track, collision...), returns nil and sets `isRejected` + `rejectionMessage`.
    /// The commit's `edits` are empty: a nest is not replayable as a timeline edit, undo with `project` snapshots.
    public mutating func nest(name: String, in project: Project) -> NestResult? {
        guard gesture == nil else { return nil }
        rejectionMessage = nil
        isRejected = false
        guard !selection.isEmpty else { return reject("Select clips to combine.") }
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
        let commit = TimelineCommit(timeline: out, edits: [], undoName: "Combine", selection: newClips)
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
        case .nestingCycle: EditorSession.nestingCycleMessage
        case .clipNotFound, .timelineNotFound: "The selected clips no longer exist."
        case .emptyClip: "Nothing to combine."
        case .wrongTrackKind: "Clips do not fit that track."
        case .invalidFormat: "That sequence format is not valid."
        case .speedUnsupported: "Speed cannot be changed on that clip."
        case .notACut, .insufficientMedia: "That transition cannot be applied here."
        case .notAGroup, .notNested, .ungroupLosesLook, .notConvertible, .noTrackToDelete: "Combine failed."
        case nil: "Combine failed."
        }
    }

    // MARK: Selection tools

    private mutating func selectForward(from track: Track.ID?, pivot: Time, allTracks: Bool, linked: Bool) {
        var ids = Set<Clip.ID>()
        let backward = toolState.selectBackward
        for t in timeline.tracks where allTracks || t.id == track {
            for c in t.clips where backward ? c.start < pivot : c.timeline.end > pivot { ids.insert(c.id) }
        }
        selection = linked ? groups(ids, linked: true) : ids
    }

    private mutating func updateMarquee(to p: CGPoint, modifiers m: GestureModifiers) {
        guard let g = gesture else { return }
        let rect = CGRect(x: min(g.downPoint.x, p.x), y: min(g.downPoint.y, p.y),
                          width: abs(p.x - g.downPoint.x), height: abs(p.y - g.downPoint.y))
        marquee = rect
        gapSelection = nil
        var hits = Set<Clip.ID>()
        for row in geometry.rows(for: timeline) {
            guard let t = timeline.track(row.track), !t.isLocked else { continue }   // locked clips are not swept up
            for c in t.clips {
                let (x0, x1) = clipX(c)
                if rect.intersects(CGRect(x: x0, y: row.y, width: max(x1 - x0, 0.001), height: row.height)) { hits.insert(c.id) }
            }
        }
        selection = g.baseSelection.union(linked(m) ? selectionGroups(hits, linked: true) : hits)
        // Captions inside the rectangle are picked up too (hidden caption tracks are not drawn, so not swept up).
        var captionHits = Set<CaptionItem.ID>()
        for row in geometry.captionRows(for: timeline) {
            guard let t = timeline.captionTrack(row.track), t.isVisible else { continue }
            for item in t.items {
                let x0 = geometry.x(for: item.range.start), x1 = geometry.x(for: item.range.end)
                if rect.intersects(CGRect(x: x0, y: row.y, width: max(x1 - x0, 0.001), height: row.height)) { captionHits.insert(item.id) }
            }
        }
        captionSelection = g.baseCaptions.union(captionHits)
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
        var edits = TimelineEdit.scoped(edits, to: gesture?.scope, in: timeline)
        // Fast Cut: the gesture runs the Fast Cut verbs, so the preview (and drop ghost) shows where things really land.
        if timeline.isFastCut {
            edits = TimelineEdit.fastCut(edits, in: timeline, keepAttached: toolState.keepAttached,
                                         position: toolState.timelineTool == .position && gesture?.kind == .move)
        }
        pendingEdits = edits
        pendingUndoName = name
        isRejected = false
        rejectionMessage = nil
        guard !edits.isEmpty else { preview = timeline; return }
        do { preview = try TimelineEdit.apply(edits, to: timeline) } catch {
            preview = timeline
            pendingEdits = []
            isRejected = true
            rejectionMessage = Self.message(for: error)
        }
    }

    /// Frame-snapped pointer travel since mouse down.
    private func travel(_ p: CGPoint, _ g: Gesture) -> Time { geometry.time(atX: p.x) - g.downTime }

    // MARK: Move

    /// Extra points the pointer may leave the previous target row before the target changes (no flicker at row edges).
    public static let rowHysteresis: CGFloat = 6

    /// Row the pointer drags `kind` onto. Above the first row adds a video track, below the last an audio track.
    /// `sticky` (the row chosen last) is kept while the pointer stays within `rowHysteresis` of it.
    /// `onVideoGhost`: the pointer is on the "V+" ghost strip under the last track; a video clip dropped there gets a new top track.
    private func dropRow(kind: TrackKind, y: CGFloat, rows: [TrackRow], sticky: Int? = nil, onVideoGhost: Bool = false) -> (index: Int, isNew: Bool) {
        if kind == .video, onVideoGhost { return (-1, true) }
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
        // Adobe: Cmd-drag = insert (the old place stays a gap), Cmd+Opt-drag = rearrange (the old place closes), Option-drag
        // = copy; Option first and then Cmd = insert the copy.
        if m.contains(.option) && !m.contains(.command) { g.copyLatched = true }
        gesture = g
        let insert = m.contains(.command)
        let copying = m.contains(.option) && !insert
        let insertCopying = m.contains(.option) && insert && g.copyLatched
        let rearranging = m.contains(.option) && insert && !g.copyLatched
        moveHint = insertCopying ? "Insert copy" : rearranging ? "Rearrange" : insert ? "Insert" : copying ? "Copy" : nil
        reorderGhost = nil
        let movers: [Clip.ID] = (!insert && selection.contains(anchorID)) ? Array(selection) : [anchorID]
        let scope = g.scope
        let everything = movers.reduce(into: Set<Clip.ID>()) { $0.formUnion(group($1, within: scope)) }
        let minStart = everything.compactMap { clip($0)?.start }.min() ?? anchor.start

        // Shift locks the move to the axis the pointer left along first: time or track.
        if m.contains(.shift) { g.axisLock.update(dx: p.x - g.downPoint.x, dy: p.y - g.downPoint.y) } else { g.axisLock.reset() }
        let lock = g.axisLock.axis
        var d = lock == .vertical ? .zero : travel(p, g)
        snapTime = nil
        if snappingOn, lock != .vertical {
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
        let dropY = lock == .horizontal && rows.indices.contains(anchorRow) ? rows[anchorRow].y + rows[anchorRow].height / 2 : p.y
        let onVideoGhost = lock != .horizontal && geometry.ghostKind(at: p, in: timeline) == .video
        let drop = dropRow(kind: anchor.kind, y: dropY, rows: rows, sticky: g.stickyRow, onVideoGhost: onVideoGhost)
        if !drop.isNew { g.stickyRow = drop.index }
        gesture = g
        if timeline.isFastCut, !copying, !insertCopying {
            // Fast Cut cursor hint: what the drop will do (TimelineEdit.fastCut).
            let onMain = !drop.isNew && rows.indices.contains(drop.index) && rows[drop.index].track == timeline.mainTrackID
            let keep = toolState.keepAttached ? " (attached stay)" : ""
            if timeline.mainClip(of: anchorID) != nil {
                moveHint = (onMain || anchor.kind == .audio ? "Rearrange" : "Lift off main track") + keep
                if onMain, !insert, d != .zero, let main = timeline.mainTrackID {
                    reorderGhost = ReorderGhost(track: main, range: TimeRange(start: anchor.start + d, duration: anchor.timeline.duration),
                                                name: anchor.name)
                }
            } else {
                moveHint = onMain ? "Insert on main track" : nil
            }
            if toolState.timelineTool == .position, !insert {     // Position tool: overwrites and leaves a hole
                moveHint = "Position"
                reorderGhost = nil
            }
        }

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
            if insertCopying {
                // Cmd+Option: insert a copy at the drop point, the original stays.
                let grp = group(anchorID, within: scope)
                for member in grp where g.copyIDs[member] == nil { g.copyIDs[member] = UUID() }
                var link = UUID()
                if let l = anchor.link { link = g.copyLinks[l] ?? link; g.copyLinks[l] = link }
                let spec = CopySpec(ids: g.copyIDs.filter { grp.contains($0.key) }, link: link)
                gesture = g
                pendingCopies = Set(g.copyIDs.filter { grp.contains($0.key) }.values)
                edits.append(.insertCopy(anchorID, to: anchor.start + d, track: anchorTrack, spec: spec))
                publish(edits, "Insert Copy")
                return
            }
            pendingCopies = []
            if d != .zero || anchorTrack != nil {
                edits.append(rearranging ? .moveInsert(anchorID, to: anchor.start + d, track: anchorTrack)
                                         : .insertMove(anchorID, to: anchor.start + d, track: anchorTrack))
            } else { edits = [] }
            publish(edits, rearranging ? "Rearrange" : "Insert Move")
            return
        }

        // Track lanes per kind, bottom-up (index 0 = V1 / A1). A track change of k lanes applies to every moved clip of
        // either kind: video up k = audio down k, because both indices grow away from the center (Premiere mirrors).
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
            let grp = group(c.id, within: scope)
            done.formUnion(grp)
            groupCount += 1
            let own = dest(of: c.id)
            var partners: [Clip.ID: Track.ID] = [:]
            for other in grp where other != c.id { if let t = dest(of: other) { partners[other] = t } }
            guard d != .zero || own != nil || !partners.isEmpty else { continue }
            if copying {
                // Option-drag: originals stay, copies land at the drop position (Premiere).
                for member in grp where g.copyIDs[member] == nil { g.copyIDs[member] = UUID() }
                var link = UUID()
                if let l = c.link { link = g.copyLinks[l] ?? link; g.copyLinks[l] = link }
                let spec = CopySpec(ids: g.copyIDs.filter { grp.contains($0.key) }, link: link)
                moves.append(.copyGroup(c.id, to: c.start + d, track: own, partners: partners, spec: spec))
                continue
            }
            moves.append(partners.isEmpty ? .move(c.id, to: c.start + d, track: own)
                                          : .moveGroup(c.id, to: c.start + d, track: own, partners: partners))
        }
        gesture = g
        pendingCopies = copying && !moves.isEmpty ? Set(g.copyIDs.values) : []
        var edits: [TimelineEdit] = []
        for kind in [TrackKind.video, .audio] {
            if let top = usedNew[kind] { edits += (g.newTracks[kind] ?? []).prefix(top + 1).map { .addTrack($0) } }
        }
        publish(moves.isEmpty ? [] : edits + moves,
                copying ? (groupCount > 1 ? "Copy Clips" : "Copy Clip") : (groupCount > 1 ? "Move Clips" : "Move Clip"))
    }

    // MARK: Captions

    private mutating func updateCaptionMove(_ p: CGPoint) {
        guard let g = gesture, let id = g.caption, let item = captionItem(id) else { return }
        var d = travel(p, g)
        snapTime = nil
        if snappingOn {
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

    /// A word edge follows the pointer, snapping like a clip edge. It stops at the neighboring word and at the caption's
    /// own edges (one frame stays); two words that touch there move their shared edge together unless Option is held.
    private mutating func updateWordRetime(_ p: CGPoint, alone: Bool) {
        guard let g = gesture, let id = g.caption, let item = captionItem(id) else { return }
        let words = item.effectiveWords
        guard words.indices.contains(g.word) else { return }
        let edgeTime = g.edge == .head ? words[g.word].range.start : words[g.word].range.end
        let d = snappedDelta(travel(p, g), from: edgeTime, excluding: [])
        publish(d == .zero ? [] : [.retimeCaptionWord(id, index: g.word, edge: g.edge, to: edgeTime + d, rolling: !alone)], "Retime Word")
    }

    // MARK: Trim / ripple / roll / slip / slide

    private mutating func updateTrim(_ p: CGPoint) {
        guard let g = gesture, let id = g.clip, let c = clip(id) else { return }
        let edgeTime = g.edge == .head ? c.start : c.timeline.end
        let d = snappedDelta(travel(p, g), from: edgeTime, excluding: group(id, linked: true))
        let ripple = g.kind == .rippleTrim
        let edit: TimelineEdit = ripple ? .rippleTrim(id, edge: g.edge, by: d) : .trim(id, edge: g.edge, by: d)
        // Several selected edges move together, like the keyboard trims.
        if let sel = edgeSelection, sel.edges.count > 1 {
            publish(EdgeEdits.trim(sel, by: d, in: timeline), ripple ? "Ripple Trim" : "Trim Clip")
            return
        }
        publish(d == .zero ? [] : [edit], ripple ? "Ripple Trim" : "Trim Clip")
    }

    /// Rate Stretch: the dragged edge snaps like a trim; the clip's speed follows the new length.
    private mutating func updateRateStretch(_ p: CGPoint) {
        guard let g = gesture, let id = g.clip, let c = clip(id) else { return }
        let edgeTime = g.edge == .head ? c.start : c.timeline.end
        let d = snappedDelta(travel(p, g), from: edgeTime, excluding: group(id, linked: true))
        publish(d == .zero ? [] : [.rateStretch(id, edge: g.edge, by: d)], "Stretch")
    }

    private mutating func updateRoll(_ p: CGPoint) {
        guard let g = gesture, let id = g.clip, let c = clip(id), let track = timeline.track(trackID(of: id) ?? UUID()) else { return }
        let left: Clip?
        if g.edge == .tail { left = c } else { left = track.clips.first { $0.timeline.end == c.start } }
        guard let left else { publish([], "Move Edit"); return }
        // A roll edits both clips of the cut: the other one joins the scope the same way the clicked clip is in it
        // (alone, or with its partners), so an unlinked roll leaves the partner cut where it is.
        if var scope = g.scope {
            let right = track.clips.first { $0.start == left.timeline.end }
            let withPartners = group(id, linked: true).isSubset(of: scope)
            for other in [left.id, right?.id].compactMap({ $0 }) where !scope.contains(other) {
                if withPartners { scope.formUnion(group(other, linked: true)) } else { scope.insert(other) }
            }
            gesture?.scope = scope
        }
        let d = snappedDelta(travel(p, g), from: left.timeline.end, excluding: group(left.id, linked: true))
        if let sel = edgeSelection, sel.edges.count > 2 {
            publish(EdgeEdits.trim(sel, by: d, in: timeline), "Move Edit")
            return
        }
        publish(d == .zero ? [] : [.roll(left.id, by: d)], "Move Edit")
    }

    /// Opt-drag on a cut: the audio edit follows the pointer (snapped, clamped by handles), the picture stays.
    private mutating func updateSplitRoll(_ p: CGPoint) {
        guard let g = gesture else { return }
        let d = snappedDelta(travel(p, g), from: g.cut, excluding: [])
        guard d != .zero else { splitRollGhost = SplitRollGhost(cut: g.cut, offset: .zero); publish([], "Split Edit Audio"); return }
        var probe = timeline
        let applied = (try? probe.splitEdit(cut: g.cut, side: .audio, to: g.cut + d)) ?? .zero
        splitRollGhost = SplitRollGhost(cut: g.cut, offset: applied)
        publish([.splitEditAudio(cut: g.cut, to: g.cut + d)], "Split Edit Audio")
    }

    private mutating func updateSlip(_ p: CGPoint) {
        guard let g = gesture, let id = g.clip else { return }
        // The media follows the pointer: dragging right shows earlier material.
        let d = Time.zero - travel(p, g)
        let stay = toolState.slipKeyframesStay
        moveHint = d == .zero ? nil : "Slip \(Self.frameText(d, geometry.frameDuration))" + (stay ? " (keyframes stay)" : "")
        publish(d == .zero ? [] : [.slip(id, by: d, keyframes: stay ? .stay : .followContent)],
                stay ? "Slip Clip (Keyframes Stay)" : "Slip Clip")
    }

    private mutating func updateSlide(_ p: CGPoint) {
        guard let g = gesture, let id = g.clip, let c = clip(id) else { return }
        var d = travel(p, g)
        snapTime = nil
        if snappingOn {
            let r = snapMove(start: c.start + d, duration: c.timeline.duration,
                             to: snapPoints(excluding: group(id, linked: true)), threshold: geometry.snapThreshold(),
                             frameDuration: geometry.frameDuration)
            d += r.delta
            snapTime = r.hit?.time
        }
        moveHint = d == .zero ? nil : "Slide \(Self.frameText(d, geometry.frameDuration))"
        publish(d == .zero ? [] : [.slide(id, by: d)], "Slide Clip")
    }

    /// Signed whole frames for the drag readout of Slip and Slide: "+12 f", "-3 f".
    static func frameText(_ d: Time, _ frame: Time) -> String {
        let n = Int((Double(d.value) * Double(frame.timescale) / (Double(d.timescale) * Double(frame.value))).rounded())
        return (n > 0 ? "+" : "") + "\(n) f"
    }

    /// `delta` of an edge at `edgeTime`, pulled onto a snap point when snapping is on.
    private mutating func snappedDelta(_ delta: Time, from edgeTime: Time, excluding: Set<Clip.ID>) -> Time {
        snapTime = nil
        guard snappingOn else { return delta }
        let r = snap(edgeTime + delta, to: snapPoints(excluding: excluding), threshold: geometry.snapThreshold(),
                     frameDuration: geometry.frameDuration)
        snapTime = r.hit?.time
        return r.time - edgeTime
    }

    // MARK: Razor

    /// Where a razor click at view x would cut (frame-snapped, edge-snapped when snapping is on). The hover guide
    /// draws its line here, so the line is exactly the cut.
    public func razorCutTime(atX x: CGFloat) -> Time {
        let t = geometry.time(atX: x)
        guard snappingOn else { return t }
        let pts = cachedSnapPoints(excluding: [])
            ?? timeline.snapPoints(playhead: playhead, markers: markers, includeKeyframes: true)
        return snap(t, to: pts, threshold: geometry.snapThreshold(), frameDuration: geometry.frameDuration).time
    }

    /// Delete / Shift+Delete has something to act on: clips, captions or a selected gap (which it ripple-closes).
    public var hasDeleteTarget: Bool { !selection.isEmpty || !captionSelection.isEmpty || gapSelection != nil }

    /// Tracks a razor click on `id` cuts: its own track first, then its linked partners' tracks.
    private func razorTracks(clip id: Clip.ID, linked: Bool) -> [Track.ID]? {
        guard let own = trackID(of: id) else { return nil }
        let set = Set(group(id, linked: linked).compactMap(trackID(of:)) + [own])
        return [own] + timeline.tracks.map(\.id).filter { set.contains($0) && $0 != own }
    }

    /// Tracks the razor hover guide spans at view point `p`: with Shift every track, otherwise only the tracks of the
    /// clip under the pointer (and its linked partners). Empty over an empty lane, so no line is drawn there.
    public func razorGuideTracks(at p: CGPoint, shift: Bool, option: Bool = false) -> [Track.ID] {
        if shift { return timeline.tracks.map(\.id) }
        guard case .clip(let id, _) = geometry.hitTest(p, in: timeline) else { return [] }
        return razorTracks(clip: id, linked: toolState.linkedSelection != option) ?? []
    }

    private mutating func razorPreview(at p: CGPoint, clip id: Clip.ID?, modifiers m: GestureModifiers) {
        var t = geometry.time(atX: p.x)
        snapTime = nil
        if snappingOn {
            let r = snap(t, to: snapPoints(excluding: []), threshold: geometry.snapThreshold(),
                         frameDuration: geometry.frameDuration)
            t = r.time
            snapTime = r.hit?.time
        }
        var tracks: [Track.ID]?
        if !m.contains(.shift), let id { tracks = razorTracks(clip: id, linked: linked(m)) }
        publish([.addEdit(at: t, tracks: tracks)], m.contains(.shift) ? "Blade All Tracks" : "Blade")
    }
}
