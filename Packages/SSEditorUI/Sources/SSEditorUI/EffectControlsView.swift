import AppKit
import Observation
import SSCore

/// Effect Controls panel (DESIGN.md screen 2, Premiere layout): sections Motion / Opacity / Rounded Corners / Volume,
/// then the Text or Audio section. Property rows with scrub fields + animate diamond + key navigation on the left,
/// keyframe lanes on the right, separated by a draggable divider (width persisted). Ruler, clip bar and playhead sit at the
/// top of the keyframe area, timecode and the zoom bar at the bottom. An expanded row shows its speed graph directly under
/// it. All state and edits live in `EffectControlsModel`.
public final class EffectControlsView: NSView {
    /// Width of the properties column (left of the divider).
    public private(set) var labelWidth: CGFloat = EffectControlsSplit.load()
    /// Receives the new width when a divider drag ends; default: UserDefaults.
    public var persistLabelWidth: (CGFloat) -> Void = { EffectControlsSplit.save($0) }

    public let model: EffectControlsModel
    /// Asked before the animate diamond deletes all keys of a property. Default: alert.
    public var confirmRemoval: @MainActor (EffectProperty) -> Bool = EffectControlsView.defaultConfirm

    /// Text / Audio section above the property rows (Premiere); set by the app.
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
    private let lanes: EffectKeyframeLanesView
    private let ruler: KeyframeRulerView
    private let zoomBar: KeyframeZoomBar
    private let divider = EffectControlsDivider()
    private var dividerStartWidth: CGFloat = 0
    private let timecodeLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No clip selected")
    private var rowViews: [(EffectRow, NSView)] = []
    private var signature: Signature?

    private struct Signature: Equatable {
        var clipID: UUID?
        var kind: TrackKind?
        var sections: [EffectSection]
        var collapsed: Set<EffectSection>
        var expanded: Set<EffectProperty>
    }

    public init(model: EffectControlsModel) {
        self.model = model
        lanes = EffectKeyframeLanesView(model: model)
        ruler = KeyframeRulerView(model: model)
        zoomBar = KeyframeZoomBar(model: model)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay      // the lanes must keep the ruler's width
        scroll.documentView = content
        addSubview(scroll)
        emptyLabel.font = Theme.Fonts.small
        emptyLabel.textColor = Theme.Colors.label3
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
        content.addSubview(lanes)
        addSubview(ruler)
        addSubview(zoomBar)
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
        timecodeLabel.font = Theme.Fonts.small
        timecodeLabel.textColor = Theme.Colors.accent
        addSubview(timecodeLabel)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Effect Controls")
        rebuild()
        observe()
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Keys

    public override var acceptsFirstResponder: Bool { true }

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
            _ = model.clip; _ = model.playhead; _ = model.selection; _ = model.expanded
            _ = model.collapsedSections; _ = model.selectedSection; _ = model.graphMode; _ = model.easingLibrary
            _ = model.viewport
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.modelChanged()
                self?.observe()
            }
        }
    }

    private var currentSignature: Signature {
        Signature(clipID: model.clip?.id, kind: model.clip?.kind, sections: model.visibleSections,
                  collapsed: model.collapsedSections, expanded: model.expanded)
    }

    private func modelChanged() {
        if currentSignature != signature { rebuild() } else { refresh() }
    }

    // MARK: Build / refresh

    private func rebuild() {
        for (_, v) in rowViews { v.removeFromSuperview() }
        rowViews = []
        signature = currentSignature
        emptyLabel.isHidden = model.clip != nil
        // Nothing selected: no ruler, zoom bar or divider, just the empty state.
        for v in [ruler, zoomBar, divider, lanes, timecodeLabel] as [NSView] { v.isHidden = model.clip == nil }
        let rows = EffectControlsLayout.rows(sections: model.visibleSections, collapsed: model.collapsedSections,
                                             expanded: model.expanded)
        for row in rows {
            let v: NSView
            switch row.kind {
            case .section(let s): v = SectionHeaderRow(section: s, model: model)
            case .property(let p): v = PropertyRow(property: p, model: model, owner: self)
            case .placeholder: v = PlaceholderRow(title: "Radius")
            case .graph(let p): v = GraphRow(property: p, model: model)
            }
            content.addSubview(v)
            rowViews.append((row, v))
        }
        lanes.rows = rows
        needsLayout = true
        refresh()
    }

    private func refresh() {
        for (_, v) in rowViews { (v as? RowUpdating)?.update() }
        lanes.needsDisplay = true
        ruler.needsDisplay = true
        if model.clip != nil {
            let tc = TimecodeFormat(frameDuration: model.frameDuration)
            timecodeLabel.stringValue = tc.string(for: model.playhead, frameDuration: model.frameDuration)
        } else { timecodeLabel.stringValue = "" }
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
        let rh = KeyframeRulerView.height, bh = KeyframeZoomBar.height
        let lw = EffectControlsSplit.clamp(labelWidth, total: bounds.width)
        let lanesW = max(bounds.width - lw, 0)
        ruler.frame = NSRect(x: lw, y: 0, width: lanesW, height: rh)
        scroll.frame = NSRect(x: 0, y: rh, width: bounds.width, height: max(bounds.height - rh - bh, 0))
        zoomBar.frame = NSRect(x: lw, y: bounds.height - bh, width: lanesW, height: bh)
        timecodeLabel.frame = NSRect(x: 12, y: bounds.height - bh + (bh - 14) / 2, width: max(lw - 24, 0), height: 14)
        divider.frame = NSRect(x: lw - 3, y: 0, width: 7, height: bounds.height)
        emptyLabel.frame = NSRect(x: 0, y: bounds.midY - 8, width: bounds.width, height: 16)
        // Text / Audio section sits below the rows: Motion and Opacity come first.
        let rowsH = rowViews.last.map { $0.0.y + $0.0.height } ?? 0
        let secH = clipSections.map { $0.isHidden ? 0 : $0.preferredHeight(for: bounds.width) } ?? 0
        clipSections?.frame = NSRect(x: 0, y: rowsH, width: bounds.width, height: secH)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(rowsH + secH, scroll.frame.height))
        for (row, v) in rowViews {
            let isGraph = { if case .graph = row.kind { return true } else { return false } }()
            v.frame = NSRect(x: 0, y: row.y, width: isGraph ? bounds.width : lw, height: row.height)
        }
        // The lanes cover the whole scrollable height: the empty area under the last row still shows the playhead line,
        // zooms / pans and deselects like the rest of the keyframe area.
        lanes.frame = NSRect(x: lw, y: 0, width: lanesW, height: content.frame.height)
        // Graph rows are laid out by themselves (they need the lane origin).
        for (row, v) in rowViews { if case .graph = row.kind { (v as? GraphRow)?.laneX = lw; v.needsLayout = true } }
        refresh()
    }

    // MARK: Stopwatch

    fileprivate func stopwatchTapped(_ p: EffectProperty) {
        if model.toggleStopwatch(p) == .needsConfirmation, confirmRemoval(p) {
            model.toggleStopwatch(p, confirmRemoval: true)
        }
    }

    @MainActor private static func defaultConfirm(_ p: EffectProperty) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove all \(p.title) keyframes?"
        alert.informativeText = "The property keeps the value it has at the playhead."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Row views

@MainActor private protocol RowUpdating { func update() }

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ClosureButton: NSButton {
    var handler: (() -> Void)?
    convenience init(symbol: String, label: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        contentTintColor = Theme.Colors.label2
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { handler?() }
    func setSymbol(_ name: String, tint: NSColor) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        contentTintColor = tint
    }
}

@MainActor private func makeLabel(_ s: String, font: NSFont = Theme.Fonts.small, color: NSColor = Theme.Colors.label2) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = font; l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
}

private class RowBackground: NSView {
    var fill: NSColor = Theme.Colors.panel
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill(); bounds.fill()
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

private final class SectionHeaderRow: RowBackground, RowUpdating {
    let section: EffectSection
    let model: EffectControlsModel
    private let chevron: ClosureButton
    private let title: NSTextField
    private let fx: ClosureButton
    private let reset: ClosureButton
    private var lastSelected = false

    init(section: EffectSection, model: EffectControlsModel) {
        self.section = section; self.model = model
        let collapsed = model.collapsedSections.contains(section)
        chevron = ClosureButton(symbol: collapsed ? "chevron.right" : "chevron.down",
                                label: collapsed ? "Expand \(section.title)" : "Collapse \(section.title)") {
            if model.collapsedSections.contains(section) { model.collapsedSections.remove(section) }
            else { model.collapsedSections.insert(section) }
        }
        title = makeLabel(section.title, font: .systemFont(ofSize: 11, weight: .semibold), color: Theme.Colors.label)
        fx = ClosureButton(symbol: "function", label: "Enable or disable \(section.title)") {
            model.setEffectEnabled(section, !model.isEffectEnabled(section))
        }
        reset = ClosureButton(symbol: "arrow.counterclockwise", label: "Reset \(section.title)") { model.resetSection(section) }
        super.init(frame: .zero)
        fill = Theme.Colors.titlebar
        addSubview(chevron); addSubview(title); addSubview(reset)
        if section.effectKind != nil { addSubview(fx) }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        chevron.frame = NSRect(x: 6, y: 0, width: 18, height: bounds.height)
        reset.frame = NSRect(x: w - 24, y: 0, width: 18, height: bounds.height)
        fx.frame = NSRect(x: w - 46, y: 0, width: 20, height: bounds.height)
        title.frame = NSRect(x: 28, y: (bounds.height - 14) / 2, width: max(w - 80, 0), height: 14)
    }

    override func mouseDown(with event: NSEvent) {
        model.selectedSection = section
        var v: NSView? = self
        while let x = v, !(x is EffectControlsView) { v = x.superview }
        if let owner = v { window?.makeFirstResponder(owner) }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        model.selectedSection = section
        let m = NSMenu(title: section.title)
        m.autoenablesItems = false
        if section.effectKind != nil {
            let on = model.isEffectEnabled(section)
            m.addItem(item(on ? "Disable Effect" : "Enable Effect", #selector(toggleFX)))
        }
        m.addItem(item("Reset \(section.title)", #selector(doReset)))
        if model.canRemoveEffect(section) {
            m.addItem(.separator())
            m.addItem(item("Remove Effect", #selector(doRemove)))
        }
        return m
    }
    private func item(_ t: String, _ a: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; return i
    }
    @objc private func toggleFX() { model.setEffectEnabled(section, !model.isEffectEnabled(section)) }
    @objc private func doReset() { model.resetSection(section) }
    @objc private func doRemove() { model.removeEffect(section) }

    func update() {
        let on = model.isEffectEnabled(section)
        fx.setSymbol("function", tint: on ? Theme.Colors.accent : Theme.Colors.label3)
        fx.toolTip = on ? "Disable \(section.title)" : "Enable \(section.title)"
        let selected = model.selectedSection == section && section.effectKind != nil
        if selected != lastSelected { lastSelected = selected; fill = selected ? Theme.Colors.selection : Theme.Colors.titlebar; needsDisplay = true }
        reset.isEnabled = section.properties.contains { !model.isDefault($0) } || !on
        title.textColor = on ? Theme.Colors.label : Theme.Colors.label3
    }
}

private final class PlaceholderRow: RowBackground, RowUpdating {
    init(title: String) {
        super.init(frame: .zero)
        let l = makeLabel(title, color: Theme.Colors.label3)
        let v = makeLabel("Not available yet", color: Theme.Colors.label3)
        addSubview(l); addSubview(v)
        l.frame = NSRect(x: 28, y: 5, width: 92, height: 14)
        v.frame = NSRect(x: 124, y: 5, width: 160, height: 14)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update() {}
}

private final class PropertyRow: RowBackground, RowUpdating {
    let property: EffectProperty
    let model: EffectControlsModel
    private weak var owner: EffectControlsView?
    private let chevron: ClosureButton
    private let name: NSTextField
    private var fields: [ScrubField] = []
    private let prev: ClosureButton, key: ClosureButton, next: ClosureButton
    private let reset: ClosureButton

    init(property p: EffectProperty, model: EffectControlsModel, owner: EffectControlsView) {
        property = p; self.model = model; self.owner = owner
        let open = model.expanded.contains(p)
        chevron = ClosureButton(symbol: open ? "chevron.down" : "chevron.right",
                                label: open ? "Hide \(p.title) graph" : "Show \(p.title) graph") {
            if model.expanded.contains(p) { model.expanded.remove(p) } else { model.expanded.insert(p) }
        }
        name = makeLabel(p.title)
        prev = ClosureButton(symbol: "chevron.left", label: "Previous keyframe") { model.goToPreviousKey(p) }
        key = ClosureButton(symbol: "diamond", label: "Add or remove keyframe") { model.toggleKeyAtPlayhead(p) }
        next = ClosureButton(symbol: "chevron.right", label: "Next keyframe") { model.goToNextKey(p) }
        reset = ClosureButton(symbol: "arrow.counterclockwise", label: "Reset \(p.title)") { model.reset(p) }
        super.init(frame: .zero)
        reset.toolTip = "Reset \(p.title) (value at the playhead when animated; right-click for Reset All)"
        addSubview(chevron); addSubview(name)
        let comps: [EffectComponent] = p.kind == .vector ? [.x, .y] : [.all]
        for (i, c) in comps.enumerated() {
            let f = ScrubField(frame: .zero)
            f.range = p.displayRange
            f.step = p.displayStep
            f.unit = p.displayUnit
            f.decimals = p.displayDecimals
            f.setAccessibilityLabel(comps.count == 2 ? "\(p.title) \(c == .x ? "X" : "Y")" : p.title)
            f.onBegin = { model.beginGesture() }
            f.onChange = { v in model.setValue(p, component: c, to: p.native(fromDisplay: v)) }
            f.onEnd = { _ in model.endGesture() }
            if i == 0 {
                f.keyframeState = ScrubKeyframeState.none
                f.onKeyframeToggle = { [weak owner] in owner?.stopwatchTapped(p) }
            }
            fields.append(f); addSubview(f)
        }
        addSubview(prev); addSubview(key); addSubview(next); addSubview(reset)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, fh = Theme.Metrics.controlHeight, y = (h - fh) / 2
        chevron.frame = NSRect(x: 6, y: 0, width: 18, height: h)
        name.frame = NSRect(x: 28, y: (h - 14) / 2, width: 72, height: 14)
        var x: CGFloat = 104
        for (i, f) in fields.enumerated() {
            let w: CGFloat = i == 0 ? 72 : 60
            f.frame = NSRect(x: x, y: y, width: w, height: fh); x += w + 4
        }
        // Key navigation (previous, add/remove, next) sits left of the reset arrow, like Premiere.
        x = max(x, bounds.width - 24 - 54 - 4)
        for b in [prev, key, next] { b.frame = NSRect(x: x, y: 0, width: 18, height: h); x += 18 }
        reset.frame = NSRect(x: bounds.width - 24, y: 0, width: 18, height: h)
    }

    // Right-click: reset at the playhead and, separately, reset all (drops the keyframes).
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu(title: property.title)
        m.autoenablesItems = false
        let animated = model.isAnimated(property)
        if animated {
            let here = NSMenuItem(title: "Reset Value at Playhead", action: #selector(resetHere), keyEquivalent: "")
            here.target = self; here.isEnabled = model.playheadInClip
            m.addItem(here)
        }
        let all = NSMenuItem(title: animated ? "Reset All (Remove Keyframes)" : "Reset", action: #selector(resetEverything), keyEquivalent: "")
        all.target = self; all.isEnabled = !model.isDefault(property)
        m.addItem(all)
        return m
    }
    @objc private func resetHere() { model.resetAtPlayhead(property) }
    @objc private func resetEverything() { model.resetAll(property) }

    func update() {
        let p = property
        let animated = model.isAnimated(p)
        let state = model.keyState(p)
        fields[0].keyframeState = state
        switch p.kind {
        case .vector:
            let v = model.vectorValue(p)
            set(fields[0], p.display(v.x)); set(fields[1], p.display(v.y))
        default:
            set(fields[0], p.display(model.scalarValue(p)))
        }
        [prev, key, next].forEach { $0.isHidden = !animated }
        prev.isEnabled = model.previousKeyTime(p) != nil
        next.isEnabled = model.nextKeyTime(p) != nil
        key.setSymbol(state == .onKey ? "diamond.fill" : "diamond",
                      tint: state == .onKey ? Theme.Colors.accent : Theme.Colors.label2)
        reset.isEnabled = animated ? (model.canResetAtPlayhead(p) || !model.isDefault(p)) : !model.isDefault(p)
        let inClip = model.playheadInClip
        key.isEnabled = inClip
        fields[0].alphaValue = 1
    }

    private func set(_ f: ScrubField, _ v: Double) {
        if !f.isDragging && !f.isEditing && f.value != v { f.value = v }
    }
}

/// Speed graph directly under its property row (Premiere): the keys are the glyphs in the row above, the graph only shows
/// the curve with small key markers and the handles of selected keys. The value graph is one context-menu click away.
private final class GraphRow: NSView, RowUpdating {
    let property: EffectProperty
    let model: EffectControlsModel
    var laneX: CGFloat = EffectControlsSplit.defaultWidth
    private var graphs: [(EffectComponent, KeyframeGraphView)] = []

    override var isFlipped: Bool { true }

    init(property p: EffectProperty, model: EffectControlsModel) {
        property = p; self.model = model
        super.init(frame: .zero)
        let comps: [EffectComponent] = p.kind == .vector ? [.x, .y] : [.all]
        for c in comps {
            let g = KeyframeGraphView(frame: .zero)
            g.setAccessibilityLabel(comps.count == 2 ? "\(p.title) \(c == .x ? "X" : "Y") graph" : "\(p.title) graph")
            g.displayScale = p == .scale || p == .opacity ? 100 : 1
            g.onEdit = { t in model.applyGraphEdit(p, component: c, track: t) }
            g.onSelectionChange = { ids in model.setSelection(for: p, ids: ids) }
            g.onLibraryChange = { lib in model.easingLibrary = lib; model.onLibraryChange?(lib) }
            g.onModeChange = { model.graphMode = $0 }
            g.onZoom = { f, anchor in model.zoom(by: f, around: anchor) }
            g.onPan = { model.panViewport(bySeconds: $0) }
            graphs.append((c, g)); addSubview(g)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        let n = CGFloat(graphs.count)
        let h = (bounds.height - 1) / max(n, 1)
        for (i, (_, g)) in graphs.enumerated() {
            // The graph spans the whole row: its plot starts where the keyframe lanes start (same 10 pt inset,
            // so the curve lines up with the keys above), its two value labels sit in the label column.
            g.frame = NSRect(x: 0, y: CGFloat(i) * h, width: bounds.width, height: h)
            g.leadingPanelWidth = laneX
            g.insets = GraphInsets(top: 14, left: laneX + 10, bottom: 14, right: 10)
        }
    }

    func update() {
        let local = model.localPlayhead
        let vp = model.viewport
        for (c, g) in graphs {
            let t = model.graphTrack(property, component: c)
            if g.track != t { g.track = t }
            if g.mode != model.graphMode { g.mode = model.graphMode }
            let sel = model.selectedKeyIDs(property)
            if g.selectedKeyIDs != sel { g.selectedKeyIDs = sel }
            g.playheadSeconds = Double(local.value) / Double(local.timescale)
            g.frameDuration = model.frameDuration
            g.maxTime = model.duration
            g.visibleTime = vp.range
            g.easingLibrary = model.easingLibrary
        }
    }
}
