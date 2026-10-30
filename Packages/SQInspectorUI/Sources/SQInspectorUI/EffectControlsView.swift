import AppKit
import Observation
import SQCore

/// Controls panel (design source: Main board, Panels board "Controls and monitors"). Left: a header line (clip name,
/// "Video · duration"), VIDEO / AUDIO group labels, section rows (chevron, eye, title, summary, reset) and parameter rows
/// (animate diamond, label, values, key navigation, Open). Right: the ruler with the playhead head and one keyframe lane
/// per row, separated by a draggable divider (width persisted). An opened row shows its inline speed graph directly
/// under it (variant A). The zoom bar appears at the bottom while the keyframe area is zoomed in. All state and edits
/// live in `EffectControlsModel`.
public final class EffectControlsView: NSView {
    /// Width of the properties column (left of the divider).
    public private(set) var labelWidth: CGFloat = EffectControlsSplit.load()
    /// Receives the new width when a divider drag ends; default: UserDefaults.
    public var persistLabelWidth: (CGFloat) -> Void = { EffectControlsSplit.save($0) }

    public let model: EffectControlsModel
    /// Asked before the animate diamond deletes all keys of a property. Default: alert.
    public var confirmRemoval: @MainActor (EffectProperty) -> Bool = EffectControlsView.defaultConfirm

    /// The content sections of the skeleton (Text or Shape and Appearance before Transform, Arrange and Animation
    /// around it, Audio or the caption list at the end); set by the app. `layout()` places them between the rows.
    public var clipSections: ClipSectionsView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let c = clipSections else { return }
            content.addSubview(c)
            c.onHeightChange = { [weak self] in self?.needsLayout = true }
            needsLayout = true
        }
    }

    private let scroll = NSScrollView()
    private let content = FlippedView()
    let lanes: EffectKeyframeLanesView
    let ruler: KeyframeRulerView
    private let zoomBar: ZoomScrollBar
    /// Curve icon at the left end of the ruler: easing popover for the selected keys.
    public let curveButton: EasingCurveButton
    /// Graph Editor (AE style speed graph over all animated properties), shown instead of the lanes while on.
    let graphEditorView: GraphEditorView
    /// Top-right toggle of the keyframe area: lanes <-> Graph Editor.
    public let graphToggle: GraphEditorToggle
    /// Receives the Graph Editor state when the toggle is clicked; default: UserDefaults.
    public var persistGraphEditor: (Bool) -> Void = { EffectControlsGraphEditorPref.save($0) }
    private let divider = EffectControlsDivider()
    private var dividerStartWidth: CGFloat = 0
    /// Clip line (v9 `.clhead`): icon, clip name, then "Main · V1 · 00:00:15:00 – 00:00:17:00" muted.
    let clipNameLabel = makeLabel("", font: Theme.Typography.bodyStrong, color: Theme.Colors.label)
    let clipInfoLabel = makeLabel("", font: Theme.Typography.caption, color: Theme.Colors.label3)
    private let clipIcon = NSImageView()
    private(set) var clipIconName: SQIcon?
    private let headerLine = NSView()
    /// Column header row (v9 `.khead`): "Property" over the rows, the mini ruler over the lanes.
    let propertyLabel = makeLabel("Property", font: Theme.Typography.caption, color: Theme.Colors.label3)
    private let propertyLine = NSView()
    let emptyState = EmptyStateView(title: "No clip selected", hint: "Select a clip in the timeline to see its Controls.")
    private var rowViews: [(EffectRow, NSView)] = []
    private var signature: Signature?

    private struct Signature: Equatable {
        var clipID: UUID?
        var kind: TrackKind?
        var sections: [EffectSection]
        var collapsed: Set<EffectSection>
        var expanded: Set<EffectProperty>
        var uniformScale: Bool
        var openColorGroups: Set<String>
        var subjectMasks: [UUID]
        var pictureMasks: Set<UUID> = []
        var colorRangeMasks: Set<UUID> = []
        var gradeRanges: [ClipEffect.ID] = []
        var graphEditor = false
        var unlinkedPairs: [ClipEffect.ID] = []
        var stabilizers: [ClipEffect.ID: StabilizerMethod] = [:]
        var transformCrop: [EffectProperty] = []
    }

    /// An effect dragged from the Effects panel (its kind) or a preset dragged from the Library (its id) onto this panel:
    /// applied to the clip shown here.
    public var onDropEffect: ((String) -> Void)?
    public var onDropPreset: ((UUID) -> Void)?
    /// G1: a keystone dropped here lands on the shown clip around the playhead.
    public var onDropKeystone: ((Keystone) -> Void)?

    public init(model: EffectControlsModel) {
        self.model = model
        lanes = EffectKeyframeLanesView(model: model)
        ruler = KeyframeRulerView(model: model)
        zoomBar = ZoomScrollBar.keyframe(model: model)
        curveButton = EasingCurveButton(model: model)
        graphEditorView = GraphEditorView(model: model)
        graphToggle = GraphEditorToggle(model: model)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        // Reachable from the row menu and View > Graph Editor (D4). The app loads the remembered state
        // (`EffectControlsGraphEditorPref.load()`); the view only saves it, so tests never read a stored value.
        model.onGraphEditorChanged = { [weak self] on in self?.persistGraphEditor(on); self?.graphToggle.update() }
        registerForDraggedTypes([.sequenceEffectID, .sequencePresetID, .sequenceKeystone])
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay      // the lanes must keep the ruler's width
        scroll.documentView = content
        addSubview(scroll)
        addSubview(graphEditorView)
        graphEditorView.keyMenu = { [weak self] onKey in self?.lanes.makeKeyItems(onKey: onKey) ?? [] }
        addSubview(emptyState)
        content.addSubview(lanes)
        addSubview(ruler)
        addSubview(zoomBar)
        addSubview(clipIcon); addSubview(clipNameLabel); addSubview(clipInfoLabel)
        clipIcon.contentTintColor = Theme.Colors.label3
        clipInfoLabel.lineBreakMode = .byTruncatingTail
        headerLine.wantsLayer = true
        headerLine.layer?.backgroundColor = Theme.Colors.separator.cgColor
        addSubview(headerLine)
        propertyLine.wantsLayer = true
        propertyLine.layer?.backgroundColor = Theme.Colors.trackRowLine.cgColor
        addSubview(propertyLabel); addSubview(propertyLine)
        // v9 `.cempty`: the title is the strong line, the hint the muted one under it.
        addSubview(divider)
        divider.onBegin = { [weak self] in self?.dividerStartWidth = self?.labelWidth ?? 0 }
        divider.onDrag = { [weak self] dx in
            guard let self else { return }
            setLabelWidth(dividerStartWidth + dx)
        }
        divider.onEnd = { [weak self] in
            guard let self else { return }
            persistLabelWidth(labelWidth)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Controls")
        rebuild()
        observe()
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Keys

    public override var acceptsFirstResponder: Bool { true }

    /// Click on empty space in the panel: nothing stays selected (the maintainer: only the timeline selection persists).
    public override func mouseDown(with event: NSEvent) {
        model.clearRowSelection()
        window?.makeFirstResponder(self)
    }

    /// Focus left the panel (another panel was clicked): the row selection goes. Focus moving between Controls' own
    /// parts (rows, lanes, fields) keeps it.
    public override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if let v = window.firstResponder as? NSView, v.isDescendant(of: self) { return }
            if let t = window.firstResponder as? NSText, let d = t.delegate as? NSView, d.isDescendant(of: self) { return }
            self.model.clearRowSelection()
        }
        return super.resignFirstResponder()
    }

    /// A click anywhere in the window outside this panel clears the selection, whichever of the panel's views (rows,
    /// keyframe lanes) holds the focus. Clicks inside the panel never clear here.
    private var clickAwayMonitor: Any?

    /// True when a click at `point` (panel coordinates) is outside the panel.
    static func isClickAway(_ point: NSPoint, panelBounds: NSRect) -> Bool { !panelBounds.contains(point) }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = clickAwayMonitor { NSEvent.removeMonitor(m); clickAwayMonitor = nil }
        guard window != nil else { return }
        clickAwayMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let w = self.window, event.window === w else { return }
                if Self.isClickAway(self.convert(event.locationInWindow, from: nil), panelBounds: self.bounds) {
                    self.model.clearRowSelection(keepMask: true)
                }
            }
            return event
        }
    }

    /// Top-left origin: the layout below is written top-down (ruler first, zoom bar last).
    public override var isFlipped: Bool { true }

    /// Delete / Forward Delete: removes the selected effect section (keys first when any are selected).
    public override func keyDown(with event: NSEvent) {
        if KeyframeZoomInput.key(event, model: model) { return }
        switch event.keyCode {
        case 51, 117: model.deleteSelectionOrEffect()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Observation

    private func observe() {
        withObservationTracking {
            _ = model.clip; _ = model.peers; _ = model.playhead; _ = model.selection; _ = model.expanded
            _ = model.collapsedSections; _ = model.selectedSection; _ = model.graphMode; _ = model.graphModeByProperty; _ = model.easingLibrary
            _ = model.viewport; _ = model.uniformScale     // the Scale row has one field or two
            _ = model.effectDefaults                       // FB-W: default markers and Reset state
            _ = model.graphEditor; _ = model.graphProperties; _ = model.graphShowAll; _ = model.graphSnap
            model.observeStabilize()                       // the Stabilizer's Analyze row: progress / Cancel / engine state
            _ = MaskTrackActivity.shared.run               // the mask row's Stop / progress
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.modelChanged()
                self?.observe()
            }
        }
    }

    private var currentSignature: Signature {
        Signature(clipID: model.clip?.id, kind: model.clip?.kind, sections: model.visibleSections,
                  collapsed: model.collapsedSections, expanded: model.expanded, uniformScale: model.uniformScale,
                  openColorGroups: model.openColorGroups,
                  subjectMasks: model.subjectMaskIDs, pictureMasks: model.pictureMaskIDs, colorRangeMasks: model.colorRangeMaskIDs, gradeRanges: model.gradeRangeEffects, graphEditor: model.graphEditor,
                  unlinkedPairs: model.unlinkedPairEffects, stabilizers: model.stabilizerMethods,
                  transformCrop: model.transformCropProperties)
    }

    private func modelChanged() {
        if showsZoomBar == zoomBar.isHidden { needsLayout = true }
        if currentSignature != signature { rebuild() } else { refresh() }
    }

    /// What the observation does after a model change (tests, profiling).
    func reloadForModelChange() { modelChanged() }
    /// Row views currently shown, top to bottom (tests).
    var shownRowViews: [NSView] { rowViews.map(\.1) }

    /// Rows of the clip shown before that the new clip can keep: `rebuild` reuses one where the new clip has a row of
    /// the same kind. Only rows that name no effect, mask or parameter id are kept (Transform, Speed, Volume and their
    /// headers): such a row view reads the clip in `update()`, and what it fixes when it is built (uniform scale, its
    /// own collapsed / open state, clip kind) has to match. Rows bound to an id are always built anew, also when the
    /// id is the same (the halves of a cut clip share effect ids but not the per-effect row variants), and so are
    /// inline graph rows and the row a field of which is being edited (its text belongs to the old clip).
    private func reusableRows(for new: Signature) -> [(EffectRow, NSView)] {
        guard let old = signature, old.clipID != nil, new.clipID != nil, old.clipID != new.clipID,
              old.kind == new.kind, old.uniformScale == new.uniformScale, old.graphEditor == new.graphEditor
        else { return [] }
        var edited = window?.firstResponder as? NSView
        if let editor = edited as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { edited = field }
        return rowViews.filter { row, view in
            if let edited, edited.isDescendant(of: view) { return false }
            switch row.kind {
            case .section(let s):
                return EffectSection.builtIns.contains(s) && old.collapsed.contains(s) == new.collapsed.contains(s)
            case .property(let p):
                return EffectProperty.builtIns.contains(p) && old.expanded.contains(p) == new.expanded.contains(p)
            case .placeholder(let s): return EffectSection.builtIns.contains(s)
            case .speedControl, .blendMode, .group: return true
            default: return false
            }
        }
    }

    /// The zoom bar is always there while a clip is shown (subtle, own strip under the lanes; the maintainer: it must stay visible fully zoomed out).
    var showsZoomBar: Bool { model.clip != nil }

    /// "Video · 00:00:05:14": the clip's kind and duration. `kindName` names a text, shape, template or graphic clip.
    static func clipInfo(kind: TrackKind, duration: Time, frameDuration: Time, kindName: String? = nil) -> String {
        EffectControlsHeaderText.clipInfo(kind: kind, duration: duration, frameDuration: frameDuration, kindName: kindName)
    }

    static func clipMeta(sequence: String?, track: String?, start: Time, end: Time, frameDuration: Time, kindName: String? = nil) -> String {
        EffectControlsHeaderText.clipMeta(sequence: sequence, track: track, start: start, end: end, frameDuration: frameDuration, kindName: kindName)
    }

    /// No clip, but a caption track: the column shows the track's caption list (read only).
    var showsCaptions: Bool { model.clip == nil && clipSections?.mode == .captions }

    /// Nothing selected: no ruler, zoom bar or divider, just the empty state. A caption track keeps the header.
    private func updateChrome() {
        let none = model.clip == nil, captions = showsCaptions
        emptyState.isHidden = !none || captions
        for v in [ruler, divider, lanes] as [NSView] where v.isHidden != none { v.isHidden = none }
        for v in [propertyLabel, propertyLine] as [NSView] where v.isHidden != none { v.isHidden = none }
        for v in [clipIcon, clipNameLabel, clipInfoLabel, headerLine] as [NSView] where v.isHidden != (none && !captions) { v.isHidden = none && !captions }
    }

    private func updateHeader() {
        var name = "", info = "", tip = "", icon: SQIcon = .film
        if let c = model.clip {
            // Multi-select: the edits go to every selected clip, so the header names how many.
            name = model.isMulti ? "\(model.peers.count + 1) clips selected" : c.name
            let kindName = ClipSectionMode.resolve(c).kindName
            let timeline = model.timeline?()
            let track = timeline?.tracks.first { $0.clips.contains { $0.id == c.id } }.flatMap { timeline?.trackLabel($0.id) }
            info = Self.clipMeta(sequence: timeline?.name, track: track, start: c.start, end: c.start + model.duration,
                                 frameDuration: model.frameDuration, kindName: kindName)
            // Kind and duration (the old header text) stay in the tooltip.
            tip = Self.clipInfo(kind: c.kind, duration: model.duration, frameDuration: model.frameDuration, kindName: kindName)
            icon = c.kind == .audio ? .waveform : .film
        } else if showsCaptions, let s = clipSections?.captionSummary {
            name = s.name
            info = "Captions \u{00B7} \(s.count)"
            icon = .captions
        }
        if clipIconName != icon { clipIconName = icon; clipIcon.image = Theme.symbol(icon, size: Theme.Typography.symbolSmall + 2) }
        clipInfoLabel.sqToolTip = tip.isEmpty ? nil : Tooltip.text(tip, shortcut: nil)
        if clipNameLabel.stringValue != name { clipNameLabel.stringValue = name; needsLayout = true }
        if clipInfoLabel.stringValue != info { clipInfoLabel.stringValue = info; needsLayout = true }
    }

    // MARK: Skeleton

    /// Where the content sections sit between the rows, and the rows at the place they are shown.
    struct Placement: Equatable {
        var rows: [EffectRow] = []
        /// Text or Shape and Appearance: before Transform.
        var top = NSRect.zero
        /// Arrange: the last rows of an open Transform.
        var tail = NSRect.zero
        /// Animation: right after Transform.
        var animation = NSRect.zero
        /// Audio or the caption list: after every effect.
        var bottom = NSRect.zero
        var height: CGFloat = 0
    }
    private(set) var placement = Placement()

    /// One skeleton for every clip kind: content, Appearance, Transform (+ Arrange), Animation, the remaining
    /// sections in model order, Audio or the caption list. Sections a clip does not have take no room.
    private func place(_ rows: [EffectRow], width lw: CGFloat) -> Placement {
        var p = Placement()
        let gap = ControlsMetrics.sectionGap
        let sec = clipSections.flatMap { $0.isHidden || $0.mode == .none ? nil : $0 }
        var offset: CGFloat = 0
        if let sec, sec.mode.leads {
            let h = sec.preferredHeight(for: lw)
            p.top = NSRect(x: 0, y: 0, width: lw, height: h)
            if h > 0, !rows.isEmpty { offset = h + gap }
        }
        func isSection(_ r: EffectRow) -> Bool { if case .section = r.kind { return true } else { return false } }
        // Arrange and Animation go in before the first section that follows Transform.
        let motion = rows.firstIndex { $0.kind == .section(.motion) }
        let insert = motion.flatMap { m in rows[(m + 1)...].firstIndex(where: isSection) } ?? rows.count
        var shift: CGFloat = 0
        if let sec, sec.mode.leads, motion != nil {
            let end = (insert < rows.count ? rows[insert].y - gap : rows.last.map { $0.y + $0.height } ?? 0) + offset
            let tailH = model.collapsedSections.contains(.motion) ? 0 : sec.transformTailHeight(for: lw)
            p.tail = NSRect(x: 0, y: end, width: lw, height: tailH)
            let animH = sec.afterTransformHeight(for: lw)
            p.animation = NSRect(x: 0, y: end + tailH + gap, width: lw, height: animH)
            shift = tailH + (animH > 0 ? gap + animH : 0)
        }
        p.rows = rows.enumerated().map { i, r in
            var r = r
            r.y += offset + (i >= insert ? shift : 0)
            return r
        }
        var y = rows.last.map { $0.y + $0.height + offset + shift } ?? p.top.maxY
        if let sec, !sec.mode.leads {
            if y > 0 { y += gap }
            let h = sec.preferredHeight(for: lw)
            p.bottom = NSRect(x: 0, y: y, width: lw, height: h)
            y += h
        }
        p.height = y
        return p
    }

    /// Applies `place` to the views: the content slot, the parts of a text clip and the lanes' rows.
    private func applyPlacement(width lw: CGFloat) {
        // The caption list fills what the column shows (it scrolls by itself).
        clipSections?.availableHeight = scroll.frame.height
        let p = place(rowViews.map(\.0), width: lw)
        placement = p
        if lanes.rows != p.rows { lanes.rows = p.rows }
        lanes.contentBottom = p.height
        guard let sec = clipSections else { return }
        sec.frame = sec.mode.leads ? p.top : p.bottom
        let tail = sec.transformTailView, anim = sec.afterTransformView
        for part in sec.partViews {
            if part.superview !== content { content.addSubview(part) }
            let frame: NSRect? = part === tail && p.tail.height > 0 ? p.tail : part === anim && p.animation.height > 0 ? p.animation : nil
            if part.isHidden != (frame == nil) { part.isHidden = frame == nil }
            if let frame, part.frame != frame { part.frame = frame }
        }
    }

    // MARK: Build / refresh

    /// Rows currently shown (tests).
    var shownRows: [EffectRow] { rowViews.map(\.0) }
    /// The scrolled content the row views sit in (layout tests).
    var contentView: NSView { content }
    /// Value fields filled with their Graph Editor curve color (tests).
    var tintedFieldCount: Int { rowViews.reduce(0) { $0 + (($1.1 as? PropertyRow)?.tintedCount ?? 0) } }

    /// Shows the model's rows. A clip of the same shape as the one shown keeps its row views (`reusing`; false builds
    /// every row from scratch).
    func rebuild(reusing: Bool = true) {
        let started = FollowTiming.logs ? ContinuousClock.now : nil
        let interval = TimelineSignpost.log.beginInterval("effectControlsRebuild")
        defer {
            TimelineSignpost.log.endInterval("effectControlsRebuild", interval)
            if let started { FollowTiming.report("effectControlsRebuild", since: started) }
        }
        let newSignature = currentSignature
        var kept = reusing ? reusableRows(for: newSignature) : []
        for (_, v) in rowViews where !kept.contains(where: { $0.1 === v }) { v.removeFromSuperview() }
        rowViews = []
        signature = newSignature
        updateChrome()
        zoomBar.isHidden = !showsZoomBar
        graphEditorView.isHidden = model.clip == nil || !model.graphEditor
        // Graph Editor: the property list stays compact (no inline graphs under the rows); the graph shows them all.
        let rows = EffectControlsLayout.rows(sections: model.visibleSections, collapsed: model.collapsedSections,
                                             expanded: model.graphEditor ? [] : model.expanded, blendModeRow: true, groupHeaders: false,
                                             openColorGroups: model.openColorGroups,
                                             subjectMasks: model.subjectMaskIDs, pictureMasks: model.pictureMaskIDs, colorRangeMasks: model.colorRangeMaskIDs, gradeRanges: model.gradeRangeEffects,
                                             stabilizers: model.stabilizerMethods,
                                             transformCrop: model.transformCropProperties)
        for row in rows {
            // Same row kind as before (a group header also at the same place: its top line depends on it): the view stays.
            if let i = kept.firstIndex(where: { $0.0.kind == row.kind && ($0.0.y == 0) == (row.y == 0) }) {
                rowViews.append((row, kept.remove(at: i).1))
                continue
            }
            let v: NSView
            switch row.kind {
            case .section(let s): v = SectionHeaderRow(section: s, model: model)
            case .property(let p): v = EffectParamRows.make(p, model: model, owner: self) ?? PropertyRow(property: p, model: model, owner: self)
            case .placeholder(let s): v = PlaceholderRow(title: s.title)
            case .graph(let p):
                let g = SpeedGraphRow(property: p, model: model)
                // The graph's right-click menu: curve presets, then the key items (copy, paste, delete).
                g.speedGraph.extraMenu = { [weak self] in
                    self?.lanes.makeKeyItems(onKey: true) ?? []
                }
                // A marquee started in the curve goes on over the lanes' diamonds.
                g.speedGraph.outerMarquee = { [weak self] rect, view in self?.lanes.externalMarquee(rect, from: view) ?? [] }
                v = g
            case .speedControl(.timeInterpolation): v = TimeInterpolationRow(model: model)
            case .speedControl(let k): v = SpeedControlRow(kind: k, model: model)
            case .blendMode: v = BlendModeRow(model: model)
            case .subjectMask(let id): v = SubjectMaskRow(maskID: id, model: model)
            case .maskControls(let id): v = MaskControlsRow(maskID: id, model: model) { [weak self] in self?.stopwatchTapped(.maskPath(id)) }
            case .maskTrack(let id): v = MaskTrackRow(maskID: id, model: model)
            case .pictureMask(let id): v = PictureMaskRow(maskID: id, model: model)
            case .colorRangeMask(let id): v = ColorRangeMaskRow(maskID: id, model: model)
            case .colorRangeAmount(let id, let soft): v = ColorRangeAmountRow(maskID: id, soft: soft, model: model)
            case .maskUse(let id): v = MaskUseRow(maskID: id, model: model)
            case .group(let g): v = GroupHeaderRow(title: g.title, first: row.y == 0)
            case .colorGroup(let id, let key): v = ColorGroupHeaderRow(effect: id, key: key, model: model)
            case .curves(let id): v = ColorCurvesRow(effect: id, model: model)
            case .multiband(let id): v = MultibandEditorRow(effect: id, model: model)
            case .multibandParams(let id): v = MultibandParamsRow(effect: id, model: model)
            case .eqCurveHeader(let id): v = EQCurveHeaderRow(effect: id, model: model)
            case .eqCurve(let id): v = EQCurveRow(effect: id, model: model)
            case .colorMatch(let id): v = ColorMatchRow(effect: id, model: model)
            case .colorGraph(let id): v = ColorGraphSummaryRow(effect: id, model: model)
            case .gradeRange(let id): v = GradeRangeRow(effect: id, model: model)
            case .gradeFade(let id): v = GradeFadeRow(effect: id, model: model)
            case .stabilizeAnalyze(let id): v = StabilizeAnalyzeRow(effect: id, model: model)
            case .trackMaskTrack(let id): v = TrackMaskTrackRow(effect: id, model: model)
            }
            content.addSubview(v)
            rowViews.append((row, v))
        }
        for (_, v) in kept { v.removeFromSuperview() }      // rows the new clip does not have
        lanes.rowsCollapsed = model.collapsedSections; lanes.rowsOpenGroups = model.openColorGroups
        applyPlacement(width: EffectControlsSplit.clamp(labelWidth, total: bounds.width))
        needsLayout = true
        refresh()
    }

    /// Everything after a model change: row fields, then the content of the keyframe views (each redraws only when
    /// what it shows changed), then the playhead layers.
    func refresh() {
        updateHeader()
        for (_, v) in rowViews { (v as? RowUpdating)?.update() }
        refreshContent()
        movePlayhead()
    }

    /// Keyframe views: they compare their own display keys and redraw only on a real change (never on a playhead tick).
    func refreshContent() {
        lanes.refreshContent()
        if !graphEditorView.isHidden { graphEditorView.refreshContent() }
        ruler.refreshContent()
        let zoomKey = ZoomKey(revision: model.clipRevision, viewport: model.viewport, size: zoomBar.bounds.size)
        if zoomKey != drawnZoomKey { drawnZoomKey = zoomKey; zoomBar.needsDisplay = true }
    }
    private struct ZoomKey: Equatable { var revision: Int; var viewport: KeyframeViewport; var size: CGSize }
    private var drawnZoomKey: ZoomKey?

    /// Playhead tick: the playhead layers of lanes, ruler and graph, and the timecode.
    func movePlayhead() {
        lanes.movePlayhead()
        ruler.movePlayhead()
        if !graphEditorView.isHidden { graphEditorView.movePlayhead() }
        for (row, v) in rowViews { if case .graph = row.kind { (v as? SpeedGraphRow)?.movePlayhead() } }
    }

    /// Sets the divider position (clamped to the min/max widths) and lays out again.
    public func setLabelWidth(_ w: CGFloat) {
        let c = EffectControlsSplit.clamp(w, total: bounds.width)
        guard c != labelWidth else { return }
        labelWidth = c
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        zoomBar.isHidden = !showsZoomBar
        // Clip line across the panel, then the column header row ("Property" + mini ruler; only with a clip).
        let ch = ControlsMetrics.clipLine, bh = zoomBar.isHidden ? 0 : ZoomScrollBar.height
        let rh = model.clip == nil ? 0 : KeyframeRulerView.height
        let lw = EffectControlsSplit.clamp(labelWidth, total: bounds.width)
        let lanesW = max(bounds.width - lw, 0)
        ruler.frame = NSRect(x: lw, y: ch, width: lanesW, height: KeyframeRulerView.height)
        updateChrome()
        // v9 `.clhead`: icon, name, meta, left to right with the panel's 12 pt inset; the meta takes what the name leaves.
        let lead = Theme.Spacing.md, trail = ControlsGrid.trailing, lh = ControlsGrid.labelHeight, iconSide: CGFloat = 14
        clipIcon.frame = NSRect(x: lead, y: ((ch - iconSide) / 2).rounded(), width: iconSide, height: iconSide)
        let nameX = clipIcon.frame.maxX + Theme.Spacing.sm, room = max(bounds.width - nameX - trail, 0)
        let nameW = min(ceil(clipNameLabel.attributedStringValue.size().width) + 4, room)
        clipNameLabel.frame = NSRect(x: nameX, y: ((ch - lh) / 2).rounded(), width: nameW, height: lh)
        let infoX = nameX + nameW + Theme.Spacing.sm
        clipInfoLabel.frame = NSRect(x: infoX, y: ((ch - lh) / 2).rounded(), width: max(bounds.width - trail - infoX, 0), height: lh)
        headerLine.frame = NSRect(x: 0, y: ch - 1, width: bounds.width, height: 1)
        propertyLabel.frame = NSRect(x: lead, y: ch + ((rh - lh) / 2).rounded(), width: max(lw - lead - trail, 0), height: lh)
        propertyLine.frame = NSRect(x: 0, y: ch + rh - 1, width: lw, height: 1)
        let top = ch + rh
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top - bh, 0))
        graphEditorView.frame = NSRect(x: lw, y: top, width: lanesW, height: scroll.frame.height)
        // Header strip above the property list, next to the curve button (After Effects: right of the switch icons).
        zoomBar.frame = NSRect(x: lw, y: bounds.height - bh, width: lanesW, height: bh)
        divider.frame = NSRect(x: lw - 3, y: ch, width: 7, height: max(bounds.height - ch, 0))
        emptyState.frame = bounds
        // The skeleton: content sections and rows share the column that ends at the divider; the keyframe lanes own
        // everything to the right.
        applyPlacement(width: lw)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(placement.height, scroll.frame.height))
        for (i, (_, v)) in rowViews.enumerated() {
            let row = placement.rows[i]
            let isGraph = { if case .graph = row.kind { return true } else { return false } }()
            v.frame = NSRect(x: 0, y: row.y, width: isGraph ? bounds.width : lw, height: row.height)
        }
        // The lanes cover the whole scrollable height: the empty area under the last row still shows the playhead line,
        // zooms / pans and deselects like the rest of the keyframe area.
        lanes.frame = NSRect(x: lw, y: 0, width: lanesW, height: content.frame.height)
        // Graph rows are laid out by themselves (they need the lane origin).
        for (row, v) in rowViews { if case .graph = row.kind { (v as? SpeedGraphRow)?.laneX = lw; v.needsLayout = true } }
        refresh()
    }

    // MARK: Reorder effects (drag a header)

    private let dropLine = NSView()
    private var dropTarget: Int?

    /// Effect headers in list order with the vertical extent of their block (header plus property rows).
    private func effectBlocks() -> [(section: EffectSection, frame: NSRect)] {
        var out: [(EffectSection, NSRect)] = []
        let rows = placement.rows
        let total = rows.last.map { $0.y + $0.height } ?? 0
        for (i, row) in rows.enumerated() {
            guard case .section(let s) = row.kind, s.effectKind != nil else { continue }
            let next = rows[(i + 1)...].first { if case .section = $0.kind { return true } else { return false } }
            let end = next?.y ?? total
            out.append((s, NSRect(x: 0, y: row.y, width: bounds.width, height: end - row.y)))
        }
        return out
    }

    fileprivate func reorderMoved(_ s: EffectSection, windowPoint: NSPoint) {
        let blocks = effectBlocks()
        guard let from = blocks.firstIndex(where: { $0.section == s }) else { return }
        let y = content.convert(windowPoint, from: nil).y
        let target = EffectControlsModel.dropIndex(forY: y, midpoints: blocks.map { $0.frame.minY + 9 }, dragging: from)
        dropTarget = target
        guard target != from else { dropLine.isHidden = true; return }
        if dropLine.superview == nil {
            dropLine.wantsLayer = true
            dropLine.layer?.backgroundColor = Theme.Colors.accent.cgColor
            content.addSubview(dropLine)
        }
        let lineY = target < from ? blocks[target].frame.minY : blocks[target].frame.maxY
        dropLine.frame = NSRect(x: 0, y: lineY - 1, width: labelWidth, height: 2)
        dropLine.isHidden = false
    }

    fileprivate func reorderEnded(_ s: EffectSection) {
        dropLine.isHidden = true
        let blocks = effectBlocks()
        defer { dropTarget = nil }
        guard let t = dropTarget, t < blocks.count, let from = blocks.firstIndex(where: { $0.section == s }), t != from,
              let index = model.effectIndex(blocks[t].section) else { return }
        model.moveEffect(s, toIndex: index)
    }

    // MARK: Animate diamond

    /// The animation switch of a parameter row: off -> on sets the first key at the playhead; on -> off asks, then
    /// removes every key (the value at the playhead stays). It never adds or deletes a single key.
    func animateTapped(_ p: EffectProperty) { stopwatchTapped(p) }

    func stopwatchTapped(_ p: EffectProperty) {
        if model.toggleStopwatch(p) == .needsConfirmation, confirmRemoval(p) {
            model.toggleStopwatch(p, confirmRemoval: true)
        }
    }

    @MainActor private static func defaultConfirm(_ p: EffectProperty) -> Bool { confirmRemoveKeyframes(title: p.title) }

    /// R29: turning animation off asks first (shared by Effect Controls and the Graphics panel).
    @MainActor static func confirmRemoveKeyframes(title: String) -> Bool {
        KeyToolsDialogs.run(.removeKeyframes(title)) != nil
    }
}

// MARK: - Row views

@MainActor protocol RowUpdating { func update() }

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Effect Controls row geometry (one place, shared by every row kind and the Text panel).
enum EC {
    /// Older names of the `ControlsGrid` edges (the mask rows read these).
    static let ringX: CGFloat = ControlsGrid.toggleX
    static let nameX: CGFloat = ControlsGrid.labelX
    static let nameWidth: CGFloat = ControlsGrid.labelWidth
    static let controlX: CGFloat = ControlsGrid.valueX
    static let labelHeight: CGFloat = ControlsGrid.labelHeight
    static let iconSlot: CGFloat = Theme.Inspector.iconSlot
    static let trailing: CGFloat = ControlsGrid.trailing
}

/// A row of the property column: panel color and the 1 pt row line of the lanes under it (v9 `.krow`, `.kl`); group
/// rows add a hairline at the top (`.grp`).
class RowBackground: NSView {
    var fill: NSColor = Theme.Colors.panel
    var topSeparator = false
    /// The row line continues the lane's line at the same y. Off for a row that is one element with the row under it.
    var bottomLine = true { didSet { if oldValue != bottomLine { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill(); bounds.fill()
        if bottomLine {
            Theme.Colors.trackRowLine.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
        guard topSeparator else { return }
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// Section row (v9 `.ksec`): chevron, title, summary value at the right (only while closed). The eye (bypass) and the
/// reset arrow appear while the pointer is over the row; the eye also stays while the effect is off, and both are in
/// the right-click menu. The chevron or a double-click opens and closes it; a click selects the effect, a drag reorders it.
final class SectionHeaderRow: RowBackground, RowUpdating, ControlsRowProbing {
    var rowProbe: ControlsRowProbe {
        ControlsRowProbe(toggle: chevron.frame, label: title.frame, tail: eye.frame.union(reset.frame))      // both slots stay reserved while hidden
    }
    let section: EffectSection
    let model: EffectControlsModel
    let chevron: IconButton
    let title: NSTextField
    let eye: IconButton
    let summary = makeLabel("", font: Theme.Typography.caption, color: Theme.Colors.label3)
    /// The open state this row was built for. The summary follows it, so it appears and disappears with the body rows.
    let builtCollapsed: Bool
    let reset: IconButton
    /// FB-W: shown when the effect's kind has a user default.
    private let defaultMarker = NSImageView()
    private var lastSelected = false
    private var lastOn: Bool?
    private var lastMixed = false

    init(section: EffectSection, model: EffectControlsModel) {
        self.section = section; self.model = model
        let collapsed = model.collapsedSections.contains(section)
        builtCollapsed = collapsed
        chevron = IconButton(symbol: collapsed ? .chevronRight : .chevronDown,
                                label: SQL10n.format(collapsed ? "Expand %@" : "Collapse %@", SQL10n.string(section.title))) {
            if model.collapsedSections.contains(section) { model.collapsedSections.remove(section) }
            else { model.collapsedSections.insert(section) }
        }
        chevron.setSymbol(collapsed ? .chevronRight : .chevronDown, tint: Theme.Colors.label3, size: Theme.Typography.symbolSmall)
        chevron.fillsWhenPressed = false
        title = makeLabel(section.title, font: Theme.Typography.bodyStrong, color: Theme.Colors.label)
        eye = IconButton(symbol: .eye, label: SQL10n.format("Disable %@", SQL10n.string(section.title))) { model.toggleEffectEnabled(section) }
        reset = IconButton(symbol: .reset, label: SQL10n.format("Reset %@", SQL10n.string(section.title))) { model.resetSection(section) }
        super.init(frame: .zero)
        summary.alignment = .right
        addSubview(chevron); addSubview(title); addSubview(summary); addSubview(reset)
        if model.hasFXToggle(section) { addSubview(eye) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self))
        defaultMarker.image = Theme.symbol(.bookmarkFilled, size: Theme.Typography.symbolSmall, label: "Your default")
        defaultMarker.contentTintColor = Theme.Colors.label3
        defaultMarker.sqToolTip = Tooltip.text("Your Default", shortcut: nil)
        defaultMarker.setAccessibilityLabel("Uses your default")
        if section.effectKind != nil { addSubview(defaultMarker) }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Pointer over the row: eye and reset show.
    var isHovering = false { didSet { if oldValue != isHovering { applyTailVisibility() } } }
    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    private func applyTailVisibility() {
        // Eye and reset are always shown in their fixed slots (feedback 2026-10-11); dim at rest, full while the pointer is over the row.
        let a: CGFloat = isHovering ? 1 : 0.55
        if eye.alphaValue != a { eye.alphaValue = a; reset.alphaValue = a }
    }

    override func layout() {
        super.layout()
        // Grid: chevron in the toggle column, title in the label column, switch and reset in the tail.
        let h = bounds.height, grid = ControlsGrid(width: bounds.width)
        chevron.frame = grid.headerToggleFrame(height: h)
        reset.frame = grid.resetFrame(height: h)
        eye.frame = NSRect(x: grid.resetX - ControlsGrid.gap - ControlsGrid.resetWidth, y: 0, width: ControlsGrid.resetWidth, height: h)
        let titleX = ControlsGrid.headerLabelX
        // Eye and reset have fixed slots that stay reserved while the icons are hidden: the summary never moves on hover.
        let rightX = eye.frame.minX - ControlsGrid.gap
        let markerW: CGFloat = defaultMarker.isHidden ? 0 : 14
        let lh = ControlsGrid.labelHeight, ly = ((h - lh) / 2).rounded()
        let titleW = min(ceil(title.attributedStringValue.size().width) + 4, max(rightX - titleX - markerW, 0))
        title.frame = NSRect(x: titleX, y: ly, width: titleW, height: lh)
        defaultMarker.frame = NSRect(x: titleX + titleW + 2, y: 0, width: 10, height: h)
        let sumX = titleX + titleW + markerW + ControlsGrid.gap
        summary.frame = NSRect(x: sumX, y: ly, width: max(rightX - sumX, 0), height: lh)
    }

    private var downPoint: NSPoint?
    private var reordering = false

    private var owner: EffectControlsView? {
        var v: NSView? = self
        while let x = v, !(x is EffectControlsView) { v = x.superview }
        return v as? EffectControlsView
    }

    func toggleCollapsed() {
        if model.collapsedSections.contains(section) { model.collapsedSections.remove(section) }
        else { model.collapsedSections.insert(section) }
    }

    override func mouseDown(with event: NSEvent) {
        model.selectEffectHeader(section)
        if let o = owner { window?.makeFirstResponder(o) }
        if event.clickCount == 2 { toggleCollapsed(); return }
        downPoint = event.locationInWindow
        reordering = false
        // No super: the click is handled here; passing it up would reach the panel background and clear the selection.
    }

    /// Dragging an effect header up or down reorders the effects (the list order is the order they are applied in).
    override func mouseDragged(with event: NSEvent) {
        guard section.effectKind != nil, let down = downPoint else { return }
        if !reordering, abs(event.locationInWindow.y - down.y) > 4 { reordering = true }
        if reordering { owner?.reorderMoved(section, windowPoint: event.locationInWindow) }
    }

    override func mouseUp(with event: NSEvent) {
        if reordering { owner?.reorderEnded(section) }
        reordering = false
        downPoint = nil
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) { SQContextMenu.show(items: contextItems(), for: event, in: self) }

    func contextItems() -> [SQMenuItem] {
        model.selectedSection = section
        var m: [SQMenuItem] = []
        let section = self.section
        // `shortcut` is only shown (the panel handles the keys itself: Cmd+X/C/V via the Edit menu, Delete in `keyDown`).
        func item(_ t: String, shortcut: String = "", enabled: Bool = true, _ run: @escaping @MainActor (EffectControlsModel) -> Void) -> SQMenuItem {
            SQMenuItem(title: t, shortcut: shortcut, isEnabled: enabled) { [model] in run(model) }
        }
        // Order (INTERACTION-AUDIT section 5): edit group, then the effect's own actions, then the destructive ones last.
        let removable = model.canRemoveEffect(section)
        if removable { m.append(item("Cut", shortcut: "\u{2318}X") { $0.cutEffect(section) }) }
        if model.canCopyEffect(section) { m.append(item("Copy", shortcut: "\u{2318}C") { if $0.copyEffect(section) { $0.markEffectCopied() } }) }
        if model.canPasteEffect { m.append(item("Paste", shortcut: "\u{2318}V") { $0.pasteEffect() }) }
        if removable { m.append(item("Duplicate Effect") { $0.duplicateEffect(section) }) }
        if !m.isEmpty { m.append(.separator) }
        if model.hasFXToggle(section) {
            let on = model.isEffectEnabled(section) && !model.isEffectEnabledMixed(section)
            m.append(item(on ? "Disable Effect" : "Enable Effect") { $0.toggleEffectEnabled(section) })
        }
        m.append(item(SQL10n.format(model.hasUserDefault(section) ? "Reset %@ to Your Default" : "Reset %@", SQL10n.string(section.title))) { $0.resetSection(section) })
        // FB-W: user defaults of the effect's kind.
        if model.canUseAsDefault(section) {
            m.append(.separator)
            m.append(item("Use as Default") { $0.useAsDefault(section) })
            if model.effectIsAnimated(section) {
                m.append(item("Use as Default Without Keyframes") { $0.useAsDefault(section, keepKeyframes: false) })
            }
            m.append(item("Reset Default to Factory", enabled: model.hasUserDefault(section)) { $0.resetDefaultToFactory(section) })
        }
        if section.effectKind != nil {
            m.append(.separator)
            m.append(item("Convert to Keyframes", enabled: model.canConvertToKeyframes(section)) { $0.convertToKeyframes(section) })
        } else if section == .motion {
            m.append(.separator)
            m.append(item(model.reopenTitle, enabled: model.canReopenAsEffect) { $0.reopenAsEffect() })
        }
        let isMask: Bool = { if case .mask = section { return true } else { return false } }()
        if removable || isMask { m.append(.separator) }
        if removable && !isMask { m.append(item("Delete", shortcut: "\u{232B}") { $0.removeEffect(section) }) }
        if isMask { m.append(item("Delete Mask") { if case .mask(let id) = section { $0.removeMask(id) } }) }
        return m
    }

    func update() {
        let on = model.isEffectEnabled(section)
        // Multi-select, on in some clips and off in others: a dash, like a mixed checkbox; a click turns all on.
        let mixed = model.isEffectEnabledMixed(section)
        if on != lastOn || mixed != lastMixed {
            lastOn = on; lastMixed = mixed
            eye.setSymbol(mixed ? .minus : on ? .eye : .eyeOff, tint: Theme.Colors.label3)
            let l = SQL10n.format(mixed ? "Enable %@ on All Selected Clips" : on ? "Disable %@" : "Enable %@", SQL10n.string(section.title))
            eye.sqToolTip = Tooltip.text(l, shortcut: nil)
            eye.setAccessibilityLabel(l)
        }
        applyTailVisibility()
        let text = model.sectionSummary(section, collapsed: builtCollapsed) ?? ""
        if summary.stringValue != text { summary.stringValue = text }
        let selected = model.isSectionSelected(section)
        if selected != lastSelected { lastSelected = selected; fill = selected ? Theme.Selection.fill : Theme.Colors.panel; needsDisplay = true }
        reset.isEnabled = section.properties.contains { !model.isDefault($0) } || !on
        let user = model.hasUserDefault(section)
        reset.sqToolTip = Tooltip.text(SQL10n.format(user ? "Reset %@ to Your Default" : "Reset %@", SQL10n.string(section.title)), shortcut: nil)
        if defaultMarker.isHidden == user { defaultMarker.isHidden = !user; needsLayout = true }
        title.textColor = on ? Theme.Colors.label : Theme.Colors.label3
        if case .mask(let id) = section, let m = model.clip?.mask(id), title.stringValue != m.name { title.stringValue = m.name }
    }
}

/// VIDEO / AUDIO group label (`.grp`): 22 pt, small caps, a line above every one but the first.
final class GroupHeaderRow: RowBackground, RowUpdating {
    let label: NSTextField
    init(title: String, first: Bool) {
        label = makeLabel(title.uppercased(), font: Theme.Typography.captionStrong, color: Theme.Colors.label3)
        super.init(frame: .zero)
        topSeparator = !first
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: ControlsMetrics.sectionLeading, y: (bounds.height - 13) / 2,
                             width: max(bounds.width - 2 * ControlsMetrics.sectionLeading, 0), height: 13)
    }
    func update() {}
}

private final class PlaceholderRow: RowBackground, RowUpdating {
    private let l: NSTextField
    init(title: String) {
        l = makeLabel("Not available yet", color: Theme.Colors.label3)
        super.init(frame: .zero)
        addSubview(l)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let grid = ControlsGrid(width: bounds.width)
        l.frame = grid.labelFrame(height: bounds.height, maxX: grid.tailMaxX + ControlsGrid.gap)
    }
    func update() {}
}

/// Parameter row (`.kp`): animate diamond, label, values right aligned, key navigation and Open at the right (only
/// while the parameter has keys). A selected row (click on its label) is highlighted.
final class PropertyRow: RowBackground, RowUpdating, ControlsRowProbing {
    let property: EffectProperty
    let model: EffectControlsModel
    private weak var owner: EffectControlsView?
    let keyframes: ParameterKeyControls
    private let name: NSTextField
    private(set) var fields: [ScrubField] = []

    init(property p: EffectProperty, model: EffectControlsModel, owner: EffectControlsView) {
        property = p; self.model = model; self.owner = owner
        keyframes = ParameterKeyControls(propertyName: p.title,
                                         onAnimate: { [weak owner] in owner?.animateTapped(p) },
                                         onPrevious: { model.goToPreviousKey(p) },
                                         onToggleKey: { model.toggleKeyAtPlayhead(p) },
                                         onNext: { model.goToNextKey(p) },
                                         onOpen: p.hasGraph ? { model.toggleOpen(p) } : nil,
                                         onReset: { model.resetAll(p) })
        name = makeLabel(p.title)
        super.init(frame: .zero)
        keyframes.install(in: self); addSubview(name)
        let comps: [EffectComponent] = Self.components(p, model: model)
        formatPicture = model.displayPicture
        for c in comps {
            let f = ScrubField(frame: .zero)
            Self.applyFormat(to: f, property: p, picture: model.displayPicture)
            f.isPlain = true; f.leadingText = true      // board `.hv`: plain accent numbers; the capsule shows while typing
            if p == .rotation {      // turns + degrees from 360 up ("1x 30.0°"), typing "1x30" or "390" both work
                f.valueFormatter = { RotationText.format($0) }
                f.valueParser = { [weak f] text in RotationText.parse(text, current: f.map { $0.isMixed ? 0 : $0.value } ?? 0) }
            }
            f.setAccessibilityLabel(comps.count == 2 ? "\(p.title) \(Self.componentName(p, c))" : p.title)
            f.onBegin = { model.beginGesture() }
            f.onChange = { v in model.setValue(p, component: c, to: p.native(fromDisplay: v, component: c, picture: model.displayPicture)) }
            f.onEnd = { _ in model.endGesture() }
            f.onReset = { _ = model.reset(p) }      // R25: double-click = the reset arrow (whole row, keys removed)
            fields.append(f); addSubview(f)
        }
        if p.pair?.linkable == true || p == .scale {
            link = SQButton(symbol: .link, label: "Link Width and Height", target: self, action: #selector(linkToggled), size: 11)
            link?.boxHeight = Theme.Row.control
            link?.horizontalPadding = 0
            addSubview(link!)
        }
        if EffectControlsModel.isKeyHue(p) {      // Color Key: pick the key color from the Program monitor
            let b = SQButton(symbol: .eyedropper, label: "Pick Key Color from Monitor", target: self, action: #selector(pickTapped), size: 11)
            b.boxHeight = Theme.Row.control
            b.horizontalPadding = 0
            pick = b
            addSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Key Hue only: the eyedropper next to the field.
    private var pick: SQButton?
    @objc private func pickTapped() { model.pickKeyColor(property) }

    /// Transform Scale only (P5): linked = one value for Width and Height. Off = Width and Height fields.
    private var link: SQButton?
    /// The Motion Scale row links through `uniformScale`; a Transform effect's Scale through its stored pair.
    private var isLinkedNow: Bool { property == .scale ? model.uniformScale : model.isLinked(property) }
    @objc private func linkToggled() {
        if property == .scale { model.setUniformScale(!model.uniformScale) } else { model.setLinked(property, !model.isLinked(property)) }
    }

    /// Scale shows Width and Height while its link is off; positions always show X and Y.
    static func components(_ p: EffectProperty, model: EffectControlsModel) -> [EffectComponent] { model.valueComponents(p) }
    static func componentName(_ p: EffectProperty, _ c: EffectComponent) -> String {
        if p == .scale || p.pair?.linkable == true { return c == .x ? "Width" : "Height" }
        return c == .x ? "X" : "Y"
    }

    /// Click on the label selects the row and all its keyframes (Shift / Cmd adds the row: several rows selected are
    /// eased together); any click on the row focuses the property.
    override func mouseDown(with event: NSEvent) {
        model.focusedProperty = property
        if let o = owner { window?.makeFirstResponder(o) }
        if name.frame.contains(convert(event.locationInWindow, from: nil)) {
            let flags = event.modifierFlags
            model.selectPropertyRow(property, extend: flags.contains(.shift) || flags.contains(.command))
        } else {
            model.clearRowSelection()      // a click elsewhere on the row clears; only the label selects
        }
        // No super: the click is handled here; passing it up would reach the panel background and clear the selection.
    }

    override func layout() {
        super.layout()
        // Grid: label column, then one value column per field; the link button takes the column after them.
        let h = bounds.height, grid = ControlsGrid(width: bounds.width)
        for (i, f) in fields.enumerated() { f.frame = grid.valueFrame(i, height: h) }
        if let link {
            link.frame = grid.controlFrame(x: ControlsGrid.valueColumn(fields.count), width: ControlsGrid.controlHeight, height: h)
        }
        if let pick {
            pick.frame = grid.controlFrame(x: ControlsGrid.valueColumn(fields.count), width: ControlsGrid.controlHeight, height: h)
        }
        grid.place(name, height: h)
        keyframes.layout(rowBounds: bounds)
    }

    var rowProbe: ControlsRowProbe {
        ControlsRowProbe(toggle: keyframes.diamond.frame, label: name.frame,
                         controls: fields.map(\.frame) + (link.map { [$0.frame] } ?? []) + (pick.map { [$0.frame] } ?? []),
                         tail: keyframes.tailFrame)
    }

    // Right-click: reset at the playhead and, separately, reset all (drops the keyframes).
    override func rightMouseDown(with event: NSEvent) { SQContextMenu.show(items: contextItems(), for: event, in: self) }

    func contextItems() -> [SQMenuItem] {
        let animated = model.isAnimated(property)
        var m: [SQMenuItem] = []
        if animated {
            // The key navigation of the row (shown on hover) is also here.
            let st = keyframes.state
            m.append(SQMenuItem(title: st.keyIsOn ? "Remove Keyframe" : "Add Keyframe", isEnabled: st.canToggleKey) { [model, property] in _ = model.toggleKeyAtPlayhead(property) })
            m.append(SQMenuItem(title: "Go to Previous Keyframe", isEnabled: st.canGoPrevious) { [model, property] in model.goToPreviousKey(property) })
            m.append(SQMenuItem(title: "Go to Next Keyframe", isEnabled: st.canGoNext) { [model, property] in model.goToNextKey(property) })
            m.append(.separator)
            m.append(SQMenuItem(title: "Reset at Playhead", isEnabled: model.playheadInClip) { [model, property] in model.resetAtPlayhead(property) })
        }
        m.append(SQMenuItem(title: animated ? "Reset All (Remove Keyframes)" : "Reset", isEnabled: !model.isDefault(property)) { [model, property] in model.resetAll(property) })
        m.append(.separator)
        m.append(model.graphEditorMenuItem())
        if model.canResetToAutomatic(property) {      // a variant is active and overrides this property
            m.append(.separator)
            m.append(SQMenuItem(title: "Reset to Automatic") { [model, property] in model.resetToAutomatic(property) })
        }
        return m
    }

    /// Range, step, unit and decimals of a field. Crop rows depend on the picture size (px vs percent).
    private static func applyFormat(to f: ScrubField, property p: EffectProperty, picture pic: Vec2?) {
        f.range = p.displayRange(picture: pic)
        f.step = p.displayStep(picture: pic)
        f.unit = p.displayUnit(picture: pic)
        f.decimals = p.displayDecimals(picture: pic)
    }
    private var formatPicture: Vec2?

    func update() {
        let p = property
        let animated = model.isAnimated(p)
        if p.pictureDependent {      // the clip changed: another picture size, so another px scale
            let pic = model.displayPicture
            if pic != formatPicture { formatPicture = pic; fields.forEach { Self.applyFormat(to: $0, property: p, picture: pic) } }
        }
        keyframes.state = model.keyframeControlState(p)
        keyframes.navigation.isOpen = model.expanded.contains(p)
        keyframes.reset?.isEnabled = !model.isDefault(p)
        fields.forEach { $0.isAnimated = animated }
        if let link {
            let on = isLinkedNow
            link.image = Theme.symbol(on ? .link : .unlink, size: 11, label: "Link Width and Height")
            link.contentTintColor = on ? Theme.Colors.accent : Theme.Colors.label3
            link.sqToolTip = Tooltip.text(on ? "Unlink Width and Height" : "Link Width and Height", shortcut: nil)
        }
        if fields.count == 2 {
            let v = model.vectorValue(p)
            set(fields[0], p.display(v.x, component: .x, picture: model.displayPicture))
            set(fields[1], p.display(v.y, component: .y, picture: model.displayPicture))
            fields[0].isMixed = model.isMixed(p, component: .x); fields[1].isMixed = model.isMixed(p, component: .y)
        } else {
            set(fields[0], p.display(model.scalarValue(p), picture: model.displayPicture))
            fields[0].isMixed = model.isMixed(p)      // multi-select, differing values: empty field
        }
        // Graph Editor: value fields carry the curve color.
        let slot = model.graphEditor ? model.graphColorSlot(p) : nil
        let tint = slot.map { GraphEditorView.palette[$0 % GraphEditorView.palette.count] }
        fields.forEach { $0.curveTint = tint }
        // `.kp.sel`: a selected row.
        // Open curve: the name row and the preset pane under it are one lighter element (the pane color).
        let opened = model.expanded.contains(p) && p.hasGraph && !model.graphEditor
        let rowFill = model.graphProperties.contains(p) ? Theme.Colors.selection : (opened ? ControlsColors.paneFill : Theme.Colors.panel)
        if fill != rowFill { fill = rowFill; needsDisplay = true }
        bottomLine = !opened
    }

    var tintedCount: Int { fields.filter { $0.curveTint != nil }.count }

    private func set(_ f: ScrubField, _ v: Double) {
        if !f.isDragging && !f.isEditing && f.value != v { f.value = v }
    }
}

/// Rows of the Speed section: Speed (percent field, right aligned like a parameter) and the Reverse / Keep Pitch checkboxes.
private final class SpeedControlRow: RowBackground, RowUpdating, ControlsRowProbing {
    var rowProbe: ControlsRowProbe {
        let shown = keyframes.flatMap { $0.diamond.isHidden ? nil : $0 }
        return ControlsRowProbe(toggle: shown?.diamond.frame, label: label.frame, controls: [kind == .speed ? field.frame : box.frame],
                                tail: keyframes?.tailFrame)
    }
    let kind: SpeedControl
    let model: EffectControlsModel
    private let label: NSTextField
    private let box = SQCheckbox(target: nil, action: nil)
    private let field = ScrubField(frame: .zero)
    /// Speed row only: the same diamond and previous / next key controls as every keyframable row (speed keys).
    private let keyframes: ParameterKeyControls?

    private var curvePopover: SQPopover?

    init(kind: SpeedControl, model: EffectControlsModel) {
        self.kind = kind; self.model = model
        let anchor = SpeedCurveAnchor()
        let title = kind == .speed ? "Speed" : kind == .reverse ? "Reverse" : "Keep Pitch"
        label = makeLabel(title)
        keyframes = kind == .speed
            ? ParameterKeyControls(propertyName: title, onAnimate: { if model.toggleSpeedAnimation() == .needsConfirmation, EffectControlsView.confirmRemoveKeyframes(title: "Speed") { model.toggleSpeedAnimation(confirmRemoval: true) } },
                                   onPrevious: { model.goToPreviousSpeedKey() }, onToggleKey: { model.toggleSpeedKeyAtPlayhead() },
                                   onNext: { model.goToNextSpeedKey() },
                                   onOpen: { anchor.open?() },
                                   onReset: {
                                       if model.speedIsAnimated { _ = model.toggleSpeedAnimation(confirmRemoval: true) }
                                       model.setSpeedPercent(100)
                                   })
            : nil
        super.init(frame: .zero)
        anchor.open = { [weak self] in self?.showCurve() }
        keyframes?.install(in: self)
        addSubview(label)
        if kind == .speed {
            field.range = 1...10000; field.step = 1; field.decimals = 1; field.unit = "%"; field.defaultValue = 100
            field.isPlain = true
            field.setAccessibilityLabel("Speed")
            field.onBegin = { [weak model] in model?.beginSpeedGesture() }
            field.onChange = { [weak model] v in model?.setSpeedPercent(v) }
            field.onEnd = { [weak model] _ in model?.endSpeedGesture() }
            field.onReset = { [weak model] in model?.setSpeedPercent(100) }
            addSubview(field)
        } else {
            box.target = self; box.action = #selector(toggled)
            box.sqToolTip = Tooltip.text(title, shortcut: nil)
            box.setAccessibilityLabel(title)
            addSubview(box)
        }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, grid = ControlsGrid(width: bounds.width)
        if kind == .speed {
            field.frame = grid.valueFrame(0, height: h)
            keyframes?.layout(rowBounds: bounds)
        } else {
            let s = Theme.Metrics.checkbox
            box.frame = grid.controlFrame(x: ControlsGrid.valueX, width: s, height: h, controlHeight: s)
        }
        grid.place(label, height: h)
    }
    /// The ease editor of the speed transition at the playhead (the popover every keyframe curve uses).
    private func showCurve() {
        guard let button = keyframes?.navigation.open, let source = model.speedCurveSource() else { return }
        curvePopover?.close()
        let pop = EasingCurvePopover.make(source: source)
        curvePopover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .maxX)
    }
    @objc private func toggled() {
        if kind == .reverse { model.setReversedClip(box.state == .on) } else { model.setKeepsPitchClip(box.state == .on) }
    }
    func update() {
        switch kind {
        case .speed:
            if !field.isDragging && !field.isEditing && field.value != model.speedPercent { field.value = model.speedPercent }
            keyframes?.state = model.speedKeysAvailable ? model.speedKeyControlState() : .off
            keyframes?.diamond.isHidden = !model.speedKeysAvailable
            keyframes?.navigation.showsOpen = model.speedHasTransition
            keyframes?.reset?.isEnabled = model.speedPercent != 100 || model.speedIsAnimated
            field.isAnimated = model.speedIsAnimated
        case .reverse: box.state = model.isReversed ? .on : .off
        case .keepPitch: box.state = model.keepsPitch ? .on : .off
        case .timeInterpolation: break
        }
    }
}

/// Lets the Speed row's key controls (built before the row exists) call back into the row.
@MainActor private final class SpeedCurveAnchor { var open: (() -> Void)? }

/// Blend Mode under the Opacity row: label at the left, popup right aligned (`.kp` with a popup, 28 pt).
private final class BlendModeRow: RowBackground, RowUpdating, ControlsRowProbing {
    var rowProbe: ControlsRowProbe { ControlsRowProbe(label: label.frame, controls: [popup.frame]) }
    let model: EffectControlsModel
    private let label = makeLabel("Blend Mode")
    private let popup = SQPopup(frame: .zero, pullsDown: false)

    init(model: EffectControlsModel) {
        self.model = model
        super.init(frame: .zero)
        popup.controlSize = .small
        popup.font = Theme.Typography.body
        // Sections (Normal, Darken, Lighten, Contrast, Inversion, Component) with a separator between them; the tag is the mode's
        // index in `allCases`.
        for (n, section) in BlendMode.menuSections.enumerated() {
            if n > 0 { popup.menu?.addItem(.separator()) }
            for m in section {
                let item = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
                item.tag = BlendMode.allCases.firstIndex(of: m) ?? 0
                popup.menu?.addItem(item)
            }
        }
        popup.target = self; popup.action = #selector(changed)
        popup.setAccessibilityLabel("Blend Mode")
        popup.sqToolTip = Tooltip.text("Blend Mode", shortcut: nil)
        addSubview(label); addSubview(popup)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let grid = ControlsGrid(width: bounds.width)
        popup.frame = grid.fillFrame(height: bounds.height, maxX: grid.valueMaxX, maxWidth: ControlsMetrics.popupWidth)
        grid.place(label, height: bounds.height)
    }
    @objc private func changed() {
        guard let i = popup.selectedItem?.tag, BlendMode.allCases.indices.contains(i) else { return }
        model.setBlendMode(BlendMode.allCases[i])
    }
    func update() {
        if model.isBlendModeMixed {
            // Multi-select, differing modes: nothing picked (empty popup), like a mixed number field.
            if popup.indexOfSelectedItem != -1 { popup.selectItem(at: -1) }
        } else if let i = BlendMode.allCases.firstIndex(of: model.blendMode), popup.selectedItem?.tag != i { popup.selectItem(withTag: i) }
        popup.isEnabled = model.isBlendGroupEnabled
    }
}

/// Speed section: how the frames between two source frames are filled (Repeat / Blend frames / Optical flow). The same choice and
/// the same session command as the Speed dialog's popup (`TimeInterpolation.allCases`, `title`).
final class TimeInterpolationRow: RowBackground, RowUpdating, ControlsRowProbing {
    var rowProbe: ControlsRowProbe { ControlsRowProbe(label: label.frame, controls: [popup.frame]) }
    let model: EffectControlsModel
    private let label = makeLabel("Frame Mode")
    let popup = SQPopup(frame: .zero, pullsDown: false)

    init(model: EffectControlsModel) {
        self.model = model
        super.init(frame: .zero)
        popup.controlSize = .small
        popup.font = Theme.Typography.body
        for t in TimeInterpolation.allCases { popup.addItem(withTitle: t.title) }
        popup.target = self; popup.action = #selector(changed)
        popup.setAccessibilityLabel("Frame Mode")
        popup.sqToolTip = Tooltip.text("Frame Mode", shortcut: nil)
        addSubview(label); addSubview(popup)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let grid = ControlsGrid(width: bounds.width)
        popup.frame = grid.fillFrame(height: bounds.height, maxX: grid.valueMaxX, maxWidth: ControlsMetrics.popupWidth)
        grid.place(label, height: bounds.height)
    }
    @objc private func changed() {
        let i = popup.indexOfSelectedItem
        guard TimeInterpolation.allCases.indices.contains(i) else { return }
        model.setTimeInterpolation(TimeInterpolation.allCases[i])
    }
    func update() {
        let i = TimeInterpolation.allCases.firstIndex(of: model.timeInterpolation) ?? 0
        if popup.indexOfSelectedItem != i { popup.selectItem(at: i) }
    }
}

/// W9.8: a subject mask under Opacity: Inverted, Mode and a delete button (no path, feather or handles: the shape is the
/// person matte of each frame). On the grid like `MaskControlsRow`: Inverted in the label column, Mode in value column 0,
/// delete in the tail column. The mask's name is the row's accessibility label.
final class SubjectMaskRow: RowBackground, RowUpdating, ControlsRowProbing {
    let maskID: ClipMask.ID
    let model: EffectControlsModel
    private let invert = SQCheckbox(title: "Inverted", target: nil, action: nil)
    private let popup = SQPopup(frame: .zero, pullsDown: false)
    private var remove: IconButton!

    var rowProbe: ControlsRowProbe { ControlsRowProbe(label: invert.frame, controls: [popup.frame], tail: remove.frame) }

    init(maskID: ClipMask.ID, model: EffectControlsModel) {
        self.maskID = maskID; self.model = model
        super.init(frame: .zero)
        invert.font = Theme.Typography.body
        invert.controlSize = .small
        invert.target = self; invert.action = #selector(inverted)
        invert.sqToolTip = Tooltip.text("Invert Subject Mask", shortcut: nil)
        invert.setAccessibilityLabel("Invert Subject Mask")
        popup.controlSize = .small
        popup.font = Theme.Typography.body
        for m in MaskMode.allCases { popup.addItem(withTitle: m.title) }
        popup.target = self; popup.action = #selector(modeChanged)
        popup.sqToolTip = Tooltip.text("Mask Mode", shortcut: nil)
        popup.setAccessibilityLabel("Mask Mode")
        remove = IconButton(symbol: .trash, label: "Delete Subject Mask") { [weak model] in model?.removeMask(maskID) }
        for v in [invert, popup, remove!] as [NSView] { addSubview(v) }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let grid = ControlsGrid(width: bounds.width), h = bounds.height
        invert.frame = grid.controlFrame(x: ControlsGrid.labelX, width: ControlsGrid.labelWidth, height: h)
        remove.frame = grid.controlFrame(x: grid.resetX, width: ControlsGrid.resetWidth, height: h)
        popup.frame = grid.fillFrame(height: h, maxX: remove.frame.minX - ControlsGrid.gap, maxWidth: Theme.Inspector.popupWidth)
    }
    @objc private func inverted() { model.setMaskInverted(maskID, invert.state == .on) }
    @objc private func modeChanged() {
        let i = popup.indexOfSelectedItem
        if MaskMode.allCases.indices.contains(i) { model.setMaskMode(maskID, MaskMode.allCases[i]) }
    }
    func update() {
        guard let m = model.clip?.mask(maskID) else { return }
        setAccessibilityLabel(m.name)
        invert.state = m.inverted ? .on : .off
        if let i = MaskMode.allCases.firstIndex(of: m.mode), popup.indexOfSelectedItem != i { popup.selectItem(at: i) }
        let on = model.isBlendGroupEnabled
        invert.isEnabled = on; popup.isEnabled = on
    }
}

/// W6.7: the first line under a path mask: Inverted, Mode and the Path stopwatch with key navigation (keys the whole shape).
/// Sized to fit the 300 pt panel minimum; tracking and delete live on `MaskTrackRow` below.
final class MaskControlsRow: RowBackground, RowUpdating, ControlsRowProbing {
    let maskID: ClipMask.ID
    let model: EffectControlsModel
    private let invert = SQCheckbox(title: "Inverted", target: nil, action: nil)
    private let popup = SQPopup(frame: .zero, pullsDown: false)
    private var path: KeyframeControls!

    var rowProbe: ControlsRowProbe {
        ControlsRowProbe(toggle: path.ring.isHidden ? nil : path.ring.frame, label: invert.frame, controls: [popup.frame],
                         tail: path.navigation.isHidden ? nil : path.navigation.frame)
    }

    /// `onStopwatch`: the Path stopwatch, through the panel's stopwatch (turning it off asks before the keys go).
    init(maskID: ClipMask.ID, model: EffectControlsModel, onStopwatch: @escaping @MainActor () -> Void) {
        self.maskID = maskID; self.model = model
        super.init(frame: .zero)
        invert.font = Theme.Typography.body
        invert.controlSize = .small
        invert.target = self; invert.action = #selector(inverted)
        invert.sqToolTip = Tooltip.text("Invert Mask", shortcut: nil)
        invert.setAccessibilityLabel("Invert Mask")
        popup.controlSize = .small
        popup.font = Theme.Typography.body
        for m in MaskMode.allCases { popup.addItem(withTitle: m.title) }
        popup.target = self; popup.action = #selector(modeChanged)
        popup.sqToolTip = Tooltip.text("Mask Mode", shortcut: nil)
        popup.setAccessibilityLabel("Mask Mode")
        path = KeyframeControls(propertyName: "Mask Path",
                                onToggleAnimation: onStopwatch,
                                onPrevious: { [weak model] in model?.goToPreviousMaskRowKey(maskID) },
                                onToggleKey: { [weak model] in model?.toggleMaskPathKeyAtPlayhead(maskID) },
                                onNext: { [weak model] in model?.goToNextMaskRowKey(maskID) })
        for v in [invert, popup] as [NSView] { addSubview(v) }
        path.install(in: self)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let grid = ControlsGrid(width: bounds.width), h = bounds.height
        // The Path ring in the toggle column, Inverted in the label column, Mode in the value column, key navigation in the tail.
        path.layout(rowBounds: bounds, ringX: ControlsGrid.toggleMidX - KeyframeToggleView.slot / 2, navigationMaxX: grid.resetX - ControlsGrid.gap)
        invert.frame = grid.controlFrame(x: ControlsGrid.labelX, width: ControlsGrid.labelWidth, height: h)
        popup.frame = grid.fillFrame(height: h, maxX: grid.valueMaxX, maxWidth: Theme.Inspector.popupWidth)
    }
    @objc private func inverted() { model.setMaskInverted(maskID, invert.state == .on) }
    @objc private func modeChanged() {
        let i = popup.indexOfSelectedItem
        if MaskMode.allCases.indices.contains(i) { model.setMaskMode(maskID, MaskMode.allCases[i]) }
    }
    func update() {
        guard let m = model.clip?.mask(maskID) else { return }
        invert.state = m.inverted ? .on : .off
        if let i = MaskMode.allCases.firstIndex(of: m.mode), popup.indexOfSelectedItem != i { popup.selectItem(at: i) }
        path.state = model.maskRowKeyframeState(maskID)
        let on = m.enabled
        invert.isEnabled = on; popup.isEnabled = on
        // A Magic mask has no path: its shape comes from the pick and Track.
        let magic = m.source == .magic || m.source == .picture
        path.ring.isHidden = magic
        // A Magic mask keeps previous / next: they step through its tracked frames (the keys on this row).
        path.navigation.isHidden = m.source == .picture || (m.source == .magic && model.magicKeys(maskID).isEmpty)
    }
}

/// The last line of a path mask: Track Backward / Forward (keys the path on every frame from the playhead), the Track
/// choice (Position / + Scale / + Rotation / Perspective, flexible width) and delete.
final class MaskTrackRow: RowBackground, RowUpdating, ControlsRowProbing {
    let maskID: ClipMask.ID
    let model: EffectControlsModel
    private var remove: IconButton!
    private var trackBack: IconButton!
    private var trackForward: IconButton!
    /// Magic masks only: one frame back / forward, Stop, and the state line (idle, tracking n of m, stopped).
    private var stepBack: IconButton!
    private var stepForward: IconButton!
    private var stopButton: IconButton!
    private let status = makeLabel("Idle")
    private let trackMode = SQPopup(frame: .zero, pullsDown: false)
    private let label = makeLabel("Track")
    private var isMagic: Bool { model.clip?.mask(maskID)?.source == .magic }

    var rowProbe: ControlsRowProbe {
        ControlsRowProbe(label: label.frame,
                         controls: [trackBack.frame, trackForward.frame] + (isMagic ? [stepBack.frame, stepForward.frame, stopButton.frame] : [])
                            + (trackMode.isHidden ? [] : [trackMode.frame]),
                         tail: remove.frame)
    }

    init(maskID: ClipMask.ID, model: EffectControlsModel) {
        self.maskID = maskID; self.model = model
        super.init(frame: .zero)
        remove = IconButton(symbol: .trash, label: "Delete Mask") { [weak model] in model?.removeMask(maskID) }
        trackBack = IconButton(symbol: .stepBack, label: "Track Mask Backward") { [weak model] in
            model?.onTrackMask?(maskID, false)
        }
        trackForward = IconButton(symbol: .stepForward, label: "Track Mask Forward") { [weak model] in
            model?.onTrackMask?(maskID, true)
        }
        trackBack.sqToolTip = Tooltip.text("Track Mask Backward (click again to stop)", shortcut: nil)
        trackForward.sqToolTip = Tooltip.text("Track Mask Forward (click again to stop)", shortcut: nil)
        stepBack = IconButton(symbol: .chevronLeft, label: "Track One Frame Back") { [weak model] in
            model?.onTrackMagic?(maskID, .step(forward: false))
        }
        stepForward = IconButton(symbol: .chevronRight, label: "Track One Frame Forward") { [weak model] in
            model?.onTrackMagic?(maskID, .step(forward: true))
        }
        stopButton = IconButton(symbol: .stop, label: "Stop Tracking") { [weak model] in model?.onTrackMagic?(maskID, nil) }
        stepBack.sqToolTip = Tooltip.text("Track One Frame Back", shortcut: nil)
        stepForward.sqToolTip = Tooltip.text("Track One Frame Forward", shortcut: nil)
        stopButton.sqToolTip = Tooltip.text("Stop Tracking", shortcut: nil)
        status.font = Theme.Typography.caption
        status.textColor = Theme.Colors.label2
        status.lineBreakMode = .byTruncatingTail
        trackMode.controlSize = .small
        trackMode.font = Theme.Typography.body
        for m in MaskTrackMode.allCases { trackMode.addItem(withTitle: m.title) }
        trackMode.target = self; trackMode.action = #selector(trackModeChanged)
        trackMode.sqToolTip = Tooltip.text("What tracking follows", shortcut: nil)
        trackMode.setAccessibilityLabel("Track")
        for v in [label, trackBack!, trackForward!, stepBack!, stepForward!, stopButton!, status, trackMode, remove!] as [NSView] { addSubview(v) }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let grid = ControlsGrid(width: bounds.width), h = bounds.height
        grid.place(label, height: h)
        remove.frame = grid.controlFrame(x: grid.resetX, width: ControlsGrid.resetWidth, height: h)
        if isMagic {
            // One frame back, back to the start, Stop, on to the end, one frame forward, then the state line.
            var x = ControlsGrid.valueX
            for b in [stepBack!, trackBack!, stopButton!, trackForward!, stepForward!] {
                b.frame = grid.controlFrame(x: x, width: ControlsGrid.controlHeight, height: h)
                x = b.frame.maxX + ControlsGrid.gap
            }
            status.frame = grid.controlFrame(x: x, width: max(remove.frame.minX - ControlsGrid.gap - x, 0), height: h)
            return
        }
        trackBack.frame = grid.controlFrame(x: ControlsGrid.valueX, width: ControlsGrid.controlHeight, height: h)
        trackForward.frame = grid.controlFrame(x: trackBack.frame.maxX + ControlsGrid.gap, width: ControlsGrid.controlHeight, height: h)
        let tx = trackForward.frame.maxX + ControlsGrid.gap
        trackMode.frame = grid.controlFrame(x: tx, width: min(remove.frame.minX - ControlsGrid.gap - tx, Theme.Inspector.popupWidth), height: h)
    }
    @objc private func trackModeChanged() {
        let i = trackMode.indexOfSelectedItem
        if MaskTrackMode.allCases.indices.contains(i) { model.maskTrackMode = MaskTrackMode.allCases[i] }
    }
    func update() {
        guard let m = model.clip?.mask(maskID) else { return }
        let on = m.enabled
        if m.source == .magic {
            let c = MaskTrackActivity.shared.magic
            let ready = on && model.playheadInClip && !c.isTracking
            trackBack.setSymbol(.goToStart, tint: Theme.Colors.label2)
            trackForward.setSymbol(.goToEnd, tint: Theme.Colors.label2)
            for b in [stepBack!, trackBack!, trackForward!, stepForward!] { b.isEnabled = ready }
            stopButton.isEnabled = c.isTracking
            stopButton.setSymbol(.stop, tint: c.isTracking ? Theme.Colors.accent : Theme.Colors.label2)
            status.stringValue = c.statusText
            for b in [stepBack!, stepForward!, stopButton!] as [NSView] { b.isHidden = false }
            status.isHidden = false
            trackMode.isHidden = true
            trackBack.sqToolTip = Tooltip.text("Track Backward to the Start", shortcut: nil)
            trackForward.sqToolTip = Tooltip.text("Track Forward to the End", shortcut: nil)
            needsLayout = true
            return
        }
        for b in [stepBack!, stepForward!, stopButton!, status] as [NSView] { b.isHidden = true }
        // While a track runs (even from another playhead position) its button is a Stop button with the progress.
        let run = MaskTrackActivity.shared.run
        let mine = run?.mask == maskID ? run : nil
        let ready = on && model.playheadInClip && run == nil
        trackBack.isEnabled = mine.map { !$0.forward } ?? ready
        trackForward.isEnabled = mine.map(\.forward) ?? ready
        let stop = { (b: IconButton) in b.setSymbol(.stop, tint: Theme.Colors.accent) }
        if let mine {
            stop(mine.forward ? trackForward : trackBack)
            label.stringValue = mine.percent >= 0 ? "\(mine.percent)%" : "…"
        } else {
            trackBack.setSymbol(.stepBack, tint: Theme.Colors.label2)
            trackForward.setSymbol(.stepForward, tint: Theme.Colors.label2)
            label.stringValue = "Track"
        }
        if let i = MaskTrackMode.allCases.firstIndex(of: model.maskTrackMode), trackMode.indexOfSelectedItem != i {
            trackMode.selectItem(at: i)
        }
        trackMode.isEnabled = on
        // Magic follows the picked object itself; the Track choice is for path masks.
        trackMode.isHidden = m.source == .magic
        let tip = m.source == .magic ? "Track Magic Mask" : "Track Mask"
        trackBack.sqToolTip = Tooltip.text("\(tip) Backward (click again to stop)", shortcut: nil)
        trackForward.sqToolTip = Tooltip.text("\(tip) Forward (click again to stop)", shortcut: nil)
    }
}

/// C6: "Picture of [V3 \u{2013} clip] [Shape | Brightness]" and delete: the line of a Picture mask (no path, no tracking).
final class PictureMaskRow: RowBackground, RowUpdating, ControlsRowProbing {
    let maskID: ClipMask.ID
    let model: EffectControlsModel
    private let label = makeLabel("Picture of")
    let trackPopup = SQPopup(frame: .zero, pullsDown: false)
    let channelPopup = SQPopup(frame: .zero, pullsDown: false)
    private var remove: IconButton!
    private var choices: [PictureTrackChoice] = []

    var rowProbe: ControlsRowProbe {
        ControlsRowProbe(label: label.frame, controls: [trackPopup.frame, channelPopup.frame], tail: remove.frame)
    }

    init(maskID: ClipMask.ID, model: EffectControlsModel) {
        self.maskID = maskID; self.model = model
        super.init(frame: .zero)
        remove = IconButton(symbol: .trash, label: "Delete Mask") { [weak model] in model?.removeMask(maskID) }
        for p in [trackPopup, channelPopup] { p.controlSize = .small; p.font = Theme.Typography.body }
        trackPopup.target = self; trackPopup.action = #selector(trackChanged)
        trackPopup.sqToolTip = Tooltip.text("The track whose picture is the mask", shortcut: nil)
        trackPopup.setAccessibilityLabel("Mask Track")
        for c in MatteChannel.allCases { channelPopup.addItem(withTitle: c.title) }
        channelPopup.target = self; channelPopup.action = #selector(channelChanged)
        channelPopup.sqToolTip = Tooltip.text("Shape: where the picture is. Brightness: how bright it is", shortcut: nil)
        channelPopup.setAccessibilityLabel("Mask Channel")
        for v in [label, trackPopup, channelPopup, remove!] as [NSView] { addSubview(v) }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let grid = ControlsGrid(width: bounds.width), h = bounds.height
        grid.place(label, height: h)
        remove.frame = grid.controlFrame(x: grid.resetX, width: ControlsGrid.resetWidth, height: h)
        let cw = Theme.Inspector.channelWidth
        channelPopup.frame = grid.controlFrame(x: remove.frame.minX - ControlsGrid.gap - cw, width: cw, height: h)
        trackPopup.frame = grid.fillFrame(height: h, maxX: channelPopup.frame.minX - ControlsGrid.gap)
    }
    @objc private func trackChanged() {
        let i = trackPopup.indexOfSelectedItem
        if choices.indices.contains(i) { model.setMaskPictureTrack(maskID, choices[i].track) }
    }
    @objc private func channelChanged() {
        let i = channelPopup.indexOfSelectedItem
        if MatteChannel.allCases.indices.contains(i) { model.setMaskPictureChannel(maskID, MatteChannel.allCases[i]) }
    }
    func update() {
        guard let m = model.clip?.mask(maskID) else { return }
        let fresh = model.pictureTrackChoices()
        // The items are rebuilt only when the tracks change: the clip name under the playhead is a tooltip, so an
        // open popup is not reset while the playhead moves.
        if fresh.map({ [$0.track?.uuidString ?? "", $0.lane ?? ""] }) != choices.map({ [$0.track?.uuidString ?? "", $0.lane ?? ""] }) {
            trackPopup.removeAllItems()
            for c in fresh { trackPopup.addItem(withTitle: c.lane ?? c.title) }
        }
        if fresh != choices {
            choices = fresh
            for (i, c) in fresh.enumerated() where trackPopup.numberOfItems > i {
                trackPopup.item(at: i)?.sqHelp = c.lane == nil || c.title == c.lane ? nil : c.title
            }
        }
        let sel = model.pictureTrackSelection(maskID, in: choices)
        if trackPopup.indexOfSelectedItem != sel { trackPopup.selectItem(at: sel) }
        if let i = MatteChannel.allCases.firstIndex(of: m.pictureChannel), channelPopup.indexOfSelectedItem != i { channelPopup.selectItem(at: i) }
        trackPopup.isEnabled = m.enabled; channelPopup.isEnabled = m.enabled
    }
}

/// How a mask is used: "Cuts picture" (Opacity) and "Use in" (the picture effects it limits, checked when on).
final class MaskUseRow: RowBackground, RowUpdating, ControlsRowProbing {
    let maskID: ClipMask.ID
    let model: EffectControlsModel
    private let cuts = SQCheckbox(title: "", target: nil, action: nil)
    private let label = makeLabel("Cuts picture")
    private let useIn = SQPopup(frame: .zero, pullsDown: true)
    private var choices: [ClipEffect.ID] = []
    private var shown: [String] = []

    var rowProbe: ControlsRowProbe { ControlsRowProbe(toggle: cuts.frame, label: label.frame, controls: [useIn.frame]) }

    init(maskID: ClipMask.ID, model: EffectControlsModel) {
        self.maskID = maskID; self.model = model
        super.init(frame: .zero)
        cuts.font = Theme.Typography.body
        cuts.controlSize = .small
        cuts.target = self; cuts.action = #selector(cutsChanged)
        cuts.sqToolTip = Tooltip.text("The mask cuts out the clip's picture (off: it only limits the effects that use it)", shortcut: nil)
        cuts.setAccessibilityLabel("Mask cuts picture")
        useIn.controlSize = .small
        useIn.font = Theme.Typography.body
        useIn.target = self; useIn.action = #selector(useInPicked)
        useIn.sqToolTip = Tooltip.text("Effects that only work inside this mask", shortcut: nil)
        useIn.setAccessibilityLabel("Use mask in effects")
        addSubview(cuts); addSubview(label); addSubview(useIn)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let grid = ControlsGrid(width: bounds.width), h = bounds.height
        cuts.frame = grid.toggleBox(ControlsGrid.toggleWidth, height: h)
        grid.place(label, height: h)
        useIn.frame = grid.fillFrame(height: h, maxWidth: Theme.Inspector.popupWidth)
    }
    @objc private func cutsChanged() { model.setMask(maskID, usedByOpacity: cuts.state == .on) }
    @objc private func useInPicked() {
        let i = useIn.indexOfSelectedItem - 1
        guard choices.indices.contains(i) else { return }
        let on = model.maskInputChoices(maskID).first { $0.effect == choices[i] }?.on ?? false
        model.setMask(maskID, input: !on, ofEffect: choices[i])
    }
    func update() {
        guard let m = model.clip?.mask(maskID) else { return }
        cuts.state = m.usedByOpacity ? .on : .off
        cuts.isEnabled = m.enabled
        let list = model.maskInputChoices(maskID)
        let used = list.filter(\.on).count
        let title = list.isEmpty ? "No effect to use it in" : used == 0 ? "Use in effect…" : used == 1 ? "Used in 1 effect" : "Used in \(used) effects"
        let key = [title] + list.map { "\($0.title)\($0.on)" }
        guard key != shown else { return }
        shown = key
        choices = list.map(\.effect)
        useIn.removeAllItems()
        useIn.addItem(withTitle: title)
        for c in list {
            useIn.addItem(withTitle: c.title)
            useIn.lastItem?.state = c.on ? .on : .off
        }
        useIn.isEnabled = m.enabled && !list.isEmpty
    }
}

/// The opened keyframe row (variant A): left the ease pane (Speed | Value, curve chips, Speed and Reach fields), right
/// the inline speed graph, time-aligned with the lanes above. Value shows the value graph in the same place.
final class SpeedGraphRow: NSView, RowUpdating {
    let property: EffectProperty
    let model: EffectControlsModel
    var laneX: CGFloat = EffectControlsSplit.defaultWidth
    let pane: EasePaneView
    let speedGraph: InlineSpeedGraphView
    private var valueGraphs: [(EffectComponent, KeyframeGraphView)] = []

    override var isFlipped: Bool { true }

    init(property p: EffectProperty, model: EffectControlsModel) {
        property = p; self.model = model
        pane = EasePaneView(property: p, model: model)
        speedGraph = InlineSpeedGraphView(property: p, model: model)
        super.init(frame: .zero)
        addSubview(pane); addSubview(speedGraph)
        let comps: [EffectComponent] = PropertyRow.components(p, model: model)
        for c in comps {
            let g = KeyframeGraphView(frame: .zero)
            g.setAccessibilityLabel(comps.count == 2 ? "\(p.title) \(PropertyRow.componentName(p, c)) graph" : "\(p.title) graph")
            g.displayScale = p == .volume ? 1 : max(abs(p.display(1, picture: model.displayPicture) - p.display(0, picture: model.displayPicture)), 1e-9)
            g.mode = .value
            g.onEdit = { t in model.applyGraphEdit(p, component: c, track: t) }
            g.onSelectionChange = { ids in model.setSelection(for: p, ids: ids) }
            g.onLibraryChange = { lib in model.easingLibrary = lib; model.onLibraryChange?(lib) }
            g.onModeChange = { model.setGraphMode($0, for: p) }
            g.onZoom = { f, anchor in model.zoom(by: f, around: anchor) }
            g.onPan = { model.panViewport(bySeconds: $0) }
            valueGraphs.append((c, g)); addSubview(g)
        }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let lw = min(laneX, bounds.width)
        pane.frame = NSRect(x: 0, y: 0, width: lw, height: bounds.height)
        let right = NSRect(x: lw, y: 0, width: max(bounds.width - lw, 0), height: bounds.height)
        speedGraph.frame = right
        let n = CGFloat(max(valueGraphs.count, 1)), h = right.height / n
        for (i, (_, g)) in valueGraphs.enumerated() {
            // Same 10 pt inset as the keyframe lanes, so the curve lines up with the keys above.
            g.frame = NSRect(x: right.minX, y: CGFloat(i) * h, width: right.width, height: h)
            g.leadingPanelWidth = 0
            g.insets = GraphInsets(top: 14, left: 10, bottom: 14, right: 10)
        }
    }

    func movePlayhead() { speedGraph.movePlayhead() }

    func update() {
        pane.update()
        let speed = model.graphMode(for: property) == .speed
        speedGraph.isHidden = !speed
        if speed { speedGraph.refresh() }
        let local = model.localPlayhead
        let vp = model.viewport
        for (c, g) in valueGraphs {
            g.isHidden = speed
            guard !speed else { continue }
            let t = model.graphTrack(property, component: c)
            if g.track != t { g.track = t }
            if g.mode != .value { g.mode = .value }
            let sel = model.selectedKeyIDs(property)
            if g.selectedKeyIDs != sel { g.selectedKeyIDs = sel }
            g.playheadSeconds = model.playheadInClip ? Double(local.value) / Double(local.timescale) : nil   // as the lanes
            g.frameDuration = model.frameDuration
            g.maxTime = model.duration
            g.visibleTime = vp.range
            g.easingLibrary = model.easingLibrary
        }
    }
}
