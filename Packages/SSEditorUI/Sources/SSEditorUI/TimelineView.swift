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

    /// Label colours of media and sequences (from the Project panel); a clip draws in its effective label colour.
    public private(set) var labelResolver = LabelResolver()
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
    /// A text template (`TextTemplateCatalog` entry id) dragged in from the Text panel: id, drop time, track under the pointer.
    public var onDropTextTemplate: ((String, Time, Track.ID?) -> Void)?
    /// Files dragged in from the Library or Finder: URLs, drop time, track under the pointer, insert instead of overwrite.
    public var onDropFiles: (([URL], Time, Track.ID?, Bool) -> Void)?
    /// Describes a drag in flight (length, video/audio) so the ghost can be drawn. Nil or empty result = 5 s video placeholder.
    /// Peaks drawn inside audio clips; the owner calls `ensure` and the view redraws when peaks arrive.
    public var waveforms: TimelineWaveforms? { didSet { waveforms?.onReady = { [weak self] in self?.needsDisplay = true } } }
    public var dropItemsProvider: ((DropSource) -> [DropItem])?
    /// An effect (`com.sequencestudio.effect-id`) dropped on a clip: effect id, clip id.
    public var onDropEffect: ((String, Clip.ID) -> Void)?
    /// Live drop ghost (read-only for tests and the host).
    public private(set) var dropPreview = DropPreview()
    /// Clip highlighted while an effect is dragged over it.
    public private(set) var effectDropTarget: Clip.ID?
    private var scrubbing: (began: Bool, active: Bool) = (false, false)
    /// Edit point the playhead is stuck to while Shift-scrubbing (snap indicator), nil otherwise.
    public private(set) var scrubSnapTime: Time?
    /// Active tool, snapping and linked selection.
    public var toolState: ToolState {
        get { interaction.toolState }
        set {
            let changed = interaction.toolState.tool != newValue.tool
            interaction.toolState = newValue
            syncToolButtons()
            if changed { invalidateCursors() }
        }
    }
    /// The user picked a tool with a tool column button (keys set `toolState` directly).
    public var onToolChange: ((TimelineTool) -> Void)?
    /// Any click inside the view (ruler, clips, empty space), before it is handled: the host stops playback here.
    public var onPointerDown: (() -> Void)?
    private var toolButtons: [(tool: TimelineTool, button: NSButton)] = []

    // MARK: Track heights

    /// Track heights changed by the user (drag, command): the host persists them per sequence (`TrackHeightStore`).
    public var onTrackHeightsChange: (([Track.ID: CGFloat]) -> Void)?
    private var resizing: (zone: TrackSizing.Zone, startY: CGFloat, rows: [TrackRow])?

    /// User track heights (empty = automatic fit).
    public var trackHeights: [Track.ID: CGFloat] { geometry.heightOverrides }

    /// Restores heights (no callback: this is the store speaking).
    public func setTrackHeights(_ h: [Track.ID: CGFloat]) {
        guard h != geometry.heightOverrides else { return }
        applyHeights(h, notify: false)
    }

    /// Height commands: one step taller (+1) or shorter (-1) for the tracks of `kind` (nil = all).
    public func sizeTracks(_ kind: TrackKind?, direction: Int) {
        applyHeights(TrackSizing.stepped(rows: geometry.rows(for: timeline), kind: kind, direction: direction), notify: true)
    }
    public func minimizeAllTracks() { applyHeights(TrackSizing.minimizedAll(rows: geometry.rows(for: timeline)), notify: true) }
    public func expandAllTracks() { applyHeights(TrackSizing.expandedAll, notify: true) }

    private func applyHeights(_ h: [Track.ID: CGFloat], notify: Bool) {
        geometry.heightOverrides = h
        clampScroll()
        syncChildren()
        invalidateCursors()
        needsDisplay = true
        if notify { onTrackHeightsChange?(h) }
    }

    private func resizeZone(at p: CGPoint) -> TrackSizing.Zone? {
        guard resizing != nil || interaction.isIdle else { return nil }
        return TrackSizing.zone(at: p, rows: geometry.rows(for: timeline), viewWidth: bounds.width)
    }

    /// The header column and the V/A boundary belong to the view itself in their grab zones, so the header's buttons
    /// do not swallow the resize drag.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if bounds.contains(p), resizeZone(at: p) != nil { return self }
        return super.hitTest(point)
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
        self.geometry.viewportHeight = frame.height
        self.interaction = TimelineInteraction(timeline: timeline, geometry: geometry)
        self.ruler = RulerView(geometry: geometry)
        super.init(frame: frame)
        wantsLayer = true
        // macOS 14+: views do not clip by default, so an opaque `dirtyRect.fill()` would paint over its siblings.
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.sequenceMediaIDs, .sequenceTextTemplate, .sequenceEffectID, .fileURL])
        addSubview(ruler)
        buildToolButtons()
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
        invalidateCursors()
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

    public func setLabelResolver(_ r: LabelResolver) {
        guard r != labelResolver else { return }
        labelResolver = r
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
        invalidateCursors()
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
            invalidateCursors()
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
        if let zone = resizeZone(at: p) {      // a resize does not stop playback
            resizing = (zone, p.y, geometry.rows(for: timeline))
            return
        }
        onPointerDown?()
        if event.clickCount == 2, case .caption(let id, _) = geometry.hitTest(p, in: timeline) {
            onEditCaptionText?(id)
            return
        }
        if geometry.hitTest(p, in: timeline) == .ruler {
            scrubbing = (false, true)
            onSeek?(scrubTime(at: p, shift: event.modifierFlags.contains(.shift)))
            return
        }
        feedInteraction()
        interaction.mouseDown(p, modifiers: gestureModifiers(event))
        refreshFromInteraction()
    }

    public override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let r = resizing {
            let dy = p.y - r.startY
            switch r.zone {
            case .split:
                applyHeights(TrackSizing.splitDragged(rows: r.rows, dy: dy), notify: false)
            case .trackEdge(let id):
                let start = r.rows.first { $0.track == id }?.height ?? 0
                applyHeights(TrackSizing.resized(rows: r.rows, track: id, to: start + dy,
                                                 wholeKind: event.modifierFlags.contains(.shift)), notify: false)
            }
            return
        }
        if scrubbing.active {
            if !scrubbing.began { scrubbing.began = true; onScrubBegan?() }
            onScrub?(scrubTime(at: p, shift: event.modifierFlags.contains(.shift)))
            return
        }
        interaction.geometry = geometry
        interaction.mouseDragged(p, modifiers: gestureModifiers(event))
        refreshFromInteraction()
    }

    public override func mouseUp(with event: NSEvent) {
        if resizing != nil {
            resizing = nil
            onTrackHeightsChange?(geometry.heightOverrides)
            return
        }
        if scrubbing.active {
            if scrubbing.began { onScrubEnded?() }
            scrubbing = (false, false)
            setScrubSnap(nil)
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

    /// Time under the pointer for a playhead drag. Shift sticks it to clip edges, markers and 0 and shows the snap line.
    private func scrubTime(at p: CGPoint, shift: Bool) -> Time {
        guard shift else { setScrubSnap(nil); return geometry.time(atX: p.x) }
        let r = PlayheadSnap.resolve(geometry.unsnappedTime(atX: p.x), timeline: timeline, geometry: geometry)
        setScrubSnap(r.hit?.time)
        return r.time
    }

    private func setScrubSnap(_ t: Time?) {
        guard t != scrubSnapTime else { return }
        for time in [scrubSnapTime, t].compactMap({ $0 }) {
            setNeedsDisplay(CGRect(x: geometry.x(for: time) - 2, y: TimelineGeometry.rulerHeight, width: 4, height: bounds.height))
        }
        scrubSnapTime = t
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

    /// What a drag carries.
    public enum DropSource: Sendable { case media([MediaRef.ID]), textTemplate(String), files([URL]), effect(String) }

    private func dropped(_ info: NSDraggingInfo) -> DropSource? {
        let pb = info.draggingPasteboard
        if let id = pb.string(forType: .sequenceEffectID) { return .effect(id) }
        if let s = pb.string(forType: .sequenceMediaIDs) {
            let ids = ProjectPanelModel.decodeItems(s).compactMap { if case .media(let id) = $0 { id } else { nil } }
            if !ids.isEmpty { return .media(ids) }
        }
        if let id = pb.string(forType: .sequenceTextTemplate) { return .textTemplate(id) }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.isEmpty ? nil : .files(urls)
    }

    private func clipID(at p: CGPoint) -> Clip.ID? {
        if case .clip(let id, _) = geometry.hitTest(p, in: timeline) { return id }
        return nil
    }

    private func trackedUpdate(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let payload = dropped(info) else { return [] }
        let p = convert(info.draggingLocation, from: nil)
        if case .effect = payload {
            let target = clipID(at: p)
            if target != effectDropTarget { effectDropTarget = target; needsDisplay = true }
            return target == nil ? [] : .copy
        }
        if !dropPreview.isActive {
            let items = dropItemsProvider?(payload) ?? []
            dropPreview.begin(items: items.isEmpty ? [DropItem(name: "", duration: Time(seconds: 5))] : items)
        }
        let insert = NSEvent.modifierFlags.contains(.command)
        dropPreview.update(point: p, insert: insert, timeline: timeline, geometry: geometry,
                           snapping: toolState.snapping, playhead: playhead)
        needsDisplay = true
        return dropPreview.ghosts.isEmpty ? [] : .copy
    }

    private func endDropTracking() {
        guard dropPreview.isActive || effectDropTarget != nil else { return }
        dropPreview.cancel()
        effectDropTarget = nil
        needsDisplay = true
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { trackedUpdate(sender) }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { trackedUpdate(sender) }
    /// Left the timeline or Esc: the ghost vanishes, nothing was changed.
    public override func draggingExited(_ sender: NSDraggingInfo?) { endDropTracking() }
    public override func draggingEnded(_ sender: NSDraggingInfo) { endDropTracking() }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endDropTracking() }
        guard let payload = dropped(sender) else { return false }
        if case .effect(let id) = payload {
            guard let target = clipID(at: convert(sender.draggingLocation, from: nil)) else { return false }
            onDropEffect?(id, target)
            return true
        }
        _ = trackedUpdate(sender)
        guard let target = dropPreview.commitTarget else { return false }
        switch payload {
        case .media(let ids): onDropMedia?(ids, target.time, target.track, target.insert)
        case .textTemplate(let id): onDropTextTemplate?(id, target.time, target.track)
        case .files(let urls): onDropFiles?(urls, target.time, target.track, target.insert)
        case .effect: return false
        }
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
        geometry.viewportHeight = newSize.height
        clampScroll()
        layoutChildren()
        syncChildren()
        invalidateCursors()
        needsDisplay = true
    }

    private func layoutChildren() {
        ruler.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TimelineGeometry.rulerHeight)
        layoutToolButtons()
    }

    // MARK: Tool column

    private static let toolSymbols: [TimelineTool: (symbol: String, title: String)] = [
        .selection: ("cursorarrow", "Selection"),
        .trackSelectForward: ("arrow.right.to.line", "Track Select Forward"),
        .rippleEdit: ("arrow.left.and.right.righttriangle.left.righttriangle.right", "Ripple Edit"),
        .rollEdit: ("rectangle.split.2x1", "Rolling Edit"),
        .razor: ("scissors", "Razor"),
        .slip: ("arrow.left.and.right.square", "Slip"),
        .slide: ("arrow.left.and.right.square.fill", "Slide"),
        .hand: ("hand.raised", "Hand"),
        .pen: ("pencil.tip", "Pen"),
        .shape: ("rectangle", "Shape"),
        .mask: ("rectangle.dashed", "Mask"),
        .type: ("character.cursor.ibeam", "Type"),
    ]
    /// Order of the column, top to bottom (Paul's Premiere setup, FEEDBACK-4 item 27). Track Select, Ripple, Rolling
    /// and Slide stay on their keys (A, B, N, U) and in the Tools menu; Pen, Shape and Mask are disabled slots.
    static let toolColumnOrder: [TimelineTool] = [.selection, .razor, .slip, .pen, .shape, .mask, .hand, .type]
    static let toolButtonSize: CGFloat = 28
    static let toolButtonSpacing: CGFloat = 2

    private func buildToolButtons() {
        for tool in Self.toolColumnOrder {
            let info = Self.toolSymbols[tool]!
            let b = NSButton(frame: .zero)
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .smallSquare
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.image = NSImage(systemSymbolName: info.symbol, accessibilityDescription: info.title)
                ?? NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: info.title)
            b.imageScaling = .scaleProportionallyDown
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            b.toolTip = tool.isAvailable ? "\(info.title) (\(String(tool.key).uppercased()))" : "\(info.title): later"
            b.isEnabled = tool.isAvailable
            b.setAccessibilityLabel(info.title)
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.focusRingType = .none
            b.target = self
            b.action = #selector(toolButtonClicked(_:))
            b.tag = toolButtons.count
            addSubview(b)
            toolButtons.append((tool, b))
        }
        syncToolButtons()
    }

    @objc private func toolButtonClicked(_ sender: NSButton) {
        guard toolButtons.indices.contains(sender.tag) else { return }
        let tool = toolButtons[sender.tag].tool
        var s = toolState
        s.tool = tool
        toolState = s
        window?.makeFirstResponder(self)
        onToolChange?(tool)
    }

    /// Highlights the active tool (selected = accent tint background).
    private func syncToolButtons() {
        for (tool, b) in toolButtons {
            let on = tool == toolState.tool
            b.state = on ? .on : .off
            b.contentTintColor = on ? Theme.Colors.accent : (tool.isAvailable ? Theme.Colors.label2 : Theme.Colors.label3)
            b.layer?.backgroundColor = (on ? Theme.Colors.accentTint : NSColor.clear).cgColor
        }
    }

    private func layoutToolButtons() {
        let step = Self.toolButtonSize + Self.toolButtonSpacing
        var y = TimelineGeometry.rulerHeight + 4
        for (_, b) in toolButtons {
            let fits = y + Self.toolButtonSize <= bounds.height
            b.isHidden = !fits
            b.frame = CGRect(x: (TimelineGeometry.toolColumnWidth - Self.toolButtonSize) / 2, y: y,
                             width: Self.toolButtonSize, height: Self.toolButtonSize)
            y += step
        }
    }

    // MARK: Cursors

    private func invalidateCursors() { window?.invalidateCursorRects(for: self) }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateCursors()
    }

    /// Cursor rects per tool (see `TimelineCursorMap`): trim cursors on clip edges, razor over the tracks, ...
    public override func resetCursorRects() {
        discardCursorRects()
        let content = CGRect(x: TimelineGeometry.contentOriginX, y: TimelineGeometry.rulerHeight,
                             width: max(bounds.width - TimelineGeometry.contentOriginX, 0),
                             height: max(bounds.height - TimelineGeometry.rulerHeight, 0))
        for r in TimelineCursorMap.regions(timeline: timeline, geometry: geometry, tool: toolState.tool, content: content) {
            addCursorRect(r.rect, cursor: TimelineCursors.cursor(for: r.kind))
        }
        // Resize cursor on the V/A boundary (full width) and on header row edges; added last so it wins.
        let rows = geometry.rows(for: timeline)
        let g = TrackSizing.grab
        for (i, r) in rows.enumerated() where r.maxY > TimelineGeometry.rulerHeight && r.maxY < bounds.height {
            let split = i + 1 < rows.count && r.kind == .video && rows[i + 1].kind == .audio
            let x = TimelineGeometry.toolColumnWidth
            let w = split ? bounds.width - x : TimelineGeometry.headerWidth
            addCursorRect(CGRect(x: x, y: r.maxY - g, width: w, height: 2 * g), cursor: .resizeUpDown)
        }
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
        dirtyRect.intersection(bounds).fill()

        let rows = geometry.rows(for: timeline)
        let contentClip = CGRect(x: TimelineGeometry.contentOriginX, y: TimelineGeometry.rulerHeight,
                                 width: max(bounds.width - TimelineGeometry.contentOriginX, 0),
                                 height: max(bounds.height - TimelineGeometry.rulerHeight, 0))
        let clip = dirtyRect.intersection(contentClip)
        if !clip.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            clip.clip()
            drawCaptionLanes(clip: clip, visible: contentClip)
            drawLanes(rows: rows, clip: clip, visible: contentClip)
            drawPlayheadLine(clip: clip)
            drawGestureOverlay(clip: clip)
            drawDropOverlay(clip: clip)
            NSGraphicsContext.restoreGraphicsState()
        }
        drawToolColumn(dirty: dirtyRect)
        drawCaptionHeaders(dirty: dirtyRect)
    }

    /// `clip` is the dirty part of the content area, `visible` the whole content area: clip names and waveforms are laid
    /// out against `visible`, so a thin dirty rect (the playhead line) repaints them exactly as a full redraw would.
    private func drawCaptionLanes(clip: CGRect, visible: CGRect) {
        let visibleX = CGRect(x: visible.minX, y: 0, width: visible.width, height: bounds.height)
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

    private func drawLanes(rows: [TrackRow], clip: CGRect, visible: CGRect) {
        let visibleX = CGRect(x: visible.minX, y: 0, width: visible.width, height: bounds.height)
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
                                 visible: visibleX, style: .label(labelResolver.label(for: c)), isSelected: selection.contains(c.id),
                                 isOffline: offlineMedia.contains(c.media))
                if track.kind == .audio, !TrackSizing.isThin(row.height), let wf = waveforms, let d = wf.data[c.media] {
                    ClipDrawing.drawWaveform(data: d, media: c.media, source: c.source,
                                             rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height),
                                             visible: CGRect(x: clip.minX, y: 0, width: clip.width, height: bounds.height),
                                             cache: wf.cache)   // pixel-mapped: only the dirty columns are needed
                }
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
        if let t = interaction.snapTime ?? scrubSnapTime {
            let x = geometry.x(for: t).rounded()
            Theme.Colors.snapLine.setFill()
            CGRect(x: x - 0.5, y: clip.minY, width: 1, height: clip.height).fill()
        }
        if let m = interaction.marquee {
            Theme.Colors.accentTint.setFill()
            m.fill()
            Theme.Colors.accent.setStroke()
            NSBezierPath(rect: m.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    /// Drop ghost (video + linked audio at the snapped position), the insert arrow and the effect target outline.
    private func drawDropOverlay(clip: CGRect) {
        let rows = geometry.rows(for: timeline)
        if dropPreview.isActive, !dropPreview.ghosts.isEmpty {
            for g in dropPreview.ghosts {
                let rowY: CGFloat, rowH: CGFloat
                if let row = rows.first(where: { $0.track == g.track }) {
                    rowY = row.y; rowH = row.height
                } else if let n = g.newTrackOrdinal {
                    // Audio track the drop creates: drawn below the last audio row.
                    let audio = rows.filter { $0.kind == .audio }
                    let last = audio.last ?? rows.last
                    rowH = last?.height ?? 40
                    rowY = (last?.maxY ?? TimelineGeometry.rulerHeight) + CGFloat(max(n - audio.count, 0)) * rowH
                } else { continue }
                let r = CGRect(x: geometry.x(for: g.range.start), y: rowY,
                               width: max(geometry.width(of: g.range.duration), 2), height: rowH - 1)
                (g.kind == .audio ? Theme.Colors.clipAudio : Theme.Colors.clipVideo).withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
                Theme.Colors.accent.setStroke()
                let outline = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                outline.lineWidth = 1
                outline.setLineDash([4, 3], count: 2, phase: 0)
                outline.stroke()
            }
            if let t = dropPreview.snapTime {
                Theme.Colors.snapLine.setFill()
                CGRect(x: geometry.x(for: t).rounded() - 0.5, y: clip.minY, width: 1, height: clip.height).fill()
            }
            if dropPreview.insert, let first = dropPreview.ghosts.first, let row = rows.first(where: { $0.track == first.track }) {
                // Premiere's ripple arrow: a triangle at the insert point pushing later clips right.
                let x = geometry.x(for: dropPreview.start)
                let cy = row.y + row.height / 2
                let arrow = NSBezierPath()
                arrow.move(to: CGPoint(x: x, y: cy - 7))
                arrow.line(to: CGPoint(x: x + 9, y: cy))
                arrow.line(to: CGPoint(x: x, y: cy + 7))
                arrow.close()
                Theme.Colors.accent.setFill()
                arrow.fill()
            }
        }
        if let id = effectDropTarget,
           let (row, c) = rows.compactMap({ r in timeline.track(r.track)?.clips.first { $0.id == id }.map { (r, $0) } }).first {
            let r = CGRect(x: geometry.x(for: c.timeline.start), y: row.y,
                           width: geometry.width(of: c.timeline.duration), height: row.height - 1)
            Theme.Colors.accentTint.setFill()
            r.fill()
            Theme.Colors.accent.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
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
