import AppKit
import SSCore

/// Timeline container (T-02: draw, scroll and zoom only; editing interactions are T-04/T-05).
/// Layer-backed, flipped, draws only the dirty rect. Children: `RulerView` on top, one `TrackHeaderView` per track.
/// Clips, lanes, playhead line and the tool column are drawn here.
///
/// Model input: `setTimeline(_:)`, `setSelection(_:)`, `setPlayhead(_:)`, `setOfflineMedia(_:)`.
@MainActor
public final class TimelineView: NSView {
    public private(set) var timeline: Timeline
    public private(set) var selection: Set<Clip.ID> = []
    public private(set) var captionSelection: Set<CaptionItem.ID> = []
    public private(set) var playhead: Time = .zero
    public private(set) var offlineMedia: Set<UUID> = []
    public private(set) var geometry: TimelineGeometry

    /// Type colour per clip; default by track kind. Nest / title / caption hook in here later.
    public var clipStyle: (Clip) -> ClipStyle = { ClipStyle(kind: $0.kind) }
    /// Header control clicks (callbacks only in T-02).
    public var onTrackToggle: ((Track.ID, TrackToggle) -> Void)?
    /// Double-click on a caption item: the host opens its text editor.
    public var onEditCaptionText: ((CaptionItem.ID) -> Void)?
    /// Builds the right-click menu for a point in view coordinates (see `TimelineContextMenu`). Nil = no menu.
    public var contextMenuProvider: ((CGPoint) -> NSMenu?)?
    /// Fired after scroll or zoom changed, so a host can sync scrollers and a zoom slider.
    public var onViewportChange: (() -> Void)?

    /// Gesture reducer behind the mouse handlers (tools, selection, snapping). The view feeds it view coordinates.
    public private(set) var interaction: TimelineInteraction
    /// A finished gesture: ONE undo step for the host (`EditorSession.commit`).
    public var onCommit: ((TimelineCommit) -> Void)?
    /// The selection changed by a click or marquee.
    public var onSelectionChange: ((Set<Clip.ID>, Set<CaptionItem.ID>) -> Void)?
    /// Ruler click: show this time. Dragging in the ruler calls begin/scrub/end.
    public var onSeek: ((Time) -> Void)?
    public var onScrubBegan: (() -> Void)?
    public var onScrub: ((Time) -> Void)?
    public var onScrubEnded: (() -> Void)?
    /// Called when a click lands in the view, so the host can move keyboard focus to this panel.
    public var onFocusRequest: (() -> Void)?
    /// A gesture was refused by SSCore (locked track, collision): message for the status bar.
    public var onRejection: ((String) -> Void)?
    /// Media dragged in from the Project panel: ids, drop time, track under the pointer (nil = default track),
    /// insert instead of overwrite (Command held at the drop).
    public var onDropMedia: (([MediaRef.ID], Time, Track.ID?, Bool) -> Void)?
    private var scrubbing: (began: Bool, active: Bool) = (false, false)
    /// Active tool, snapping and linked selection.
    public var toolState: ToolState {
        get { interaction.toolState }
        set { interaction.toolState = newValue }
    }

    public static let minPointsPerSecond: Double = 0.02
    public static let maxPointsPerFrame: Double = 400
    public static let zoomStep: Double = 1.5

    private let ruler: RulerView
    private var headers: [Track.ID: TrackHeaderView] = [:]

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public init(timeline: Timeline = Timeline(name: "", frameDuration: Time(1, 24)), frame: NSRect = NSRect(x: 0, y: 0, width: 1000, height: 200)) {
        self.timeline = timeline
        let fd = timeline.frameDuration
        self.geometry = TimelineGeometry(frameDuration: fd, pointsPerSecond: 40)
        self.interaction = TimelineInteraction(timeline: timeline, geometry: geometry)
        self.ruler = RulerView(geometry: geometry)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.sequenceMediaIDs])
        addSubview(ruler)
        layoutChildren()
        rebuildHeaders()
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Model input

    public func setTimeline(_ t: Timeline) {
        timeline = t
        geometry.frameDuration = t.frameDuration
        selection.formIntersection(Set(t.tracks.flatMap { $0.clips.map(\.id) }))
        captionSelection.formIntersection(Set(t.captionTracks.flatMap { $0.items.map(\.id) }))
        interaction.reset(timeline: t)
        interaction.setSelection(selection)
        interaction.setCaptionSelection(captionSelection)
        clampScroll()
        rebuildHeaders()
        syncChildren()
        needsDisplay = true
    }

    public func setSelection(_ ids: Set<Clip.ID>) {
        guard ids != selection else { return }
        selection = ids
        interaction.setSelection(ids)
        needsDisplay = true
    }

    public func setCaptionSelection(_ ids: Set<CaptionItem.ID>) {
        guard ids != captionSelection else { return }
        captionSelection = ids
        interaction.setCaptionSelection(ids)
        needsDisplay = true
    }

    public func setOfflineMedia(_ ids: Set<UUID>) {
        guard ids != offlineMedia else { return }
        offlineMedia = ids
        needsDisplay = true
    }

    public func setPlayhead(_ t: Time) {
        guard t != playhead else { return }
        let old = geometry.x(for: playhead)
        playhead = t
        let new = geometry.x(for: t)
        ruler.movePlayhead(to: t)
        for x in [old, new] {
            setNeedsDisplay(CGRect(x: x - 1, y: TimelineGeometry.rulerHeight, width: 2, height: bounds.height))
        }
    }

    // MARK: Viewport (scroll + zoom)

    /// Visible time span of the content area.
    public var visibleRange: TimeRange {
        let a = max(geometry.time(atX: TimelineGeometry.contentOriginX), .zero)
        let b = max(geometry.time(atX: bounds.width), a)
        return TimeRange(start: a, end: b)
    }

    /// End of the last clip (zero for an empty timeline).
    public var contentEnd: Time {
        let clips = timeline.tracks.compactMap { $0.clips.last?.timeline.end }
        let captions = timeline.captionTracks.compactMap { $0.items.last?.range.end }
        return (clips + captions).max() ?? .zero
    }

    private var contentViewportWidth: CGFloat { max(bounds.width - TimelineGeometry.contentOriginX, 1) }

    private func maxScrollX() -> CGFloat {
        // Sequence end plus one viewport of room, so the tail can be scrolled to the left edge.
        max(geometry.width(of: contentEnd) + contentViewportWidth * 0.5 - contentViewportWidth * 0.0, 0)
    }

    private func maxScrollY() -> CGFloat { max(geometry.contentHeight(for: timeline) - bounds.height, 0) }

    private func clampScroll() {
        geometry.scrollX = min(max(geometry.scrollX, 0), maxScrollX())
        geometry.scrollY = min(max(geometry.scrollY, 0), maxScrollY())
    }

    public func scroll(toX x: CGFloat) { setScroll(x: x, y: geometry.scrollY) }
    public func scroll(toY y: CGFloat) { setScroll(x: geometry.scrollX, y: y) }

    public func scroll(byX dx: CGFloat, y dy: CGFloat) { setScroll(x: geometry.scrollX + dx, y: geometry.scrollY + dy) }

    private func setScroll(x: CGFloat, y: CGFloat) {
        let old = (geometry.scrollX, geometry.scrollY)
        geometry.scrollX = x; geometry.scrollY = y
        clampScroll()
        guard (geometry.scrollX, geometry.scrollY) != old else { return }
        viewportChanged()
    }

    /// Sets zoom, keeping the time under `anchorX` (view coordinates) fixed.
    public func setZoom(pointsPerSecond: Double, anchorX: CGFloat? = nil) {
        let fdSec = Double(geometry.frameDuration.value) / Double(geometry.frameDuration.timescale)
        let maxPPS = Self.maxPointsPerFrame / fdSec
        let pps = min(max(pointsPerSecond, Self.minPointsPerSecond), maxPPS)
        guard pps != geometry.pointsPerSecond else { return }
        let anchor = anchorX ?? defaultZoomAnchor()
        let relX = Double(anchor - TimelineGeometry.contentOriginX)
        let seconds = (relX + Double(geometry.scrollX)) / geometry.pointsPerSecond
        geometry.pointsPerSecond = pps
        geometry.scrollX = CGFloat(seconds * pps - relX)
        clampScroll()
        viewportChanged()
    }

    private func defaultZoomAnchor() -> CGFloat {
        let x = geometry.x(for: playhead)
        return x >= TimelineGeometry.contentOriginX && x <= bounds.width
            ? x : TimelineGeometry.contentOriginX + contentViewportWidth / 2
    }

    public func zoomIn(anchorX: CGFloat? = nil) { setZoom(pointsPerSecond: geometry.pointsPerSecond * Self.zoomStep, anchorX: anchorX) }
    public func zoomOut(anchorX: CGFloat? = nil) { setZoom(pointsPerSecond: geometry.pointsPerSecond / Self.zoomStep, anchorX: anchorX) }

    /// `\`: fit the whole sequence (clips, or In/Out when set) into the content area.
    public func zoomToFit() {
        let span = timeline.inOut.flatMap { $0.isEmpty ? nil : $0 } ?? TimeRange(start: .zero, duration: contentEnd)
        guard !span.isEmpty else { return }
        let seconds = Double(span.duration.value) / Double(span.duration.timescale)
        let startSeconds = Double(span.start.value) / Double(span.start.timescale)
        let usable = Double(contentViewportWidth) - 2 * Double(Theme.Spacing.lg)
        geometry.scrollX = 0
        setZoom(pointsPerSecond: max(usable, 1) / seconds, anchorX: TimelineGeometry.contentOriginX)
        geometry.scrollX = CGFloat(startSeconds * geometry.pointsPerSecond) - Theme.Spacing.lg
        clampScroll()
        viewportChanged()
    }

    private func viewportChanged() {
        syncChildren()
        needsDisplay = true
        onViewportChange?()
    }

    // MARK: Events

    public override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let anchor = convert(event.locationInWindow, from: nil).x
            setZoom(pointsPerSecond: geometry.pointsPerSecond * exp(Double(dy) * 0.01), anchorX: anchor)
            return
        }
        let horizontalOnly = event.modifierFlags.contains(.shift) || maxScrollY() == 0
        if horizontalOnly {
            scroll(byX: -(abs(dx) > abs(dy) ? dx : dy), y: 0)
        } else {
            scroll(byX: -dx, y: -dy)
        }
    }

    public override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil).x
        setZoom(pointsPerSecond: geometry.pointsPerSecond * (1 + Double(event.magnification)), anchorX: anchor)
    }

    private func gestureModifiers(_ e: NSEvent) -> GestureModifiers {
        var m: GestureModifiers = []
        if e.modifierFlags.contains(.shift) { m.insert(.shift) }
        if e.modifierFlags.contains(.command) { m.insert(.command) }
        if e.modifierFlags.contains(.option) { m.insert(.option) }
        if e.modifierFlags.contains(.control) { m.insert(.control) }
        return m
    }

    private func feedInteraction() {
        interaction.geometry = geometry
        interaction.playhead = playhead
        interaction.markers = timeline.markers.map(\.time)
    }

    /// Shows the in-flight gesture (`interaction.preview`) and mirrors selection and scroll changes into the view.
    private func refreshFromInteraction() {
        if interaction.geometry.scrollX != geometry.scrollX || interaction.geometry.scrollY != geometry.scrollY {
            setScroll(x: interaction.geometry.scrollX, y: interaction.geometry.scrollY)
        }
        let preview = interaction.preview
        if preview != timeline {
            timeline = preview
            rebuildHeaders()
            syncChildren()
        }
        if interaction.selection != selection || interaction.captionSelection != captionSelection {
            selection = interaction.selection
            captionSelection = interaction.captionSelection
            onSelectionChange?(selection, captionSelection)
        }
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocusRequest?()
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, case .caption(let id, _) = geometry.hitTest(p, in: timeline) {
            onEditCaptionText?(id)
            return
        }
        if geometry.hitTest(p, in: timeline) == .ruler {
            scrubbing = (false, true)
            onSeek?(geometry.time(atX: p.x))
            return
        }
        feedInteraction()
        interaction.mouseDown(p, modifiers: gestureModifiers(event))
        refreshFromInteraction()
    }

    public override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if scrubbing.active {
            if !scrubbing.began { scrubbing.began = true; onScrubBegan?() }
            onScrub?(geometry.time(atX: p.x))
            return
        }
        interaction.geometry = geometry
        interaction.mouseDragged(p, modifiers: gestureModifiers(event))
        refreshFromInteraction()
    }

    public override func mouseUp(with event: NSEvent) {
        if scrubbing.active {
            if scrubbing.began { onScrubEnded?() }
            scrubbing = (false, false)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        interaction.geometry = geometry
        let wasRejected = interaction.isRejected
        let commit = interaction.mouseUp(p, modifiers: gestureModifiers(event))
        refreshFromInteraction()
        if wasRejected, let m = interaction.rejectionMessage { onRejection?(m) }
        if let commit { onCommit?(commit) }
    }

    /// Right-click: selects the item under the pointer (see `TimelineInteraction.contextSelect`) before the menu opens.
    public func contextSelect(at p: CGPoint) {
        feedInteraction()
        interaction.contextSelect(at: p)
        refreshFromInteraction()
    }

    /// Escape during a drag.
    public func cancelGesture() {
        interaction.cancel()
        refreshFromInteraction()
    }

    // MARK: Drop from the Project panel

    private func droppedMedia(_ info: NSDraggingInfo) -> [MediaRef.ID] {
        guard let s = info.draggingPasteboard.string(forType: .sequenceMediaIDs) else { return [] }
        return ProjectPanelModel.decodeItems(s).compactMap { if case .media(let id) = $0 { id } else { nil } }
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedMedia(sender).isEmpty ? [] : .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedMedia(sender).isEmpty ? [] : .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let ids = droppedMedia(sender)
        guard !ids.isEmpty else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let time = max(geometry.time(atX: max(p.x, TimelineGeometry.contentOriginX)), .zero)
        var track: Track.ID?
        switch geometry.hitTest(p, in: timeline) {
        case .clip(let id, _): track = timeline.tracks.first { $0.clips.contains { $0.id == id } }?.id
        case .gap(let t, _): track = t
        case .header(let t): track = t
        default: break
        }
        onDropMedia?(ids, time, track, NSEvent.modifierFlags.contains(.command))
        return true
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(convert(event.locationInWindow, from: nil))
    }

    public override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomIn()
        case "-": zoomOut()
        case "\\": zoomToFit()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Layout

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampScroll()
        layoutChildren()
        syncChildren()
    }

    private func layoutChildren() {
        ruler.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TimelineGeometry.rulerHeight)
    }

    private func rebuildHeaders() {
        let ids = Set(timeline.tracks.map(\.id))
        for (id, view) in headers where !ids.contains(id) { view.removeFromSuperview(); headers[id] = nil }
        for t in timeline.tracks where headers[t.id] == nil {
            let v = TrackHeaderView(track: t, label: "")
            v.onToggle = { [weak self] id, toggle in self?.onTrackToggle?(id, toggle) }
            headers[t.id] = v
            addSubview(v, positioned: .below, relativeTo: ruler)   // the ruler stays above scrolled-up headers
        }
    }

    /// Pushes model and viewport into the ruler and header rows.
    private func syncChildren() {
        ruler.update(geometry: geometry, inOut: timeline.inOut, markers: timeline.markers, playhead: playhead)
        let rows = geometry.rows(for: timeline)
        var seen = Set<Track.ID>()
        for row in rows {
            guard let header = headers[row.track], let track = timeline.track(row.track) else { continue }
            seen.insert(row.track)
            header.isHidden = false
            header.frame = CGRect(x: TimelineGeometry.toolColumnWidth, y: row.y,
                                  width: TimelineGeometry.headerWidth, height: row.height)
            header.apply(track: track, label: row.label)
        }
        for (id, h) in headers where !seen.contains(id) { h.isHidden = true }
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.timeline.setFill()
        dirtyRect.fill()

        let rows = geometry.rows(for: timeline)
        let contentClip = CGRect(x: TimelineGeometry.contentOriginX, y: TimelineGeometry.rulerHeight,
                                 width: max(bounds.width - TimelineGeometry.contentOriginX, 0),
                                 height: max(bounds.height - TimelineGeometry.rulerHeight, 0))
        let clip = dirtyRect.intersection(contentClip)
        if !clip.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            clip.clip()
            drawCaptionLanes(clip: clip)
            drawLanes(rows: rows, clip: clip)
            drawPlayheadLine(clip: clip)
            drawGestureOverlay(clip: clip)
            NSGraphicsContext.restoreGraphicsState()
        }
        drawToolColumn(dirty: dirtyRect)
        drawCaptionHeaders(dirty: dirtyRect)
    }

    private func drawCaptionLanes(clip: CGRect) {
        let visibleX = CGRect(x: clip.minX, y: 0, width: clip.width, height: bounds.height)
        for row in geometry.captionRows(for: timeline) {
            let laneRect = CGRect(x: clip.minX, y: row.y, width: clip.width, height: row.height)
            guard laneRect.intersects(clip), let track = timeline.captionTrack(row.track) else { continue }
            Theme.Colors.lane.setFill()
            laneRect.fill()
            Theme.Colors.separator.setFill()
            CGRect(x: clip.minX, y: row.maxY - 1, width: clip.width, height: 1).fill()
            for item in track.items {
                let x0 = geometry.x(for: item.range.start), x1 = geometry.x(for: item.range.end)
                if x1 < clip.minX { continue }
                if x0 > clip.maxX { break }
                ClipDrawing.draw(name: CaptionDrawing.preview(item), rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height),
                                 visible: visibleX, style: .caption, isSelected: captionSelection.contains(item.id),
                                 isOffline: false)
            }
        }
    }

    private func drawCaptionHeaders(dirty: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Fonts.small, .foregroundColor: Theme.Colors.label2]
        for row in geometry.captionRows(for: timeline) {
            let r = CGRect(x: TimelineGeometry.toolColumnWidth, y: row.y, width: TimelineGeometry.headerWidth, height: row.height)
            guard r.maxY > TimelineGeometry.rulerHeight, r.intersects(dirty) else { continue }
            Theme.Colors.titlebar.setFill()
            r.fill()
            Theme.Colors.separator.setFill()
            CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
            let name = timeline.captionTrack(row.track)?.name ?? ""
            NSAttributedString(string: name.isEmpty ? row.label : name, attributes: attrs)
                .draw(at: CGPoint(x: r.minX + 8, y: r.minY + (r.height - 13) / 2))
        }
    }

    private func drawLanes(rows: [TrackRow], clip: CGRect) {
        let visibleX = CGRect(x: clip.minX, y: 0, width: clip.width, height: bounds.height)
        for row in rows {
            let laneRect = CGRect(x: clip.minX, y: row.y, width: clip.width, height: row.height)
            guard laneRect.intersects(clip), let track = timeline.track(row.track) else { continue }
            Theme.Colors.lane.setFill()
            laneRect.fill()
            Theme.Colors.separator.setFill()
            CGRect(x: clip.minX, y: row.maxY - 1, width: clip.width, height: 1).fill()
            for c in track.clips {
                let x0 = geometry.x(for: c.timeline.start), x1 = geometry.x(for: c.timeline.end)
                if x1 < clip.minX { continue }
                if x0 > clip.maxX { break }   // clips are sorted by start
                ClipDrawing.draw(name: c.name, rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height),
                                 visible: visibleX, style: clipStyle(c), isSelected: selection.contains(c.id),
                                 isOffline: offlineMedia.contains(c.media))
            }
        }
    }

    private func drawPlayheadLine(clip: CGRect) {
        let x = geometry.x(for: playhead)
        guard x >= clip.minX - 1, x <= clip.maxX + 1 else { return }
        Theme.Colors.playhead.setFill()
        CGRect(x: x.rounded() - 0.5, y: clip.minY, width: 1, height: clip.height).fill()
    }

    /// Marquee rectangle and the snap line of the gesture in flight.
    private func drawGestureOverlay(clip: CGRect) {
        if let t = interaction.snapTime {
            let x = geometry.x(for: t).rounded()
            Theme.Colors.clipSelect.setFill()
            CGRect(x: x - 0.5, y: clip.minY, width: 1, height: clip.height).fill()
        }
        if let m = interaction.marquee {
            Theme.Colors.accentTint.setFill()
            m.fill()
            Theme.Colors.accent.setStroke()
            NSBezierPath(rect: m.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    /// Placeholder: the real tools arrive with T-04. Only the column surface and its edge.
    private func drawToolColumn(dirty: CGRect) {
        let col = CGRect(x: 0, y: TimelineGeometry.rulerHeight, width: TimelineGeometry.toolColumnWidth,
                         height: max(bounds.height - TimelineGeometry.rulerHeight, 0))
        let r = dirty.intersection(col)
        guard !r.isEmpty else { return }
        Theme.Colors.titlebar.setFill()
        r.fill()
        Theme.Colors.separator.setFill()
        CGRect(x: col.maxX - 1, y: col.minY, width: 1, height: col.height).intersection(dirty).fill()
    }
}
