import AppKit
import SQCore
/// The tool bar (design v9 `.tbar`, built from its `TOOLS` list): a grip, then Select, Blade, Slip, Hand, Create, Mask as
/// 28 pt buttons; the picked one sits on `fillPressed`. Tools with options carry a corner mark; hold or right-click opens them.
/// The keyboard-only tools (Select Forward, Ripple, Roll, Slide, Rate Stretch, Zoom) are in the bar's own right-click menu.
@MainActor
public final class ToolStripView: NSView {
    // The tool list, icons, help and menus are shared with the draw-list strip (`ToolStripTools`, ToolStripModel.swift).
    static var toolOrder: [TimelineTool] { ToolStripTools.order }
    static var toolSymbols: [TimelineTool: (symbol: SQIcon, title: String)] { ToolStripTools.symbols }
    static var toolHelp: [TimelineTool: String] { ToolStripTools.help }

    /// One optical size for every tool button icon.
    static let glyphSize: CGFloat = 16
    /// Icon for a tool slot; `name` is an SQIcon case name from `CreateToolMode` / `MaskMode` (the session layer cannot import SQUIKit).
    static func toolSymbolImage(_ name: String, label: String) -> NSImage? {
        toolSymbolImage(SQIcon(rawValue: name) ?? .unknown, label: label)
    }
    static func toolSymbolImage(_ icon: SQIcon, label: String) -> NSImage? {
        Theme.symbol(icon, size: glyphSize, label: label)
    }

    static func editorTool(_ t: TimelineTool) -> EditorTool? { ToolStripTools.editorTool(t) }

    /// Tooltip "Name (Key)" of a tool slot; the key comes from the key map.
    static func toolTip(_ tool: TimelineTool, title: String, map: CommandMap = .current) -> String {
        editorTool(tool).map { Tooltip.text(title, command: .tool($0), map: map) } ?? title
    }

    private(set) var toolButtons: [(tool: TimelineTool, button: TimelineToolSlotButton)] = []
    private weak var timeline: TimelineView?
    public var toolState = ToolState() { didSet { sync() } }
    public private(set) var edge: ToolStripEdge = .left { didSet { needsLayout = true; needsDisplay = true } }
    /// Grip drag: called with the pointer position in the superview while dragging, and on release.
    public var onGripDrag: ((CGPoint, Bool) -> Void)?

    public nonisolated override var isFlipped: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        for tool in Self.toolOrder {
            let info = Self.toolSymbols[tool]!
            let b = TimelineToolSlotButton(frame: .zero)
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.image = Self.toolSymbolImage(info.symbol, label: info.title)
            b.setAccessibilityLabel(info.title)
            b.focusRingType = .none
            b.setButtonType(.pushOnPushOff)
            b.style = .tool
            b.tag = toolButtons.count
            b.target = self
            b.action = #selector(toolClicked(_:))
            if tool == .slip { b.variantItems = { [weak self] in self?.slipVariantItems() ?? [] } }
            if tool == .mask { b.variantItems = { [weak self] in self?.maskModeItems() ?? [] } }
            if tool == .type { b.variantItems = { [weak self] in self?.createModeItems() ?? [] } }
            addSubview(b)
            toolButtons.append((tool, b))
        }
        sync()
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    public func setEdge(_ e: ToolStripEdge) { edge = e }

    /// Mirrors `timeline.toolState` and sends clicks back to it.
    public func bind(to timeline: TimelineView) {
        self.timeline = timeline
        toolState = timeline.toolState
        let previous = timeline.onToolStateChange
        timeline.onToolStateChange = { [weak self] s in previous?(s); self?.toolState = s }
    }

    private func commit(_ s: ToolState) {
        guard let timeline else { toolState = s; return }
        timeline.toolState = s
        timeline.window?.makeFirstResponder(timeline)
    }

    @objc private func toolClicked(_ sender: AnyObject) {
        guard let tag = (sender as? NSControl)?.tag, toolButtons.indices.contains(tag) else { return }
        let tool = toolButtons[tag].tool
        var s = toolState
        s.tool = tool
        commit(s)
        timeline?.onToolChange?(tool)
    }

    /// Picks `s` from a strip menu: the timeline takes it and reports the tool change.
    private func commitFromMenu(_ s: ToolState) {
        commit(s)
        timeline?.onToolChange?(s.tool)
    }

    private func slipVariantItems() -> [SQMenuItem] {
        ToolStripTools.variantItems(.slip, state: toolState) { [weak self] in self?.commitFromMenu($0) }
    }

    private func maskModeItems() -> [SQMenuItem] {
        ToolStripTools.variantItems(.mask, state: toolState) { [weak self] in self?.commitFromMenu($0) }
    }

    func createModeItems() -> [SQMenuItem] {
        ToolStripTools.variantItems(.type, state: toolState) { [weak self] in self?.commitFromMenu($0) }
    }

    /// Right-click on the bar (not on a tool): every tool with its key, the keyboard-only ones included, and where the bar docks.
    func allToolItems(map: CommandMap = .current) -> [SQMenuItem] {
        ToolStripTools.allToolItems(state: toolState, edge: edge, map: map) { [weak self] in self?.commitFromMenu($0) }
    }

    /// The three dots are the "more tools" control: the tools without a button (Select Forward, Ripple, Roll, Slide, Rate
    /// Stretch, Zoom) and the dock choices, opened under the dots.
    func showAllTools() {
        let g = gripRect
        SQContextMenu.popUp(items: allToolItems(), at: CGPoint(x: edge.isVertical ? g.maxX : g.minX, y: edge.isVertical ? g.minY : g.maxY), in: self)
    }

    public override func rightMouseDown(with event: NSEvent) {
        SQContextMenu.popUp(items: allToolItems(), at: convert(event.locationInWindow, from: nil), in: self)
    }

    /// "Name (Key) · what it does" (v9 tooltip: title with key, then the description).
    static func describedTip(_ head: String, tool: TimelineTool) -> String {
        toolHelp[tool].map { "\(head) · \($0)" } ?? head
    }

    /// The Create slot shows its mode: the v9 T for Text, the mode's symbol otherwise.
    private func syncCreateSlot(_ b: TimelineToolSlotButton) {
        let mode = toolState.createMode
        b.image = Self.toolSymbolImage(mode.symbol, label: mode.title)
        b.sqToolTip = Self.createToolTip(mode)
        b.setAccessibilityLabel("Create tool, \(mode.title)")
    }

    /// "Create: Rectangle (key) · Adds an item to a Graphic clip. Hold for the shape."
    static func createToolTip(_ mode: CreateToolMode, map: CommandMap = .current) -> String {
        describedTip(Tooltip.text("Create: \(mode.title)", command: .tool(mode.editorTool), map: map), tool: .type)
    }

    private func syncMaskSlot(_ b: TimelineToolSlotButton) {
        let mode = toolState.maskMode
        b.image = Self.toolSymbolImage(mode.symbol, label: "Mask")
        b.sqToolTip = Self.describedTip(Tooltip.text("Mask: \(mode.title)", command: .tool(.mask)), tool: .mask)
        b.setAccessibilityLabel("Mask tool, \(mode.title)")
    }

    private func sync() {
        for (tool, b) in toolButtons {
            if tool == .mask { syncMaskSlot(b) } else if tool == .type { syncCreateSlot(b) } else if tool == .slip { syncSlipSlot(b) } else {
                b.sqToolTip = Self.describedTip(Self.toolTip(tool, title: Self.toolSymbols[tool]?.title ?? ""), tool: tool)
            }
            let on = tool == toolState.tool
            b.state = on ? .on : .off
            b.contentTintColor = on ? Theme.Colors.label : Theme.Colors.label2
        }
    }

    private func syncSlipSlot(_ b: TimelineToolSlotButton) {
        let title = toolState.slipKeyframesStay ? "Slip (Keyframes Stay)" : "Slip"
        b.image = Self.toolSymbolImage(.toolSlip, label: title)
        b.sqToolTip = Self.describedTip(Tooltip.text(title, command: .tool(.slip)), tool: .slip)
        b.setAccessibilityLabel(title)
    }

    static var gripTip: String { ToolStripTools.gripTip }

    // MARK: Layout and drawing

    public override func layout() {
        super.layout()
        let s = ToolStripLayout.slots(edge: edge, toolCount: toolButtons.count, size: bounds.size)
        for (i, entry) in toolButtons.enumerated() { entry.button.frame = s.tools[i] }
        gripTipView.frame = s.grip
    }

    public override func draw(_ dirtyRect: NSRect) {
        if edge == .floating {
            // v9 `.tbar.floating`: raised fill, 1 pt strong line, small radius.
            let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
            Theme.Colors.overlay.setFill()
            box.fill()
            Theme.Colors.trackHeaderLine.setStroke()
            box.stroke()
        } else {
            Theme.Colors.panel.setFill()
            bounds.fill()
            Theme.Colors.separator.setFill()
            switch edge {
            case .left: CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
            case .right: CGRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
            case .top: CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
            default: CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
            }
        }
        // Grip: three dots in a row (v9 `i-gripx`, 20 x 10); turned a quarter when the bar is a row.
        let grip = ToolStripLayout.slots(edge: edge, toolCount: 0, size: bounds.size).grip
        Theme.Colors.label3.setFill()
        for i in -1...1 {
            let c = edge.isVertical ? CGPoint(x: grip.midX + CGFloat(i) * 4.2, y: grip.midY) : CGPoint(x: grip.midX, y: grip.midY + CGFloat(i) * 4.2)
            NSBezierPath(ovalIn: CGRect(x: c.x - 1, y: c.y - 1, width: 2, height: 2)).fill()
        }
    }

    // MARK: Grip drag

    private var gripRect: CGRect { ToolStripLayout.slots(edge: edge, toolCount: 0, size: bounds.size).grip }
    private lazy var gripTipView: NSView = {
        let v = PassThroughView()
        v.sqToolTip = Self.gripTip
        addSubview(v, positioned: .below, relativeTo: nil)
        return v
    }()

    public override func resetCursorRects() { addCursorRect(gripRect, cursor: .openHand) }

    public override func mouseDown(with event: NSEvent) {
        guard gripRect.contains(convert(event.locationInWindow, from: nil)), let sv = superview else { return }
        if event.clickCount == 2 { ToolStripPrefs.edge = .left; return }       // v9: double-click puts it back on the left
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        var moved = false
        let start = event.locationInWindow
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = sv.convert(e.locationInWindow, from: nil)
            if !moved, hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) < 3 {
                if e.type == .leftMouseUp { showAllTools(); break }      // a plain click on the dots: every tool
                continue
            }
            moved = true
            onGripDrag?(p, e.type == .leftMouseUp)
            if e.type == .leftMouseUp { break }
        }
    }
}

/// Carries the grip's tooltip without taking its clicks.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Docks the tool strip around `content` (left / right / top / bottom) or floats it above. Window > Tools toggles it.
@MainActor
public final class ToolStripDockView: NSView {
    public let strip = ToolStripView(frame: .zero)
    public private(set) var content: NSView
    public private(set) var edge: ToolStripEdge = ToolStripPrefs.edge
    public private(set) var stripVisible: Bool = ToolStripPrefs.visible
    private var observer: NSObjectProtocol?

    public nonisolated override var isFlipped: Bool { true }

    public init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
        addSubview(strip)
        strip.setEdge(edge)
        strip.onGripDrag = { [weak self] p, done in self?.gripDrag(p, done: done) }
        observer = NotificationCenter.default.addObserver(forName: ToolStripPrefs.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadPrefs() }
        }
    }
    public required init?(coder: NSCoder) { fatalError("not used") }
    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    public func bind(to timeline: TimelineView) { strip.bind(to: timeline) }

    private func reloadPrefs() {
        edge = ToolStripPrefs.edge
        stripVisible = ToolStripPrefs.visible
        strip.setEdge(edge)
        strip.isHidden = !stripVisible
        needsLayout = true
        superview?.needsLayout = true
    }

    /// Accent ring + tint over the edge the dragged bar will dock to (v9 `.dockzone.on`).
    private let zoneView = DockZoneView()

    private func gripDrag(_ p: CGPoint, done: Bool) {
        let area = CGRect(x: 0, y: topInset, width: bounds.width, height: max(bounds.height - topInset, 0))
        let target = ToolStripLayout.edge(for: p, in: area)
        if target == .floating {
            ToolStripPrefs.floatOrigin = CGPoint(x: p.x - ToolStripLayout.floatPadding - ToolStripLayout.rowGripLength / 2,
                                                 y: p.y - topInset - ToolStripLayout.rowThickness / 2)
        }
        edge = target
        strip.setEdge(target)
        if let zone = ToolStripLayout.zone(target, in: area), !done {
            if zoneView.superview == nil { addSubview(zoneView, positioned: .below, relativeTo: strip) }
            zoneView.frame = zone
        } else {
            zoneView.removeFromSuperview()
        }
        needsLayout = true
        superview?.needsLayout = true
        if done { ToolStripPrefs.edge = target }
    }

    /// Height of the host's header bar above the content: the tool bar sits below it on every edge (v9 `.tlw` is under `.ph`).
    public var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }

    /// What the host's header must leave free on its left and right: nothing, the bar never runs beside the header.
    public var headerInsets: (leading: CGFloat, trailing: CGFloat) { (0, 0) }

    /// A fixed-width view of the host right of the lanes; the tool bar docked right sits outside it (v9: lanes, meter, bar).
    public var trailingAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let trailingAccessory { addSubview(trailingAccessory, positioned: .below, relativeTo: strip) }
            needsLayout = true
        }
    }
    public var trailingAccessoryWidth: CGFloat = 0 { didSet { needsLayout = true } }

    public override func layout() {
        super.layout()
        let below = CGRect(x: 0, y: topInset, width: bounds.width, height: max(bounds.height - topInset, 0))
        let f = ToolStripLayout.frames(edge: edge, bounds: below, toolCount: strip.toolButtons.count,
                                       floatOrigin: CGPoint(x: ToolStripPrefs.floatOrigin.x, y: ToolStripPrefs.floatOrigin.y + topInset),
                                       visible: stripVisible)
        var body = f.content
        if let acc = trailingAccessory, !acc.isHidden, trailingAccessoryWidth > 0 {
            let w = min(trailingAccessoryWidth, body.width)
            acc.frame = CGRect(x: body.maxX - w, y: body.minY, width: w, height: body.height)
            body.size.width -= w
        }
        content.frame = body
        strip.frame = f.strip
        strip.isHidden = !stripVisible
        strip.needsLayout = true
    }
}

@MainActor
private final class DockZoneView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        Theme.Colors.accentTint.setFill()
        box.fill()
        Theme.Colors.accent.setStroke()
        box.lineWidth = 1
        box.stroke()
    }
}
