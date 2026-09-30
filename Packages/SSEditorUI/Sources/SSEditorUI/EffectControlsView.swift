import AppKit
import Observation
import SSCore

/// Effect Controls panel (DESIGN.md screen 2): sections Motion / Opacity / Rounded Corners / Volume,
/// property rows with scrub fields + animate diamond + key navigation on the left, keyframe lanes on the right,
/// graph in place when a row is expanded. All state and edits live in `EffectControlsModel`.
public final class EffectControlsView: NSView {
    public static let labelWidth: CGFloat = 340

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
    private let emptyLabel = NSTextField(labelWithString: "No clip selected")
    private var rowViews: [(EffectRow, NSView)] = []
    private var signature: Signature?

    private struct Signature: Equatable {
        var clipID: UUID?
        var kind: TrackKind?
        var collapsed: Set<EffectSection>
        var expanded: Set<EffectProperty>
    }

    public init(model: EffectControlsModel) {
        self.model = model
        lanes = EffectKeyframeLanesView(model: model)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = content
        addSubview(scroll)
        emptyLabel.font = Theme.Fonts.small
        emptyLabel.textColor = Theme.Colors.label3
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
        content.addSubview(lanes)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Effect Controls")
        rebuild()
        observe()
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Observation

    private func observe() {
        withObservationTracking {
            _ = model.clip; _ = model.playhead; _ = model.selection; _ = model.expanded
            _ = model.collapsedSections; _ = model.graphMode; _ = model.easingLibrary
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.modelChanged()
                self?.observe()
            }
        }
    }

    private var currentSignature: Signature {
        Signature(clipID: model.clip?.id, kind: model.clip?.kind,
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
    }

    public override func layout() {
        super.layout()
        scroll.frame = bounds
        emptyLabel.frame = NSRect(x: 0, y: bounds.midY - 8, width: bounds.width, height: 16)
        let topH = clipSections.map { $0.isHidden ? 0 : $0.preferredHeight(for: bounds.width) } ?? 0
        clipSections?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: topH)
        let total = (rowViews.last.map { $0.0.y + $0.0.height } ?? 0) + topH
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(total, bounds.height))
        let lw = min(Self.labelWidth, bounds.width)
        for (row, v) in rowViews {
            let isGraph = { if case .graph = row.kind { return true } else { return false } }()
            v.frame = NSRect(x: 0, y: row.y + topH, width: isGraph ? bounds.width : lw, height: row.height)
        }
        lanes.frame = NSRect(x: lw, y: topH, width: max(bounds.width - lw, 0), height: max(content.frame.height - topH, 0))
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

    init(section: EffectSection, model: EffectControlsModel) {
        self.section = section; self.model = model
        let collapsed = model.collapsedSections.contains(section)
        chevron = ClosureButton(symbol: collapsed ? "chevron.right" : "chevron.down",
                                label: collapsed ? "Expand \(section.title)" : "Collapse \(section.title)") {
            if model.collapsedSections.contains(section) { model.collapsedSections.remove(section) }
            else { model.collapsedSections.insert(section) }
        }
        title = makeLabel(section.title, font: .systemFont(ofSize: 11, weight: .semibold), color: Theme.Colors.label)
        super.init(frame: .zero)
        fill = Theme.Colors.titlebar
        addSubview(chevron); addSubview(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: 6, y: 0, width: 18, height: bounds.height)
        title.frame = NSRect(x: 28, y: (bounds.height - 14) / 2, width: bounds.width - 36, height: 14)
    }
    func update() {}
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
        super.init(frame: .zero)
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
        addSubview(prev); addSubview(key); addSubview(next)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, fh = Theme.Metrics.controlHeight, y = (h - fh) / 2
        chevron.frame = NSRect(x: 6, y: 0, width: 18, height: h)
        name.frame = NSRect(x: 28, y: (h - 14) / 2, width: 92, height: 14)
        var x: CGFloat = 124
        for (i, f) in fields.enumerated() {
            let w: CGFloat = i == 0 ? 82 : 64
            f.frame = NSRect(x: x, y: y, width: w, height: fh); x += w + 4
        }
        x = max(x, 278)
        for b in [prev, key, next] { b.frame = NSRect(x: x, y: 0, width: 18, height: h); x += 18 }
    }

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
        let inClip = model.playheadInClip
        key.isEnabled = inClip
        fields[0].alphaValue = 1
    }

    private func set(_ f: ScrubField, _ v: Double) {
        if !f.isDragging && !f.isEditing && f.value != v { f.value = v }
    }
}

private final class GraphRow: NSView, RowUpdating {
    let property: EffectProperty
    let model: EffectControlsModel
    var laneX: CGFloat = EffectControlsView.labelWidth
    private var graphs: [(EffectComponent, KeyframeGraphView)] = []
    private let mode = NSSegmentedControl(labels: ["Value", "Speed"], trackingMode: .selectOne, target: nil, action: nil)

    override var isFlipped: Bool { true }

    init(property p: EffectProperty, model: EffectControlsModel) {
        property = p; self.model = model
        super.init(frame: .zero)
        mode.controlSize = .small
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel("Graph type")
        addSubview(mode)
        let comps: [EffectComponent] = p.kind == .vector ? [.x, .y] : [.all]
        for c in comps {
            let g = KeyframeGraphView(frame: .zero)
            g.setAccessibilityLabel(comps.count == 2 ? "\(p.title) \(c == .x ? "X" : "Y") graph" : "\(p.title) graph")
            g.onEdit = { t in model.applyGraphEdit(p, component: c, track: t) }
            g.onSelectionChange = { ids in model.setSelection(for: p, ids: ids) }
            g.onLibraryChange = { lib in model.easingLibrary = lib; model.onLibraryChange?(lib) }
            graphs.append((c, g)); addSubview(g)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.panel.setFill()
        NSRect(x: 0, y: 0, width: min(laneX, bounds.width), height: bounds.height).fill()
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        mode.frame = NSRect(x: 28, y: 6, width: 110, height: 18)
        let n = CGFloat(graphs.count)
        let h = (bounds.height - 1) / max(n, 1)
        for (i, (_, g)) in graphs.enumerated() {
            g.frame = NSRect(x: laneX, y: CGFloat(i) * h, width: max(bounds.width - laneX, 0), height: h)
        }
    }

    @objc private func modeChanged() { model.graphMode = mode.selectedSegment == 1 ? .speed : .value }

    func update() {
        mode.selectedSegment = model.graphMode == .speed ? 1 : 0
        let local = model.localPlayhead
        for (c, g) in graphs {
            let t = model.graphTrack(property, component: c)
            if g.track != t { g.track = t }
            if g.mode != model.graphMode { g.mode = model.graphMode }
            let sel = model.selectedKeyIDs(property)
            if g.selectedKeyIDs != sel { g.selectedKeyIDs = sel }
            g.playheadSeconds = Double(local.value) / Double(local.timescale)
            g.frameDuration = model.frameDuration
            g.maxTime = model.duration
            g.easingLibrary = model.easingLibrary
        }
    }
}
