import AppKit
import SQCore
import SQText

/// Window > Graphics: the layer list and properties of the selected graphics clip (GFX design layer). Add shapes and
/// text, arrange, group, align and distribute; Motion, Opacity, shape look, text and layer effects of the selected layer,
/// written at the playhead (a keyed property gets a key there). Every change is one undo step through `GraphicsEditor`.
@MainActor
public final class GraphicsPanelView: NSView {
    public let editor: GraphicsEditor
    /// "New Graphics Clip" in the empty state (the host adds the clip and keeps the panel in front).
    public var onNewGraphic: (() -> Void)?
    /// "Make Graphic" in the empty state of a text or shape clip (the host converts the selected clip).
    public var onMakeGraphic: (() -> Void)?
    /// "Save as Template…" in the header (the host shows the name sheet and saves to the Library).
    public var onSaveTemplate: (() -> Void)? {
        get { headerBar.onSaveTemplate }
        set { headerBar.onSaveTemplate = newValue }
    }
    /// "Save Effects as Preset…" in the layer's Effects section: the host asks for a name and saves to the Library.
    public var onSaveEffectPreset: ((EffectPreset) -> Void)?
    /// The Library's effect presets a layer can take (name + preset), listed in the Presets menu of the Effects section.
    public var effectPresets: (() -> [(name: String, preset: EffectPreset)])?
    /// The window's Library keystones: the saved animations of the text item's Intro / Outro popups, and where a
    /// Custom one is saved (the same store `ClipSectionsView` gets).
    public weak var keystones: KeystonesPanelModel? { didSet { textModel?.keystones = keystones } }
    /// Says a short notice in the host's status line (a save that could not happen); the SQ dialog when unset.
    public var onNotice: ((String) -> Void)?
    /// The text item's model and block while one is selected.
    private(set) weak var textModel: TextInspectorModel?
    private(set) weak var textBlock: TextBlockView?
    let headerBar = GraphicsHeaderBar()

    /// The layer list: pinned on top (own scroll), so it stays in view while the properties below scroll.
    public let list: LayerListView
    private let handle = ListResizeHandle()
    /// One-line message at the bottom (a refused effect drop); clears itself.
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusToken = 0
    private let scroll = NSScrollView()
    private let stack = FlippedStack()
    private var structureKey: String?
    /// Value refreshers of the built controls (run on playhead / value changes without rebuilding).
    private var refreshers: [() -> Void] = []
    private var footerButtons: [(NSControl, (GraphicsEditor) -> Bool)] = []
    private var drawButton: IconButton?

    static let listHeightKey = "sq.graphics.listHeight"
    /// List height (rows + footer), dragged at the handle; at least three rows.
    var listHeight: CGFloat = CGFloat(UserDefaults.standard.double(forKey: GraphicsPanelView.listHeightKey)) {
        didSet { needsLayout = true }
    }
    private static let minListHeight = Theme.Row.list * 3 + LayerListView.footerHeight
    private static let defaultListHeight = Theme.Row.list * 6 + LayerListView.footerHeight

    public override func becomeFirstResponder() -> Bool { list.focused = true; return true }
    public override func resignFirstResponder() -> Bool { list.focused = false; return true }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// Delete removes the selected layers (never the whole graphics clip). Other keys travel on.
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            editor.deleteSelected()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           editSelectedLayer() { return }
        super.keyDown(with: event)
    }

    /// Return on the layer list: a selected text layer puts the caret in its text box; any other single layer or group
    /// starts the rename of its row. False when nothing fits (no layer, or several).
    @discardableResult
    func editSelectedLayer() -> Bool {
        guard editor.selectedLayers.count == 1, let layer = editor.selectedLayer else { return false }
        if case .text = layer.content, let block = textBlock { return block.focusTextBox() }
        return list.beginRenameSelected()
    }

    public override func selectAll(_ sender: Any?) { editor.selectAllLayers(); selectionChanged() }

    // MARK: Effects dropped from the Effects panel

    /// The effect kinds an Effects panel drag carries (one effect, or a folder's); empty for any other drag.
    static func effectKinds(from pb: NSPasteboard) -> [String] {
        guard let s = pb.string(forType: .sequenceEffectID) else { return [] }
        return EffectDragPayload.decodeDrag(s)
    }

    /// Shows a refusal for a few seconds (an added effect needs no message: the section appears).
    func showDrop(_ r: GraphicsEditor.EffectDrop) {
        selectionChanged()
        guard case .refused(let why) = r else { return }
        statusLabel.stringValue = why
        statusLabel.isHidden = false
        statusLabel.setAccessibilityLabel(why)
        statusToken += 1
        let token = statusToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, statusToken == token else { return }
            statusLabel.isHidden = true
        }
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        editor.clip?.graphics != nil && !Self.effectKinds(from: sender.draggingPasteboard).isEmpty ? .copy : []
    }

    /// A drop on the properties: goes to the selected layer when exactly one is selected.
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let kinds = Self.effectKinds(from: sender.draggingPasteboard)
        guard editor.clip?.graphics != nil, !kinds.isEmpty else { return false }
        guard editor.selectedLayers.count == 1 else { showDrop(.refused("Select one layer to add an effect.")); return true }
        showDrop(editor.addEffects(kinds))
        return true
    }

    public init(editor: GraphicsEditor) {
        self.editor = editor
        list = LayerListView(editor: editor)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 480))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ControlsMetrics.sectionGap    // sections touch; one hairline each (DESIGN.md inspector grid)
        stack.edgeInsets = NSEdgeInsets(top: Theme.Spacing.sm, left: 0, bottom: Theme.Spacing.md, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        addSubview(headerBar)
        addSubview(list)
        addSubview(handle)
        addSubview(scroll)
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        list.onFocus = { [weak self] in
            guard let self, let w = window, w.firstResponder !== self else { return }
            w.makeFirstResponder(self)
        }
        list.onSelectionChange = { [weak self] in self?.selectionChanged() }
        list.onEffectDrop = { [weak self] r in self?.showDrop(r) }
        registerForDraggedTypes([.sequenceEffectID])
        statusLabel.font = Theme.Typography.body
        statusLabel.textColor = Theme.Colors.label2
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .center
        statusLabel.wantsLayer = true
        statusLabel.layer?.backgroundColor = Theme.Colors.panel.cgColor
        statusLabel.isHidden = true
        addSubview(statusLabel)
        handle.onDrag = { [weak self] dy in
            guard let self else { return }
            listHeight = clampedListHeight(currentListHeight + dy)
            UserDefaults.standard.set(Double(listHeight), forKey: Self.listHeightKey)
        }
        buildFooter()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Graphics")
        sync([.project, .selection])
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    private var currentListHeight: CGFloat { listHeight > 0 ? listHeight : Self.defaultListHeight }

    private func clampedListHeight(_ h: CGFloat) -> CGFloat {
        let maxH = max(bounds.height - GraphicsHeaderBar.height - Theme.Inspector.rowHeight * 4, Self.minListHeight)
        return min(max(h, Self.minListHeight), maxH)
    }

    public override func layout() {
        super.layout()
        let hasClip = editor.clip?.graphics != nil
        list.isHidden = !hasClip
        handle.isHidden = !hasClip
        headerBar.isHidden = !hasClip
        statusLabel.frame = NSRect(x: 0, y: max(bounds.height - Theme.Inspector.rowHeight, 0), width: bounds.width, height: Theme.Inspector.rowHeight)
        guard hasClip else { scroll.frame = bounds; return }
        let top = GraphicsHeaderBar.height
        headerBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        let h = clampedListHeight(currentListHeight)
        list.frame = NSRect(x: 0, y: top, width: bounds.width, height: h)
        handle.frame = NSRect(x: 0, y: top + h - ListResizeHandle.grab / 2, width: bounds.width, height: ListResizeHandle.grab)
        scroll.frame = NSRect(x: 0, y: top + h + Theme.Separator.width, width: bounds.width,
                              height: max(bounds.height - top - h - Theme.Separator.width, 0))
    }

    /// Playhead ticks the panel skipped (hidden) or short-cut (nothing on screen depends on the time).
    private(set) var skippedTicks = 0, shortCutTicks = 0
    private var tickPending = false
    private var lastInClip = false

    /// The panel is on screen (its dock tab selected, window up). A hidden panel takes no playhead ticks.
    var isShown: Bool { !isHiddenOrHasHiddenAncestor && (window != nil || superview == nil) }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); catchUp() }
    public override func viewDidUnhide() { super.viewDidUnhide(); catchUp() }
    private func catchUp() {
        guard tickPending, isShown else { return }
        tickPending = false
        lastInClip = !editor.playheadInClip
        sync([.playhead])
    }

    /// Some layer of the selection has a key (Motion, Opacity or an effect): its rows read the value at the playhead.
    private var selectionAnimated: Bool { editor.targetLayers.contains { !LayerListLogic.keyTimes($0).isEmpty } }

    public func sync(_ change: EditorSession.Change) {
        guard change.contains(.project) || change.contains(.selection) || change.contains(.playhead) else { return }
        let timeOnly = !change.contains(.project) && !change.contains(.selection)
        if timeOnly {
            guard isShown else { tickPending = true; skippedTicks += 1; return }
            // A playhead move changes only the key strips and the rows of an animated layer (and the add-key state at the clip edge).
            list.refreshPlayhead()
            let inClip = editor.playheadInClip
            if inClip == lastInClip, !selectionAnimated { shortCutTicks += 1; return }
            lastInClip = inClip
            if !refreshers.isEmpty { refresh(); return }
        }
        if change.contains(.project) || change.contains(.selection) {
            editor.sync()
            if let c = editor.clip { headerBar.show(c) }
            list.reload()
            updateFooter()
            needsLayout = true
        }
        if change.contains(.playhead) { list.refreshTicks() }
        lastInClip = editor.playheadInClip
        let key = Self.structure(editor)
        if key != structureKey || refreshers.isEmpty { structureKey = key; rebuild() } else { refresh() }
    }

    /// The layer selection changed (overlay click, list click): reload the list, rebuild the property section.
    public func selectionChanged() { structureKey = nil; list.reload(); updateFooter(); sync([.selection]) }

    private func refresh() {
        let editing = window?.firstResponder as? NSTextView
        for r in refreshers { r() }
        if let editing { window?.makeFirstResponder(editing) }
    }

    /// What decides the property rows: clip, selection, the selected layer's effects, draw mode.
    static func structure(_ e: GraphicsEditor) -> String { GraphicsPanelLogic.structure(e) }

    // MARK: Footer (add + arrange, under the list)

    private func buildFooter() {
        let text = SQButton(title: "+ Text", target: nil, action: nil)
        let textTarget = ActionTarget { [weak self] in self?.editor.addText(); self?.selectionChanged() }
        text.target = textTarget; text.action = #selector(ActionTarget.fire)
        keep(textTarget, on: text)
        text.setAccessibilityLabel("Add Text")
        let shape = SQButton(title: "+ Shape", target: nil, action: nil)
        let shapeTarget = ActionTarget { [weak self, weak shape] in
            guard let self, let shape, let w = shape.window else { return }
            let items = ShapeKind.allCases.map { k in
                SQMenuItem(title: k.title, icon: .symbol(Self.symbol(k))) { [weak self] in self?.editor.addShape(k); self?.selectionChanged() }
            }
            let bottom = shape.isFlipped ? shape.bounds.maxY : 0
            let p = w.convertPoint(toScreen: shape.convert(NSPoint(x: 0, y: bottom), to: nil))
            SQMenuController.shared.present(items: items, at: p)
        }
        shape.target = shapeTarget; shape.action = #selector(ActionTarget.fire)
        keep(shapeTarget, on: shape)
        shape.setAccessibilityLabel("Add Shape")
        let draw = IconButton(symbol: .draw, label: "Draw", size: 12) { [weak self] in
            guard let self else { return }
            editor.isDrawing.toggle()
            selectionChanged()
        }
        drawButton = draw
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let group = iconButton(.bundle, "Group", command: .group) { [weak self] in self?.editor.groupSelected() }
        let dup = iconButton(.duplicate, "Duplicate", command: .duplicate) { [weak self] in self?.editor.duplicateSelected() }
        let del = iconButton(.trash, "Delete Layers", command: .delete) { [weak self] in self?.editor.deleteSelected() }
        footerButtons = [(group, { $0.selectedLayers.count >= 2 }), (dup, { !$0.selectedLayers.isEmpty }),
                         (del, { !$0.selectedLayers.isEmpty })]
        for v in [text, shape, draw, spacer, group, dup, del] { list.footer.addArrangedSubview(v) }
        updateFooter()
    }

    private func updateFooter() {
        for (b, enabled) in footerButtons { b.isEnabled = enabled(editor) }
        drawButton?.contentTintColor = editor.isDrawing ? Theme.Colors.accent : Theme.Colors.label2
    }

    // MARK: Build

    private func rebuild() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        refreshers = []
        section = nil
        guard let clip = editor.clip, clip.graphics != nil else {
            let state = GraphicsEmptyState.resolve(editor.session.singleSelectedClip) ?? .noGraphic
            let blocker = state == .editedInControls
                ? editor.session.singleSelectedClip.flatMap { editor.session.project.makeGraphicBlocker(clipID: $0.id) } : nil
            let empty = EmptyStateView(title: state.title, hint: blocker ?? state.hint)
            stack.addArrangedSubview(empty)
            // Centered in the panel like every other empty state: as wide and as tall as the visible area.
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let fill = empty.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor,
                                                     constant: -(stack.edgeInsets.top + stack.edgeInsets.bottom))
            fill.priority = .defaultHigh
            fill.isActive = true
            empty.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            // A text or shape clip becomes a graphic with Make Graphic; otherwise New Graphics Clip is the primary action.
            if state == .editedInControls {
                empty.setAction(title: "Make Graphic") { [weak self] in self?.makeGraphic() }
                empty.actionButton?.sqToolTip = blocker ?? "Turn this clip into a graphic with one layer. The picture stays the same."
                empty.actionButton?.isEnabled = blocker == nil
            } else {
                empty.setAction(title: "New Graphics Clip") { [weak self] in self?.newGraphic() }
                empty.actionButton?.style = .accent
            }
            return
        }
        let n = editor.selectedLayers.count
        guard n > 0 else { buildIntroOutro(clip); return }
        buildArrange(count: n)
        buildTransform()
        if n == 1 { buildFollow() }
        let layers = editor.targetLayers
        // Kind sections only when every selected layer has that kind; a text layer's look lives in its text block.
        if layers.allSatisfy({ !$0.isText }) {
            buildShape(layers)
            buildAppearance(layers)
        } else if let layer = editor.selectedLayer, layer.isText {
            buildText()
        }
        if let layer = editor.selectedLayer { buildEffects(layer) }
    }

    @objc private func makeGraphic() { onMakeGraphic?() }
    @objc private func newGraphic() { onNewGraphic?() }

    /// No layer selected: Intro and Outro of the whole clip (animation zones, same calls as the Template section).
    private func buildIntroOutro(_ clip: Clip) {
        begin("Intro and Outro", key: "introOutro")
        let s = editor.session, id = clip.id
        let box = SQCheckbox(title: "Keep intro and outro when trimmed", target: nil, action: nil)
        box.state = clip.zones == nil ? .off : .on
        box.sqToolTip = "The first and last moments keep their length when you trim or stretch the clip."
        let boxTarget = ActionTarget { [weak self, weak box] in
            guard let box else { return }
            s.setZonesEnabled(box.state == .on, clip: id)
            self?.selectionChanged()
        }
        box.target = boxTarget; box.action = #selector(ActionTarget.fire)
        keep(boxTarget, on: box)
        add(row([box]))
        defer { buildTemplateFields(clip) }
        guard let zones = clip.zones else { return }
        let middle = SQSegmented(labels: ["Hold", "Stretch"], segmentWidth: 64)
        middle.selectedSegment = zones.middle == .stretch ? 1 : 0
        middle.setAccessibilityLabel("Middle")
        let mt = ActionTarget { [weak middle] in
            guard let middle else { return }
            s.setZoneMiddle(middle.selectedSegment == 1 ? .stretch : .hold, clip: id)
        }
        middle.target = mt; middle.action = #selector(ActionTarget.fire)
        keep(mt, on: middle)
        add(InspectorRow(title: "Middle", control: middle, controlWidth: 128))
        // Seconds-exact zones: the first N seconds are the in animation, the last M the out animation.
        func secs(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }
        let e = editor
        add(numberRow("In", unit: "s", key: nil, decimals: 2, fields: [
            (get: { e.clip?.zones.map { secs($0.introEnd) } }, set: { e.setZoneLengths(intro: $0, outro: nil) })]))
        add(numberRow("Out", unit: "s", key: nil, decimals: 2, fields: [
            (get: { e.clip?.zones.map { secs($0.outroLength) } }, set: { e.setZoneLengths(intro: nil, outro: $0) })]))
    }

    /// G10: the fields "Save as Template…" makes from this graphic (one per text layer, plus Color, Font and Size of the
    /// first). Read-only: the values are edited on the layer itself and, once the template is placed, in Controls.
    private func buildTemplateFields(_ clip: Clip) {
        let fields = TemplateFieldsLogic.fields(of: clip)
        guard !fields.isEmpty else { return }
        begin("Template Fields", key: "templateFields")
        for f in fields {
            let value = NSTextField(labelWithString: f.value)
            value.font = Theme.Typography.body
            value.textColor = Theme.Colors.label2
            value.lineBreakMode = .byTruncatingTail
            add(InspectorRow(title: f.title, control: value, controlWidth: 128))
        }
    }

    // MARK: Properties

    /// Align to: the frame (each layer on its own) or the selection (2+ layers). Kept for the session.
    var alignToFrame = false
    /// Scale X and Y linked (an edit keeps each layer's ratio).
    var scaleLinked: Bool {
        get { UserDefaults.standard.object(forKey: "sq.graphics.scaleLinked") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sq.graphics.scaleLinked") }
    }

    /// Arrange: 6 align + 2 distribute buttons, "Align To" Frame | Selection (Selection needs 2+ layers).
    private func buildArrange(count n: Int) {
        begin("Arrange", key: "arrange")
        let toFrame = n < 2 || alignToFrame
        let aligns: [(SQIcon, String, GraphicsAlign)] = [
            (.alignLeft, "Align Left", .left), (.alignCenterH, "Align Centers Horizontally", .centerX),
            (.alignRight, "Align Right", .right), (.alignTop, "Align Top", .top),
            (.alignCenterV, "Align Centers Vertically", .centerY), (.alignBottom, "Align Bottom", .bottom),
        ]
        var buttons = aligns.map { s, t, a in iconButton(s, t) { [weak self] in self?.editor.align(a, toFrame: toFrame) } }
        let three = n >= 3
        buttons.append(iconButton(.distributeH, "Distribute Horizontally", enabled: three) { [weak self] in
            self?.editor.distribute(.horizontal)
        })
        buttons.append(iconButton(.distributeV, "Distribute Vertically", enabled: three) { [weak self] in
            self?.editor.distribute(.vertical)
        })
        add(row(buttons))
        let to = SQSegmented(labels: ["Frame", "Selection"], segmentWidth: 64)
        to.selectedSegment = toFrame ? 0 : 1
        to.setEnabled(n >= 2, forSegment: 1)
        to.setAccessibilityLabel("Align To")
        let toTarget = ActionTarget { [weak self, weak to] in
            guard let self, let to else { return }
            alignToFrame = to.selectedSegment == 0
            selectionChanged()
        }
        to.target = toTarget; to.action = #selector(ActionTarget.fire)
        keep(toTarget, on: to)
        add(InspectorRow(title: "Align To", control: to, controlWidth: 128))
    }

    /// Transform of every selected layer: Position, Anchor, Scale X/Y (+ link), Rotation, Opacity, Blend. Empty fields
    /// where the layers differ; an edit sets the value on all of them (one undo step).
    private func buildTransform() {
        begin("Transform", key: "transform")
        let e = editor
        func get(_ p: GraphicsEditor.Property, _ axis: Int = 0, _ k: Double = 1) -> () -> Double? {
            { [weak e] in e?.value(p, axis: axis).map { $0 * k + 0 } }      // + 0: no "-0"
        }
        func set(_ p: GraphicsEditor.Property, _ axis: Int = 0, _ k: Double = 1) -> (Double) -> Void {
            { [weak e] v in e?.setValue(p, axis: axis, v / k) }
        }
        add(numberRow("Position", unit: "px", key: .position, fields: [(get(.position, 0), set(.position, 0)),
                                                                       (get(.position, 1, -1), set(.position, 1, -1))]))      // Y up, 0,0 = centered
        add(numberRow("Anchor", unit: "px", key: .anchor, reset: [0, 0], fields: [(get(.anchor, 0), set(.anchor, 0)),
                                                                                (get(.anchor, 1, -1), set(.anchor, 1, -1))]))
        let scaleSet: (Int) -> (Double) -> Void = { axis in { [weak self, weak e] v in
            guard let self, let e else { return }
            if scaleLinked { e.setScaleLinked(axis: axis, v / 100) } else { e.setValue(.scale, axis: axis, v / 100) }
        } }
        let link = IconButton(symbol: scaleLinked ? .link : .unlink, label: "Link Scale", size: 11) {}
        link.handler = { [weak self, weak link] in
            guard let self, let link else { return }
            scaleLinked.toggle()
            link.isSelected = scaleLinked
            link.setSymbol(scaleLinked ? .link : .unlink, tint: scaleLinked ? Theme.Colors.accent : Theme.Colors.label2, size: 11)
        }
        link.isSelected = scaleLinked
        link.contentTintColor = scaleLinked ? Theme.Colors.accent : Theme.Colors.label2
        add(numberRow("Scale", unit: "%", key: .scale, reset: [100, 100], fields: [(get(.scale, 0, 100), scaleSet(0)),
                                                                               (get(.scale, 1, 100), scaleSet(1))],
                      trailing: link))
        add(numberRow("Rotation", unit: "°", key: .rotation, reset: [0], fields: [(get(.rotation, 0, -1), set(.rotation, 0, -1))]))      // counterclockwise positive
        add(numberRow("Opacity", unit: "%", key: .opacity, reset: [100], fields: [(get(.opacity, 0, 100), set(.opacity, 0, 100))]))
        let blend = SQPopup(frame: .zero, pullsDown: false)
        blend.controlSize = .small
        blend.font = Theme.Typography.body
        blend.addItems(withTitles: BlendMode.allCases.map(\.title))
        let showBlend = { [weak e] in
            if let m = e?.blendMode { blend.selectItem(at: BlendMode.allCases.firstIndex(of: m) ?? 0) } else { blend.select(nil) }
        }
        refreshers.append(showBlend)
        showBlend()
        let blendTarget = ActionTarget { [weak e] in
            let i = blend.indexOfSelectedItem
            if i >= 0, i < BlendMode.allCases.count { e?.beginGesture(); e?.setBlendMode(BlendMode.allCases[i]) }
        }
        blend.target = blendTarget; blend.action = #selector(ActionTarget.fire)
        keep(blendTarget, on: blend)
        add(InspectorRow(title: "Blend", control: blend, controlWidth: 120))
    }

    /// G11 Follow of the single selected layer: what it follows (None, Frame, a layer), which edges, how far apart.
    private func buildFollow() {
        begin("Follow", key: "follow")
        let e = editor
        let current = e.follow
        let targets: [GraphicsFollow.Target?] = [nil, .frame] + e.followCandidates.map { .layer(id: $0.id) }
        let pop = SQPopup(frame: .zero, pullsDown: false)
        pop.controlSize = .small
        pop.font = Theme.Typography.body
        // Through the menu: two layers may share a name (addItems would merge them).
        for t in targets { pop.menu?.addItem(withTitle: e.followTitle(t), action: nil, keyEquivalent: "") }
        pop.selectItem(at: targets.firstIndex { $0 == current?.target } ?? 0)
        pop.sqToolTip = "Keep this layer's edges at another layer's edges or at the frame."
        pop.setAccessibilityLabel("Follows")
        pop.isEnabled = !(e.selectedLayer?.isLocked ?? true)
        let popTarget = ActionTarget { [weak e, weak pop] in
            guard let pop, pop.indexOfSelectedItem >= 0, pop.indexOfSelectedItem < targets.count else { return }
            e?.beginGesture()
            e?.setFollowTarget(targets[pop.indexOfSelectedItem])
        }
        pop.target = popTarget; pop.action = #selector(ActionTarget.fire)
        keep(popTarget, on: pop)
        add(InspectorRow(title: "Follows", control: pop, controlWidth: 128))
        guard let f = current else { return }
        let edges: [(SQIcon, String, GraphicsEdges)] = [
            (.arrowLeftToLine, "Left Edge", .left), (.arrowUpFromLine, "Top Edge", .top),
            (.arrowRightToLine, "Right Edge", .right), (.arrowDownToLine, "Bottom Edge", .bottom),
        ]
        let buttons = edges.map { symbol, title, edge in
            let b = IconButton(symbol: symbol, label: title, size: 12) { [weak e] in e?.beginGesture(); e?.toggleFollowEdge(edge) }
            b.isSelected = f.edges.contains(edge)
            b.isEnabled = pop.isEnabled
            return b
        }
        refreshers.append { [weak e] in
            let on = e?.follow?.edges ?? []
            for (b, edge) in zip(buttons, edges) { b.isSelected = on.contains(edge.2) }
        }
        let strip = NSStackView(views: buttons)
        strip.orientation = .horizontal
        strip.spacing = Theme.Spacing.xs
        add(InspectorRow(title: "Edges", control: strip, controlWidth: 128))
        let d = GraphicsEditor.defaultFollowPadding
        func pad(_ edge: GraphicsEdges, _ path: KeyPath<GraphicsEdgePadding, Double>) -> (get: () -> Double?, set: (Double) -> Void) {
            ({ [weak e] in e?.follow?.resolvedPadding[keyPath: path] }, { [weak e] v in e?.setFollowPadding(v, for: edge) })
        }
        add(numberRow("Padding L / R", unit: "px", key: nil, reset: [d, d],
                      fields: [pad(.left, \.left), pad(.right, \.right)]))
        add(numberRow("Padding T / B", unit: "px", key: nil, reset: [d, d],
                      fields: [pad(.top, \.top), pad(.bottom, \.bottom)]))
    }

    /// Kind tag for the structure key (a kind change rebuilds the Shape rows).
    static func kindTag(_ l: GraphicsLayer) -> String { GraphicsPanelLogic.kindTag(l) }

    /// Lines, arrows and open paths have a length and no fill.
    private static func isLineLike(_ l: GraphicsLayer) -> Bool { GraphicsPanelLogic.isLineLike(l) }

    /// Shape: Kind (shape layers), Width / Height or Length, Corners (rectangles); every number keyable.
    private func buildShape(_ layers: [GraphicsLayer]) {
        begin("Shape", key: "shape")
        let e = editor
        let isLine = layers.allSatisfy(Self.isLineLike)
        let isRect = layers.allSatisfy { if case .shape(.rectangle) = $0.content { true } else { false } }
        if layers.allSatisfy({ if case .shape = $0.content { true } else { false } }) {
            let kinds = ShapeKind.allCases
            let pop = SQPopup(frame: .zero, pullsDown: false)
            pop.controlSize = .small
            pop.font = Theme.Typography.body
            pop.addItems(withTitles: kinds.map(\.title))
            if let k = e.shapeKind { pop.selectItem(at: kinds.firstIndex(of: k) ?? 0) } else { pop.select(nil) }
            let t = ActionTarget { [weak self, weak e] in
                let i = pop.indexOfSelectedItem
                guard i >= 0, i < kinds.count else { return }
                e?.beginGesture(); e?.setShapeKind(kinds[i]); self?.selectionChanged()
            }
            pop.target = t; pop.action = #selector(ActionTarget.fire)
            keep(t, on: pop)
            add(InspectorRow(title: "Kind", control: pop, controlWidth: 120))
        }
        func shapeRow(_ title: String, _ key: String) -> NSView {
            let p = GraphicsEditor.Property.shape(key)
            let def = EffectCatalog.param(ClipEffect.shapeEffectKind, key)?.defaultValue
            return numberRow(title, unit: "px", key: p, decimals: 0, reset: def.map { [$0] },
                             fields: [({ [weak e] in e?.value(p) }, { [weak e] v in e?.setValue(p, max(v, 0)) })])
        }
        if isLine {
            add(shapeRow("Length", ClipEffect.shapeWidthKey))
        } else {
            add(shapeRow("Width", ClipEffect.shapeWidthKey))
            add(shapeRow("Height", ClipEffect.shapeHeightKey))
        }
        if isRect { add(shapeRow("Corners", ClipEffect.shapeCornerRadiusKey)) }
    }

    /// Appearance of shape layers on the text block's `AppearanceRow`: Fill, Outline, Shadow (a drop shadow in the layer's
    /// effects). Check, color, main value inline; the chevron opens the keyable detail rows.
    private func buildAppearance(_ layers: [GraphicsLayer]) {
        begin("Appearance", key: "appearance")
        let e = editor
        let shadow = ClipEffect.dropShadowKind
        if !layers.allSatisfy(Self.isLineLike) {
            let fill = appearanceRow("fill", "Fill")
            bound(GraphicAppearanceBinding.bindFill(fill, editor: { [weak e] in e }))
            add(fill)
        }
        let widthP = GraphicsEditor.Property.shape(ClipEffect.shapeStrokeWidthKey)
        let outline = appearanceRow("outline", "Outline")
        bound(GraphicAppearanceBinding.bindOutline(outline, editor: { [weak e] in e }))
        detail(outline, numberRow("Width", unit: "px", key: widthP, reset: [8],
                                  fields: [({ [weak e] in e?.value(widthP) }, { [weak e] v in e?.setValue(widthP, max(v, 0)) })]))
        add(outline)
        func fx(_ key: String) -> GraphicsEditor.Property { .effect(kind: shadow, key: key) }
        let shadowRow = appearanceRow("shadow", "Shadow")
        bound(GraphicAppearanceBinding.bind(
            shadowRow, title: "Shadow", editor: e,
            on: { [weak e] in e?.shadowState },
            setOn: { [weak self, weak e] on in e?.setShadow(on); self?.selectionChanged() },
            colorKind: shadow, colorKey: ClipEffect.shadowColorKey,
            value: { [weak e] in e?.value(fx(ClipEffect.shadowOpacityKey)) },
            setValue: { [weak e] v in e?.setValue(fx(ClipEffect.shadowOpacityKey), min(max(v, 0), 100)) },
            unit: "%", reset: 50))
        if layers.allSatisfy({ l in l.effects.contains { $0.kind == shadow } }) {
            for (title, key, unit) in [("Opacity", ClipEffect.shadowOpacityKey, "%"), ("Angle", ClipEffect.shadowDirectionKey, "°"),
                                       ("Distance", ClipEffect.shadowDistanceKey, "px"), ("Blur", ClipEffect.shadowSoftnessKey, "px")] {
                let p = fx(key)
                let spec = EffectCatalog.param(shadow, key)
                detail(shadowRow, numberRow(title, unit: unit, key: p, decimals: 0, reset: spec.map { [$0.defaultValue] }, fields: [
                    ({ [weak e] in e?.value(p) }, { [weak e] v in
                        e?.setValue(p, spec.map { min(max(v, $0.range.lowerBound), $0.range.upperBound) } ?? v) }),
                ]))
            }
        }
        add(shadowRow)
    }

    /// Stored color (sRGB components) to and from the well.
    static func nsColor(_ c: EffectColor) -> NSColor { Theme.ColorBridge.ns(c) }
    static func effectColor(_ n: NSColor) -> EffectColor? {
        Theme.ColorBridge.effectColor(n)
    }

    private func detail(_ row: AppearanceRow, _ v: NSView) {
        row.detail.append(v)
        if v is InspectorRow { v.heightAnchor.constraint(equalToConstant: Theme.Inspector.rowHeight).isActive = true }
    }

    /// One `AppearanceRow` bound to the selected layers: `on` / color / value read nil when the layers differ (dash,
    /// empty swatch, empty field). Each control is one undo step per gesture.
    /// The wiring is `GraphicAppearanceBinding`'s (shared with Controls > Graphic); its loader goes to `bound`.
    private func appearanceRow(_ key: String, _ title: String) -> AppearanceRow {
        let row = AppearanceRow(key: "graphics.\(key)", title: title, hasCheck: true)
        row.onLayoutChange = { [weak self] in self?.stack.needsLayout = true }
        return row
    }

    /// Keeps a bound row's loader with the refreshers and loads it once.
    private func bound(_ load: @escaping () -> Void) {
        refreshers.append(load)
        load()
    }

    /// The shared text block (same as Controls and Captions > Look) drives the layer's text template: the text box edits
    /// `text`, every other control edits `style`. Refreshes load the template back unless a gesture is open.
    private func buildText() {
        let e = editor
        let model = TextInspectorModel()
        let block = TextBlockView(model: model, context: .graphics)
        model.keystones = keystones
        block.onNotice = { [weak self] m in if let show = self?.onNotice { show(m) } else { TextBlockView.noticeDialog(m) } }
        textModel = model; textBlock = block
        var gestureOpen = false
        model.onBeginEditing = { [weak e] in gestureOpen = true; e?.beginGesture() }
        model.onEndEditing = { gestureOpen = false }
        model.onChange = { [weak e] style, anims in
            if e?.textAnimations != anims { e?.updateText("Text Animation", animations: anims) { $0.style = style } }
            else { e?.updateText("Text Style") { $0.style = style } }
        }
        block.onTextBegin = { [weak e] in e?.beginGesture() }
        block.onTextChange = { [weak e] s in e?.updateText("Edit Text") { $0.text = s } }
        let load = { [weak e, weak block] in
            guard let t = e?.textTemplate else { return }
            model.target = e?.selectedLayer?.id
            let anims = e?.textAnimations ?? AnimationSet(in: nil, out: nil)
            model.frameSize = AnimationChoices.frameSize(e?.session.displayFormat)
            if !gestureOpen, model.style != t.style || model.animations != anims { model.load(style: t.style, animations: anims) }
            if block?.text != t.text { block?.text = t.text }
        }
        refreshers.append(load)
        load()
        stack.addArrangedSubview(block)
        block.translatesAutoresizingMaskIntoConstraints = false
        block.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        section = nil
    }

    // MARK: Layer effects

    /// One section per effect on the layer, only when there is one (effects are added by dropping them from the Effects
    /// panel on a layer row or on this panel). The header carries the enable toggle and the remove button.
    private func buildEffects(_ layer: GraphicsLayer) {
        let e = editor
        let appearanceShadow = layer.isText ? nil : layer.effects.first { $0.kind == ClipEffect.dropShadowKind }?.id
        for fx in layer.effects where !EffectCatalog.isGeneratorOwned(fx.kind) && fx.id != appearanceShadow {
            guard let spec = EffectCatalog.spec(for: fx.kind) else { continue }
            begin(spec.title, key: "fx.\(fx.kind)", enableToggle: true)
            if let header = section?.header, let on = header.enableToggle {
                header.isEnabledToggleOn = fx.enabled
                header.onToggleEnabled = { [weak e] state in e?.setEffectEnabled(fx.id, state) }
                on.setAccessibilityLabel("Enable \(spec.title)")
                let remove = iconButton(.minusCircle, SQL10n.format("Remove %@", SQL10n.string(spec.title))) { [weak e] in e?.removeEffect(fx.id) }
                header.addAccessory(remove)
            }
            for p in spec.params {
                let getFx = { [weak e] in e?.selectedLayer?.effects.first { $0.id == fx.id } }
                switch p.kind {
                case .slider:
                    let prop = EffectProperty.fx(fx.id, kind: fx.kind, key: p.key)      // the display boundary: scale and sign
                    add(numberRow(p.title, unit: p.unit, key: .effect(kind: fx.kind, key: p.key, id: fx.id), decimals: p.decimals,
                                  reset: [prop.display(p.defaultValue)], fields: [
                        ({ [weak e] in prop.display(getFx()?.scalar(p.key, atLocal: e?.localTime ?? .zero) ?? p.defaultValue) },
                         { [weak e] v in e?.setEffectValue(fx.id, key: p.key, min(max(prop.native(fromDisplay: v), p.range.lowerBound), p.range.upperBound)) }),
                    ]))
                case .checkbox:
                    let b = SQCheckbox(title: "", target: nil, action: nil)
                    b.font = Theme.Typography.body; b.controlSize = .small
                    let bt = ActionTarget { [weak e] in e?.beginGesture(); e?.setEffectValue(fx.id, key: p.key, b.state == .on ? 1 : 0) }
                    b.target = bt; b.action = #selector(ActionTarget.fire)
                    keep(bt, on: b)
                    refreshers.append { [weak e] in b.state = (getFx()?.scalar(p.key, atLocal: e?.localTime ?? .zero) ?? 0) >= 0.5 ? .on : .off }
                    refreshers.last?()
                    add(InspectorRow(title: p.title, control: b, controlWidth: 24))
                case .choice(let titles):
                    let pop = SQPopup(frame: .zero, pullsDown: false)
                    pop.controlSize = .small; pop.font = Theme.Typography.body
                    pop.addItems(withTitles: titles)
                    let pt = ActionTarget { [weak e] in e?.beginGesture(); e?.setEffectValue(fx.id, key: p.key, Double(pop.indexOfSelectedItem)) }
                    pop.target = pt; pop.action = #selector(ActionTarget.fire)
                    keep(pt, on: pop)
                    refreshers.append { [weak e] in pop.selectItem(at: Int((getFx()?.scalar(p.key, atLocal: e?.localTime ?? .zero) ?? 0).rounded())) }
                    refreshers.last?()
                    add(InspectorRow(title: p.title, control: pop, controlWidth: 120))
                case .color(let def):
                    let well = colorWell { [weak e] c in e?.setEffectColor(fx.id, key: p.key, c) }
                    refreshers.append { [weak e] in
                        let c = getFx()?.colors[p.key]?.value(atLocal: e?.localTime ?? .zero) ?? def
                        if !well.isActive { well.color = Self.nsColor(c) }
                    }
                    refreshers.last?()
                    add(InspectorRow(title: p.title, control: well, controlWidth: Theme.Row.swatch.width))
                case .point(let def):
                    let pk = GraphicsEditor.Property.effectPoint(kind: fx.kind, key: p.key, id: fx.id)
                    let sign = { (i: Int) in EffectProperty.fx(fx.id, kind: fx.kind, key: p.key).displaySign(component: i == 0 ? .x : .y) }
                    func axis(_ i: Int) -> (get: () -> Double?, set: (Double) -> Void) {
                        let k = sign(i)
                        return ({ [weak e] in
                            guard let v = getFx()?.points[p.key]?.value(atLocal: e?.localTime ?? .zero) else { return (i == 0 ? def.x : def.y) * k + 0 }
                            return (i == 0 ? v.x : v.y) * k + 0
                        }, { [weak e] v in e?.setValue(pk, axis: i, v * k) })
                    }
                    add(numberRow(p.title, unit: "px", key: pk, reset: [def.x * sign(0) + 0, def.y * sign(1) + 0], fields: [axis(0), axis(1)]))
                }
            }
        }
        let addButton = SQButton(title: "Add Effect…", target: nil, action: nil, style: .standard)
        let addTarget = ActionTarget { [weak self, weak addButton] in if let b = addButton { self?.presentAddEffectMenu(from: b) } }
        addButton.target = addTarget; addButton.action = #selector(ActionTarget.fire)
        addButton.setAccessibilityLabel("Add Effect")
        keep(addTarget, on: addButton)
        let presetButton = SQButton(title: "Presets…", target: nil, action: nil, style: .standard)
        let presetTarget = ActionTarget { [weak self, weak presetButton] in if let b = presetButton { self?.presentEffectPresetMenu(from: b) } }
        presetButton.target = presetTarget; presetButton.action = #selector(ActionTarget.fire)
        presetButton.setAccessibilityLabel("Layer Effect Presets")
        keep(presetTarget, on: presetButton)
        begin("Effects", key: "fxAdd")
        add(row([addButton, presetButton]))
    }

    /// Keyboard and click path to add an effect to the selected layer: an SQ menu of the offered catalog.
    private func presentAddEffectMenu(from anchor: NSView) {
        let e = editor
        let items = GraphicsEditor.offeredEffects.map { spec in
            SQMenuItem(title: spec.title) { [weak self, weak e] in
                guard let e else { return }
                self?.showDrop(e.addEffect(spec.kind))
            }
        }
        guard !items.isEmpty, let window = anchor.window else { return }
        let r = anchor.convert(anchor.bounds, to: nil)
        SQMenuController.shared.present(items: items, at: window.convertPoint(toScreen: NSPoint(x: r.minX, y: r.minY)))
    }

    /// Library effect presets onto the selected layer, plus saving the layer's effects as a new preset.
    private func presentEffectPresetMenu(from anchor: NSView) {
        let e = editor
        var items = (effectPresets?() ?? []).map { entry in
            SQMenuItem(title: entry.name) { [weak self, weak e] in
                guard let e else { return }
                self?.showDrop(e.applyEffectPreset(entry.preset, name: entry.name))
            }
        }
        if !items.isEmpty { items.append(.separator) }
        let canSave = e.layerEffectPreset() != nil
        items.append(SQMenuItem(title: "Save Effects as Preset…", isEnabled: canSave) { [weak self, weak e] in
            if let p = e?.layerEffectPreset() { self?.onSaveEffectPreset?(p) }
        })
        guard let window = anchor.window else { return }
        let r = anchor.convert(anchor.bounds, to: nil)
        SQMenuController.shared.present(items: items, at: window.convertPoint(toScreen: NSPoint(x: r.minX, y: r.minY)))
    }

    // MARK: Controls

    private static func symbol(_ k: ShapeKind) -> SQIcon {
        switch k {
        case .rectangle: .shapeRectangle
        case .ellipse: .shapeEllipse
        case .line: .shapeLine
        case .arrow: .arrowUpRight
        }
    }

    private var section: InspectorSection?

    /// Starts a collapsible section (state kept under `sq.inspector.open.graphics.<key>`); `add` fills it.
    private func begin(_ title: String, key: String, enableToggle: Bool = false) {
        let sec = InspectorSection(title: title, key: "graphics.\(key)", hasEnableToggle: enableToggle)
        sec.header.showsTopLine = !stack.arrangedSubviews.isEmpty
        stack.addArrangedSubview(sec)
        section = sec
    }

    private func add(_ v: NSView) {
        guard let section else { stack.addArrangedSubview(v); return }
        section.addRow(v)
        if v is InspectorRow { v.heightAnchor.constraint(equalToConstant: Theme.Inspector.rowHeight).isActive = true }
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = Theme.Spacing.xs
        r.alignment = .centerY
        r.edgeInsets = NSEdgeInsets(top: Theme.Spacing.xs, left: ControlsGrid.toggleX, bottom: Theme.Spacing.xs, right: Theme.Inspector.trailing)
        return r
    }

    private func iconButton(_ symbol: SQIcon, _ title: String, command: EditorCommand? = nil, enabled: Bool = true,
                            _ action: @escaping () -> Void) -> IconButton {
        let b = IconButton(symbol: symbol, label: title, command: command, size: 12, handler: action)
        b.isEnabled = enabled
        return b
    }

    private func colorWell(_ onChange: @escaping (EffectColor) -> Void) -> SQColorWell {
        let well = SQColorWell()
        well.showsAlpha = true
        let e = editor
        well.onOpen = { [weak e] in e?.beginGesture() }        // one undo step per picker session
        let t = ActionTarget {
            guard let c = Self.effectColor(well.color) else { return }
            onChange(c)
        }
        well.target = t; well.action = #selector(ActionTarget.fire)
        keep(t, on: well)
        _ = e
        return well
    }

    /// A titled `InspectorRow` of ScrubFields (drag, click to type, arrows step, double-click resets to `reset`), with the
    /// keyed look (`isAnimated`) when `key` is a layer Motion property. Keys are set in Controls only (one system); this
    /// panel edits the value at the playhead. Each gesture is one undo step.
    private func numberRow(_ title: String, unit: String, key: GraphicsEditor.Property?, decimals: Int = 1,
                           reset: [Double]? = nil, fields: [(get: () -> Double?, set: (Double) -> Void)],
                           trailing: NSView? = nil) -> NSView {
        let e = editor
        var scrubs: [ScrubField] = []
        for (i, f) in fields.enumerated() {
            let field = ScrubField()
            field.isPlain = true
            field.decimals = decimals
            field.step = decimals >= 2 ? 0.01 : 1
            field.unit = unit
            field.setAccessibilityLabel(fields.count > 1 ? "\(title) \(i == 0 ? "X" : "Y")" : title)
            if let reset, i < reset.count { field.defaultValue = reset[i] }
            field.onBegin = { [weak e] in e?.beginGesture() }
            field.onChange = { v in f.set(v) }
            refreshers.append {
                guard !field.isEditing && !field.isDragging else { return }
                let v = f.get()
                field.isMixed = v == nil       // several layers that differ: an empty field
                if let v { field.value = v }
            }
            refreshers.last?()
            scrubs.append(field)
        }
        let control: NSView
        if scrubs.count == 1 && trailing == nil { control = scrubs[0] } else {
            let h = NSStackView(views: scrubs)
            h.orientation = .horizontal
            h.distribution = .fillEqually
            h.spacing = Theme.Spacing.xs
            if let trailing {
                let outer = NSStackView(views: [h, trailing])
                outer.orientation = .horizontal
                outer.spacing = Theme.Spacing.xs
                trailing.widthAnchor.constraint(equalToConstant: Theme.Inspector.iconSlot).isActive = true
                control = outer
            } else { control = h }
        }
        if let key {
            refreshers.append { [weak e] in
                guard let e else { return }
                let animated = e.keyframeState(key).showsNavigation
                scrubs.forEach { $0.isAnimated = animated }
            }
            refreshers.last?()
        }
        let width = CGFloat(fields.count) * 64 + CGFloat(max(fields.count - 1, 0)) * Theme.Spacing.xs
            + (trailing == nil ? 0 : Theme.Spacing.xs + Theme.Inspector.iconSlot)
        return InspectorRow(title: title, control: control, controlWidth: width)
    }

    private func keep(_ t: ActionTarget, on v: NSView) {
        objc_setAssociatedObject(v, &ActionTarget.key, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

/// Closure target for AppKit controls (retained by the control through an associated object).
@MainActor
final class ActionTarget: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// Top-down stack for the scroll view's document.
final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }

    /// Inspector rows and empty states take the full inner width (the stack's insets each side), rows
    /// their fixed height.
    override func addArrangedSubview(_ view: NSView) {
        super.addArrangedSubview(view)
        guard view is InspectorSection || view is InspectorRow || view is EmptyStateView else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: widthAnchor, constant: -(edgeInsets.left + edgeInsets.right)).isActive = true
        if view is InspectorRow { view.heightAnchor.constraint(equalToConstant: Theme.Inspector.rowHeight).isActive = true }
    }
}

/// The drag handle between the pinned layer list and the properties: a 1 pt hairline with a wider grab area.
@MainActor
final class ListResizeHandle: NSView {
    static let grab: CGFloat = 7
    var onDrag: ((CGFloat) -> Void)?
    private let line = SQDivider()
    private var last: CGFloat?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Layer list height")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        line.frame = NSRect(x: 0, y: (bounds.height - Theme.Separator.width) / 2, width: bounds.width, height: Theme.Separator.width)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with event: NSEvent) { last = event.locationInWindow.y }
    override func mouseDragged(with event: NSEvent) {
        guard let l = last else { return }
        let y = event.locationInWindow.y
        onDrag?(l - y)              // window coordinates grow upwards: dragging down makes the list taller
        last = y
    }
    override func mouseUp(with event: NSEvent) { last = nil }
}

/// Tiny hover helper: one `.inVisibleRect` tracking area (it follows the view, no `updateTrackingAreas` override).
@MainActor
final class HoverTracker: NSObject {
    private let onChange: (Bool) -> Void
    init(view: NSView, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init()
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                            owner: self, userInfo: nil))
    }
    @objc func mouseEntered(_ event: NSEvent) { onChange(true) }
    @objc func mouseExited(_ event: NSEvent) { onChange(false) }
}
