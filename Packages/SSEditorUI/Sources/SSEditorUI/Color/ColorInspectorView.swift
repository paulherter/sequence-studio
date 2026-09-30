import AppKit
import Observation
import SSCore
import SSRender
import UniformTypeIdentifiers

/// NSSlider that resets to the default on double-click (Premiere) and brackets a drag as one gesture.
final class ResettableSlider: NSSlider {
    var onReset: (() -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        onBegin?()
        super.mouseDown(with: event)   // runs the tracking loop; returns after mouse-up
        onEnd?()
    }
}

/// One slider row: title, slider, number. Double-click the slider to reset it.
@MainActor
final class ColorParamRow: NSStackView {
    let param: ColorParam
    let slider: ResettableSlider
    let field = NSTextField(string: "")
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    /// A value the user chose (slider drag or typed).
    var onSet: ((Float) -> Void)?
    var onReset: (() -> Void)?

    init(_ p: ColorParam) {
        param = p
        slider = ResettableSlider(value: Double(p.neutral), minValue: Double(p.range.lowerBound),
                                  maxValue: Double(p.range.upperBound), target: nil, action: nil)
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: p.title)
        title.font = Theme.Fonts.small
        title.textColor = Theme.Colors.label2
        title.widthAnchor.constraint(equalToConstant: 82).isActive = true
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.onBegin = { [weak self] in self?.onBegin?() }
        slider.onEnd = { [weak self] in self?.onEnd?() }
        slider.onReset = { [weak self] in self?.onReset?() }
        slider.setAccessibilityLabel(p.title)
        field.controlSize = .small
        field.font = Theme.Fonts.small
        field.alignment = .right
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(fieldEntered)
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        setViews([title, slider, field], in: .leading)
        orientation = .horizontal
        alignment = .centerY
        spacing = Theme.Spacing.sm
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func sliderMoved() {
        var v = Float(slider.doubleValue)
        if param.decimals == 0 { v = v.rounded() }
        onSet?(v)
    }

    @objc private func fieldEntered() {
        onBegin?()
        onSet?(field.floatValue)
        onEnd?()
    }

    func show(_ v: Float) {
        if slider.doubleValue != Double(v) { slider.doubleValue = Double(v) }
        if field.currentEditor() == nil { field.stringValue = String(format: "%.\(param.decimals)f", v) }
    }
}

/// Header of a block: disclosure arrow, enable checkbox, title (drag to reorder), extra control, Reset, menu.
@MainActor
final class ColorSectionHeader: NSStackView, NSDraggingSource {
    let sectionID: Int
    let disclosure = NSButton()
    let enable = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let title: NSTextField
    let reset = NSButton(title: "Reset", target: nil, action: nil)
    let moreButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var pressPoint: NSPoint?

    init(id: Int, kind: ColorSectionKind) {
        sectionID = id
        title = NSTextField(labelWithString: kind.title)
        super.init(frame: .zero)
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        disclosure.controlSize = .small
        disclosure.setAccessibilityLabel("Show \(kind.title)")
        enable.controlSize = .small
        enable.toolTip = "Enable / disable \(kind.title)"
        title.font = Theme.Fonts.bodyTitle
        title.textColor = Theme.Colors.label
        reset.controlSize = .small
        reset.bezelStyle = .accessoryBarAction
        reset.font = Theme.Fonts.small
        moreButton.controlSize = .small
        moreButton.isBordered = false
        moreButton.addItem(withTitle: "")
        moreButton.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        moreButton.setContentHuggingPriority(.required, for: .horizontal)
        setViews([disclosure, enable, title, NSView(), reset, moreButton], in: .leading)
        orientation = .horizontal
        alignment = .centerY
        spacing = Theme.Spacing.xs
        toolTip = "Drag to reorder"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func mouseDown(with event: NSEvent) { pressPoint = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        pressPoint = nil
        let item = NSPasteboardItem()
        item.setString(String(sectionID), forType: ColorSectionsStack.dragType)
        let drag = NSDraggingItem(pasteboardWriter: item)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            let img = NSImage(size: bounds.size)
            img.addRepresentation(rep)
            drag.setDraggingFrame(bounds, contents: img)
        } else {
            drag.draggingFrame = bounds
        }
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { pressPoint = nil }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
}

/// The vertical stack of blocks; accepts a header dragged onto it and reports the new position.
@MainActor
final class ColorSectionsStack: NSStackView {
    static let dragType = NSPasteboard.PasteboardType("com.sequencestudio.color-section")
    /// (section id, index in the list after the section is taken out)
    var onMove: ((Int, Int) -> Void)?
    private var indicator: CGFloat?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.dragType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func sectionViews() -> [ColorSectionView] { arrangedSubviews.compactMap { $0 as? ColorSectionView } }

    /// Insertion slot for a pointer at `y`: the number of other blocks whose middle lies above it.
    static func slot(midYs: [CGFloat], y: CGFloat) -> Int { midYs.filter { $0 < y }.count }

    private func dragged(_ info: NSDraggingInfo) -> Int? {
        info.draggingPasteboard.string(forType: Self.dragType).flatMap { Int($0) }
    }

    private func layoutSlot(_ info: NSDraggingInfo) -> (id: Int, slot: Int, lineY: CGFloat)? {
        guard let id = dragged(info) else { return nil }
        let y = convert(info.draggingLocation, from: nil).y
        let others = sectionViews().filter { $0.section != id }
        let slot = Self.slot(midYs: others.map(\.frame.midY), y: y)
        let line = slot == 0 ? (others.first?.frame.minY ?? 0) : others[slot - 1].frame.maxY
        return (id, slot, line)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let s = layoutSlot(sender) else { return [] }
        indicator = s.lineY
        needsDisplay = true
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { indicator = nil; needsDisplay = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { indicator = nil; needsDisplay = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { indicator = nil; needsDisplay = true }
        guard let s = layoutSlot(sender) else { return false }
        onMove?(s.id, s.slot)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let y = indicator {
            Theme.Colors.accent.setFill()
            NSRect(x: 0, y: y - 1, width: bounds.width, height: 2).fill()
        }
    }
}

/// One block: header plus (for blocks with controls) a body that collapses.
@MainActor
final class ColorSectionView: NSStackView {
    let section: Int
    let kind: ColorSectionKind
    let header: ColorSectionHeader
    let body = NSStackView()
    var rows: [ColorParam: ColorParamRow] = [:]
    var wheels: [ColorWheelSlot: ColorWheelControl] = [:]
    var lutPopup: NSPopUpButton?
    var lutPicks: [LUTPick] = []
    var curveEditor: CurveEditorView?
    var curveChannel: NSSegmentedControl?
    var selectedChannel = 0

    enum LUTPick { case choice(ColorInspectorModel.LUTChoice?), chooseFile }

    init(id: Int, kind: ColorSectionKind) {
        section = id
        self.kind = kind
        header = ColorSectionHeader(id: id, kind: kind)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Theme.Spacing.sm
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = Theme.Spacing.sm
        body.edgeInsets = NSEdgeInsets(top: 0, left: Theme.Spacing.lg, bottom: Theme.Spacing.xs, right: 0)
        addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        if kind != .inputLUT {
            addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        } else {
            header.disclosure.isHidden = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
}

/// Color page inspector: "Interpret as", a "+" menu and the ordered stack of colour blocks (Lumetri-like, modular).
/// Default stack: Basic Correction, then the Input LUT with its popup right in the header row. Blocks collapse
/// (disclosure arrow), enable/disable, reset, reorder (drag the title) and can be added or removed.
@MainActor
public final class ColorInspectorView: NSView {
    public let model: ColorInspectorModel

    private let stack = NSStackView()
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let sectionsStack = ColorSectionsStack()
    private var sectionViews: [Int: ColorSectionView] = [:]
    private var builtSignature: [BuiltKey] = []

    private struct BuiltKey: Equatable { var id: Int; var kind: ColorSectionKind; var collapsed: Bool }

    /// Index 0 of the source popup is "Automatic (<detected>)", then these.
    private static let sources: [(String, ColorSpaceID)] = [
        ("Rec. 709", .rec709), ("S-Log3 / S-Gamut3.Cine", .sLog3SGamut3Cine), ("HLG / Rec. 2020", .hlgBT2020),
    ]
    private static func name(_ id: ColorSpaceID) -> String { sources.first { $0.1 == id }?.0 ?? "" }

    public init(model: ColorInspectorModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 640))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        build()
        rebuildSections()
        refresh()
        observe()
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Build

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.md
        stack.edgeInsets = NSEdgeInsets(top: Theme.Spacing.md, left: Theme.Spacing.md, bottom: Theme.Spacing.md, right: Theme.Spacing.md)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Interpret as + add menu in one row.
        style(sourcePopup)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        let interpret = NSTextField(labelWithString: "Interpret as")
        interpret.font = Theme.Fonts.small
        interpret.textColor = Theme.Colors.label2
        addButton.controlSize = .small
        addButton.font = Theme.Fonts.small
        addButton.addItem(withTitle: "+ Add")
        for k in ColorSectionKind.addable {
            let item = NSMenuItem(title: k.title, action: #selector(addSection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = k.rawValue
            addButton.menu?.addItem(item)
        }
        addButton.setAccessibilityLabel("Add colour block")
        let top = NSStackView(views: [interpret, sourcePopup, addButton])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = Theme.Spacing.sm
        add(top)

        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = Theme.Spacing.md
        sectionsStack.onMove = { [weak self] id, dest in self?.model.moveSection(id, to: dest) }
        add(sectionsStack)
    }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.md).isActive = true
    }

    private func style(_ popup: NSPopUpButton) {
        popup.controlSize = .small
        popup.font = Theme.Fonts.small
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = Theme.Fonts.mini
        l.textColor = Theme.Colors.label3
        return l
    }

    // MARK: Sections

    private func signature() -> [BuiltKey] {
        model.sections.map { BuiltKey(id: $0.id, kind: $0.kind, collapsed: model.isCollapsed($0.id)) }
    }

    /// Rebuilds all blocks (structure changed: add, remove, reorder, collapse).
    private func rebuildSections() {
        for v in sectionsStack.arrangedSubviews { sectionsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        sectionViews = [:]
        for s in model.sections {
            let v = makeSection(s)
            sectionViews[s.id] = v
            sectionsStack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor).isActive = true
        }
        builtSignature = signature()
    }

    private func makeSection(_ s: ColorSection) -> ColorSectionView {
        let id = s.id
        let v = ColorSectionView(id: id, kind: s.kind)
        let h = v.header
        h.enable.target = self; h.enable.action = #selector(enableToggled(_:)); h.enable.tag = id
        h.reset.target = self; h.reset.action = #selector(resetPressed(_:)); h.reset.tag = id
        h.disclosure.target = self; h.disclosure.action = #selector(disclosureToggled(_:)); h.disclosure.tag = id
        h.disclosure.state = model.isCollapsed(id) ? .off : .on
        let up = NSMenuItem(title: "Move Up", action: #selector(moveBlockUp(_:)), keyEquivalent: ""); up.tag = id; up.target = self
        let down = NSMenuItem(title: "Move Down", action: #selector(moveBlockDown(_:)), keyEquivalent: ""); down.tag = id; down.target = self
        h.moreButton.menu?.addItem(up); h.moreButton.menu?.addItem(down)
        if s.kind != .inputLUT {
            let rm = NSMenuItem(title: "Remove", action: #selector(removePressed(_:)), keyEquivalent: ""); rm.tag = id; rm.target = self
            h.moreButton.menu?.addItem(.separator()); h.moreButton.menu?.addItem(rm)
        }

        switch s.kind {
        case .inputLUT:
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            style(popup)
            popup.target = self; popup.action = #selector(lutChosen(_:)); popup.tag = id
            popup.setAccessibilityLabel("Input LUT")
            h.insertArrangedSubview(popup, at: 3)
            h.setCustomSpacing(Theme.Spacing.sm, after: h.title)
            v.lutPopup = popup
        case .basicCorrection, .vignette:
            addParamRows(v, kind: s.kind)
        case .creative:
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            style(popup)
            popup.target = self; popup.action = #selector(lutChosen(_:)); popup.tag = id
            popup.setAccessibilityLabel("Look")
            v.lutPopup = popup
            v.body.addArrangedSubview(labelled("Look", popup))
            addParamRows(v, kind: .creative)
            let tints = NSStackView()
            tints.orientation = .horizontal
            tints.spacing = Theme.Spacing.md
            for slot in [ColorWheelSlot.shadowTint, .highlightTint] { tints.addArrangedSubview(wheel(v, slot, showsMaster: false)) }
            v.body.addArrangedSubview(tints)
            append(paramRow(v, .tintBalance), to: v)
        case .wheels:
            let w = NSStackView()
            w.orientation = .horizontal
            w.spacing = Theme.Spacing.sm
            for slot in [ColorWheelSlot.shadows, .midtones, .highlights] { w.addArrangedSubview(wheel(v, slot, showsMaster: true)) }
            v.body.addArrangedSubview(w)
            addParamRows(v, kind: .wheels)
        case .curves:
            let seg = NSSegmentedControl(labels: ["Master", "R", "G", "B"], trackingMode: .selectOne, target: self, action: #selector(curveChannelChosen(_:)))
            seg.controlSize = .small
            seg.selectedSegment = 0
            seg.tag = id
            v.curveChannel = seg
            let editor = CurveEditorView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
            editor.translatesAutoresizingMaskIntoConstraints = false
            editor.heightAnchor.constraint(equalToConstant: 150).isActive = true
            editor.onBegin = { [weak self] in self?.model.onGestureBegan?() }
            editor.onEnd = { [weak self] in self?.model.onGestureEnded?() }
            editor.onChange = { [weak self, weak v] pts in
                guard let self, let v else { return }
                var c = self.model.curves(id)
                switch v.selectedChannel { case 1: c.red = pts; case 2: c.green = pts; case 3: c.blue = pts; default: c.master = pts }
                self.model.setCurves(id, c)
            }
            v.curveEditor = editor
            v.body.addArrangedSubview(seg)
            v.body.addArrangedSubview(editor)
            editor.widthAnchor.constraint(equalTo: v.body.widthAnchor, constant: -Theme.Spacing.lg).isActive = true
        }
        v.body.isHidden = model.isCollapsed(id)
        return v
    }

    private func labelled(_ name: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: name)
        l.font = Theme.Fonts.small
        l.textColor = Theme.Colors.label2
        l.widthAnchor.constraint(equalToConstant: 82).isActive = true
        let r = NSStackView(views: [l, control])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = Theme.Spacing.sm
        return r
    }

    private func addParamRows(_ v: ColorSectionView, kind: ColorSectionKind) {
        for g in ColorParam.layout(for: kind) {
            if let name = g.group { v.body.addArrangedSubview(caption(name)) }
            for p in g.params { append(paramRow(v, p), to: v) }
        }
    }

    /// Adds a row to the block's body and sizes it to the body width (the constraint needs the shared superview).
    private func append(_ row: NSView, to v: ColorSectionView) {
        v.body.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: v.body.widthAnchor, constant: -Theme.Spacing.lg).isActive = true
    }

    private func paramRow(_ v: ColorSectionView, _ p: ColorParam) -> ColorParamRow {
        let id = v.section
        let r = ColorParamRow(p)
        r.onBegin = { [weak self] in self?.model.onGestureBegan?() }
        r.onEnd = { [weak self] in self?.model.onGestureEnded?() }
        r.onSet = { [weak self] value in self?.model.set(id, p, value) }
        r.onReset = { [weak self] in self?.model.resetParameter(id, p) }
        v.rows[p] = r
        return r
    }

    private func wheel(_ v: ColorSectionView, _ slot: ColorWheelSlot, showsMaster: Bool) -> ColorWheelControl {
        let id = v.section
        let w = ColorWheelControl(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        w.title = slot.title
        w.showsMaster = showsMaster
        w.translatesAutoresizingMaskIntoConstraints = false
        w.widthAnchor.constraint(equalToConstant: showsMaster ? 82 : 76).isActive = true
        w.heightAnchor.constraint(equalToConstant: 92).isActive = true
        w.onBegin = { [weak self] _ in self?.model.onGestureBegan?() }
        w.onEnd = { [weak self] _ in self?.model.onGestureEnded?() }
        w.onChange = { [weak self, weak w] part in
            guard let self, let w else { return }
            switch part {
            case .wheel: self.model.setWheel(id, slot, hue: Float(w.hue), amount: Float(w.amount))
            case .master: self.model.setWheelLuma(id, slot, Float(w.master * 100))
            }
        }
        v.wheels[slot] = w
        return w
    }

    // MARK: Actions

    @objc private func sourceChanged() {
        let i = sourcePopup.indexOfSelectedItem
        guard i >= 0, i <= Self.sources.count else { return }
        model.gesture { model.setSourceOverride(i == 0 ? nil : Self.sources[i - 1].1) }
    }

    @objc private func addSection(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let k = ColorSectionKind(rawValue: raw) else { return }
        model.addSection(k)
    }

    @objc private func enableToggled(_ b: NSButton) { model.setEnabled(b.tag, b.state == .on) }
    @objc private func resetPressed(_ b: NSButton) { model.resetSection(b.tag) }
    @objc private func moveBlockUp(_ i: NSMenuItem) { model.moveSection(i.tag, by: -1) }
    @objc private func moveBlockDown(_ i: NSMenuItem) { model.moveSection(i.tag, by: 1) }
    @objc private func removePressed(_ i: NSMenuItem) { model.removeSection(i.tag) }
    @objc private func disclosureToggled(_ b: NSButton) { model.setCollapsed(b.tag, b.state == .off) }

    @objc private func curveChannelChosen(_ s: NSSegmentedControl) {
        guard let v = sectionViews[s.tag] else { return }
        v.selectedChannel = s.selectedSegment
        refresh()
    }

    @objc private func lutChosen(_ popup: NSPopUpButton) {
        guard let v = sectionViews[popup.tag] else { return }
        switch v.lutPicks[safe: popup.indexOfSelectedItem] {
        case .choice(let c)?: model.setLUT(v.section, c)
        case .chooseFile?:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
            panel.allowsMultipleSelection = false
            panel.message = "Choose a .cube LUT"
            if panel.runModal() == .OK, let url = panel.url { model.setLUT(v.section, .file(url.path)) } else { refresh() }
        case nil: refresh()
        }
    }

    // MARK: Refresh

    private func observe() {
        withObservationTracking {
            _ = model.color
            _ = model.collapsed
            _ = model.availableLUTs
            _ = model.recentLUTs
            _ = model.detectedSource
            _ = model.embeddedLUTName
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }

    /// Updates all controls from the model; rebuilds the blocks first when their structure changed.
    public func refresh() {
        if builtSignature != signature() { rebuildSections() }
        sourcePopup.removeAllItems()
        sourcePopup.addItem(withTitle: "Automatic (\(Self.name(model.detectedSource)))")
        Self.sources.forEach { sourcePopup.addItem(withTitle: $0.0) }
        if let o = model.sourceOverride, let i = Self.sources.firstIndex(where: { $0.1 == o }) { sourcePopup.selectItem(at: i + 1) }
        else { sourcePopup.selectItem(at: 0) }

        for (n, s) in model.sections.enumerated() {
            guard let v = sectionViews[s.id] else { continue }
            v.header.enable.state = s.enabled ? .on : .off
            v.body.alphaValue = s.enabled ? 1 : 0.45
            for (p, r) in v.rows { r.show(model.value(s.id, p)) }
            for (slot, w) in v.wheels {
                let st = model.wheel(s.id, slot)
                w.hue = Double(st.value.hue); w.amount = Double(st.value.amount); w.master = Double(st.luma / 100)
            }
            if let popup = v.lutPopup { refreshLUTPopup(popup, v, s) }
            if let editor = v.curveEditor {
                let c = model.curves(s.id)
                let (pts, color): ([CurvePoint], NSColor) = switch v.selectedChannel {
                case 1: (c.red, Theme.Colors.red)
                case 2: (c.green, Theme.Colors.green)
                case 3: (c.blue, NSColor.systemBlue)
                default: (c.master, Theme.Colors.label)
                }
                editor.points = pts
                editor.lineColor = color
            }
            v.header.moreButton.menu?.items.forEach { item in
                if item.title == "Move Up" { item.isEnabled = n > 0 }
                if item.title == "Move Down" { item.isEnabled = n < model.sections.count - 1 }
            }
        }
    }

    private func refreshLUTPopup(_ popup: NSPopUpButton, _ v: ColorSectionView, _ s: ColorSection) {
        let current = model.lutChoice(s.id)
        var items: [(String, ColorSectionView.LUTPick)] = []
        if v.kind == .inputLUT {
            items.append(("Automatic", .choice(.automatic)))
            if let n = model.embeddedLUTName { items.append(("Embedded: \(n)", .choice(.embedded(name: n)))) }
        } else {
            items.append(("None", .choice(nil)))
        }
        var seen = Set<String>()
        if let c = current, c.filePath != nil { items.append((c.name, .choice(c))); seen.insert(c.id) }
        let recents = model.recentLUTs.map { ColorInspectorModel.LUTChoice.file($0) }
        for c in recents + model.availableLUTs where c.filePath != nil && !seen.contains(c.id) {
            items.append((c.name, .choice(c))); seen.insert(c.id)
            if seen.count > 10 { break }
        }
        items.append(("Choose File…", .chooseFile))
        if v.kind == .inputLUT { items.append(("None", .choice(nil))) }
        popup.removeAllItems()
        v.lutPicks = items.map(\.1)
        for (title, _) in items { popup.addItem(withTitle: title) }
        let i = items.firstIndex { if case .choice(let c) = $0.1 { c == current } else { false } } ?? 0
        popup.selectItem(at: i)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
