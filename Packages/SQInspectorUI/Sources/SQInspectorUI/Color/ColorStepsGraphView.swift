import AppKit
import Observation
import SQCore

/// The Steps panel of the Color page (version 9, lower panel with the Pro grade): the Color Graph as boxes on a dotted
/// canvas. In, the Input LUT slot, one box per Step, the Output LUT slot, Out, joined by wires. Boxes move freely (the
/// position is stored with the Step), the canvas pans and zooms, a Step dropped on a wire goes between the columns around it.
/// A click selects, a double-click renames, the eye turns a Step off, a right-click opens the Step's menu. Geometry and drag
/// rules live in `StepsCanvas`; this view draws and forwards events.
@MainActor
public final class ColorStepsGraphView: NSView, NSTextFieldDelegate {
    /// The graph shown (the Color panel's model of what is being graded); nil shows the empty state.
    var model: ColorInspectorModel? { didSet { if model !== oldValue { observe(); refresh() } } }
    /// Owner of the Step and LUT menus (the Pro page of the Color panel).
    weak var menus: ColorGraphPage? { didSet { menus?.stepsGraphView = self } }

    struct Node: Equatable {
        var id: UUID
        var label: String
        var enabled: Bool
        var hasLUT: Bool
        var hasQualifier: Bool
        var hasWindow: Bool
        var hasPrimaries = false
        var hasCurves = false
        /// A key wire ends or starts at the Step (stored, not applied yet).
        var keyOut = false
        var keyIn = false
        var kind: StepKind = .serial
        var mix: Float = 100
    }
    /// The Steps in order, and the same Steps as columns (a serial Step with the Parallel and Layer Steps behind it).
    private(set) var nodes: [Node] = []
    private(set) var columns: [[Node]] = []
    private(set) var selected: UUID?
    /// Every selected Step (a multi-selection); `selected` is the one the inspector shows.
    private(set) var selectedSet: Set<UUID> = []
    private(set) var selectedMixer: UUID?
    private(set) var inLUT: String?
    private(set) var outLUT: String?
    private(set) var serialCount = 0
    private(set) var canvas = StepsCanvas()

    /// Nothing is being graded.
    let emptyState = EmptyStateView(title: "No Pro grade here", hint: "Pick a clip, then choose Pro in the Color panel.")
    /// Version 9 `.gempty`, a clip without a Color Graph: In and Out joined by a wire, what happens next, two buttons.
    let startTitle = NSTextField(labelWithString: "No Pro grade on this clip yet")
    let startHint = NSTextField(wrappingLabelWithString: "The first step adds a Color Graph effect. Your Simple grade stays as it is.")
    private(set) lazy var startEmpty = SQButton(title: "Start empty", target: self, action: #selector(startEmptyPressed), style: .accent)
    private(set) lazy var startFromSimple = SQButton(title: "Start from Simple grade", target: self, action: #selector(startFromSimplePressed))
    /// Footer controls of the canvas.
    private(set) lazy var tidyButton = SQButton(title: "Tidy up", target: self, action: #selector(tidyPressed), style: .standard)
    private(set) lazy var fitButton = SQButton(title: "Fit", target: self, action: #selector(fitPressed), style: .standard)
    /// The clip has no Color Graph yet: the start page shows.
    private(set) var offersStart = false
    static let startWire: CGFloat = 80
    /// Version 9 `.gempty`: the column starts 40 pt above the middle, the In / Out row is as high as a node, the text
    /// wraps at 44 characters.
    static let startRise: CGFloat = 40
    static let startHintWidth: CGFloat = 300
    static let startDot: CGFloat = 7

    static let node = StepsCanvas.node
    static let pill = StepsCanvas.pill
    static let slot = StepsCanvas.slot
    static let wire = StepsCanvas.wire
    static let dotPitch: CGFloat = 18
    static let footer: CGFloat = 28
    static let wellInset = Theme.Spacing.sm

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        addSubview(emptyState)
        startTitle.font = Theme.Typography.windowTitle      // version 9 has 15 / 600; 13 semibold is the nearest token
        startTitle.textColor = Theme.Colors.label
        startTitle.lineBreakMode = .byTruncatingTail
        startHint.font = Theme.Typography.body
        startHint.textColor = Theme.Colors.label2
        startHint.isSelectable = false
        startHint.preferredMaxLayoutWidth = Self.startHintWidth
        for l in [startTitle, startHint] { l.alignment = .center }
        for v in [startTitle, startHint, startEmpty, startFromSimple, tidyButton, fitButton] as [NSView] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Steps")
        refresh()
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.graph
            _ = model.selectedStep
            _ = model.selectedSteps
            _ = model.showsEmptyPro
            _ = model.renamingStep
            _ = model.selectedMixer
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }

    func refresh() {
        let g = model?.graph
        let keyOuts = Set((g?.keyLinks ?? []).compactMap { $0.from.stepID })
        let keyIns = Set((g?.keyLinks ?? []).map(\.to))
        func node(_ s: ColorStep) -> Node {
            Node(id: s.id, label: s.label, enabled: s.enabled, hasLUT: s.lut != nil, hasQualifier: s.qualifier != nil,
                 hasWindow: s.window != nil, hasPrimaries: !s.primaries.isNeutral,
                 hasCurves: !(s.curves.isNeutral && s.hueCurves.isNeutral),
                 keyOut: keyOuts.contains(s.id), keyIn: keyIns.contains(.step(s.id)), kind: s.kind, mix: s.mix)
        }
        columns = g?.columns.map { $0.map(node) } ?? []
        nodes = columns.flatMap { $0 }
        serialCount = columns.count
        selected = model?.selectedStep
        selectedSet = model?.selectedSteps ?? []
        canvas.links = g?.links
        canvas.keyLinks = g?.keyLinks ?? []
        selectedMixer = model?.selectedMixer
        canvas.mixerPositions = Dictionary(uniqueKeysWithValues: (g?.steps ?? []).compactMap { s in s.mixerPosition.map { (s.id, $0) } })
        canvas.columns = columns.map { $0.map(\.id) }
        canvas.positions = Dictionary(uniqueKeysWithValues: (g?.steps ?? []).compactMap { s in s.position.map { (s.id, $0) } })
        inLUT = model?.graphLUTChoice(.input)?.name
        outLUT = model?.graphLUTChoice(.output)?.name
        canvas.inSlotWidth = Self.slotWidth(inLUT)
        canvas.outSlotWidth = Self.slotWidth(outLUT)
        refit()
        if let id = model?.renamingStep {
            model?.renamingStep = nil
            if nodes.contains(where: { $0.id == id }) { beginRename(id) }
        } else if let id = editing, !nodes.contains(where: { $0.id == id }) { endRename(commit: false) }
        offersStart = model != nil && g == nil
        emptyState.isHidden = model != nil
        for v in [startTitle, startHint, startEmpty, startFromSimple] as [NSView] { v.isHidden = !offersStart }
        let showsCanvas = !nodes.isEmpty && !offersStart
        tidyButton.isHidden = !showsCanvas
        fitButton.isHidden = !showsCanvas
        needsLayout = true
        needsDisplay = true
    }

    /// While the user has not moved the view, it fits itself to the content.
    private func refit() {
        guard canvas.drag == nil, !canvas.userView else { return }
        canvas.fit(in: well.size, margin: Theme.Spacing.lg)
    }

    /// "6 steps, 4 in series": every Step, and how many of them are in the main row (the serial ones).
    static func summary(_ n: Int, series: Int? = nil) -> String {
        let s = series ?? n
        return "\(n) \(n == 1 ? "step" : "steps"), \(s) in series"
    }

    @objc private func startEmptyPressed() { model?.startEmptyGraph() }
    @objc private func startFromSimplePressed() { model?.startFromSimple() }
    @objc private func tidyPressed() { tidyUp() }
    @objc private func fitPressed() { fitView() }

    /// Tidy up: every Step back to the automatic layout, the view fitted.
    func tidyUp() {
        canvas.userView = false
        model?.tidyUpSteps()
        refresh()
    }

    func fitView() {
        canvas.userView = false
        refit()
        needsDisplay = true
    }

    // MARK: Layout

    typealias Hit = StepsCanvas.Hit

    private var well: NSRect {
        NSRect(x: Self.wellInset, y: Self.wellInset, width: max(bounds.width - 2 * Self.wellInset, 0),
               height: max(bounds.height - Self.wellInset - Self.footer, 0))
    }

    /// A point of this view in canvas-view coordinates (the origin is the well's corner).
    private func local(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x - well.minX, y: p.y - well.minY) }

    func hit(at pt: NSPoint) -> Hit? {
        guard !nodes.isEmpty, !offersStart, well.contains(pt) else { return nil }
        return canvas.hit(at: local(pt))
    }

    /// The frame of a Step in this view's coordinates.
    func frame(ofStep id: UUID) -> NSRect? {
        guard let r = canvas.layout().rects[id] else { return nil }
        return canvas.viewRect(r).offsetBy(dx: well.minX, dy: well.minY)
    }

    public override func layout() {
        super.layout()
        let w = well
        emptyState.frame = w
        refit()
        let hw = min(Self.startHintWidth, max(w.width - 2 * Theme.Spacing.md, 0))
        let th = ceil(startTitle.intrinsicContentSize.height)
        let hh = ceil(startHint.sizeThatFits(NSSize(width: hw, height: .greatestFiniteMagnitude)).height)
        let a = startEmpty.intrinsicContentSize, b = startFromSimple.intrinsicContentSize
        let bh = max(a.height, b.height)
        let gap = Theme.Spacing.sm
        let chain = Self.node.height + gap
        let total = chain + gap + th + gap + hh + gap + Theme.Spacing.xs + bh
        // Version 9 starts the column 40 pt above the middle; a low panel centers it so the buttons stay inside.
        var y = max(min((w.midY - Self.startRise).rounded(), (w.maxY - total - gap).rounded()), w.minY + Theme.Spacing.xs)
        startPillsY = y + ((Self.node.height - Self.pill.height) / 2).rounded()
        y += chain + gap
        startTitle.frame = NSRect(x: w.minX, y: y, width: w.width, height: th)
        y += th + gap
        startHint.frame = NSRect(x: (w.midX - hw / 2).rounded(), y: y, width: hw, height: hh)
        y += hh + gap + Theme.Spacing.xs
        let bw = a.width + Theme.Spacing.sm + b.width
        let bx = (w.midX - bw / 2).rounded()
        startEmpty.frame = NSRect(x: bx, y: y, width: a.width, height: a.height)
        startFromSimple.frame = NSRect(x: bx + a.width + Theme.Spacing.sm, y: y, width: b.width, height: b.height)
        // Footer: the hint on the left, then Tidy up, Fit and the count on the right.
        let ts = tidyButton.intrinsicContentSize, fs = fitButton.intrinsicContentSize
        let fy = bounds.height - Self.footer + ((Self.footer - ts.height) / 2).rounded()
        let sumW = ceil(Self.summaryString(nodes.count, serialCount).size().width)
        var rx = bounds.width - Theme.Spacing.md - sumW - Theme.Spacing.md
        rx -= fs.width
        fitButton.frame = NSRect(x: rx, y: fy, width: fs.width, height: fs.height)
        rx -= Theme.Spacing.xs + ts.width
        tidyButton.frame = NSRect(x: rx, y: fy, width: ts.width, height: ts.height)
        if let id = editing, let f = frame(ofStep: id) { editor?.frame = renameFrame(f) }
    }

    private var startPillsY: CGFloat = 0

    private static func summaryString(_ n: Int, _ series: Int) -> NSAttributedString {
        NSAttributedString(string: summary(n, series: series),
                           attributes: [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3])
    }

    // MARK: Drawing

    public override func draw(_ dirty: NSRect) {
        let w = well
        Theme.Colors.content.setFill()
        NSBezierPath(roundedRect: w, xRadius: Theme.Radius.inner, yRadius: Theme.Radius.inner).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: w, xRadius: Theme.Radius.inner, yRadius: Theme.Radius.inner).addClip()
        drawGrid(w)
        if offersStart {
            drawStart()
        } else if !nodes.isEmpty {
            let t = NSAffineTransform()
            t.translateX(by: w.minX, yBy: w.minY)
            t.concat()
            drawGraph()
        }
        NSGraphicsContext.restoreGraphicsState()

        let hint = nodes.isEmpty || offersStart ? "" : "Drag a step to move it, onto a wire to insert it. Drag between dots to wire. Space-drag or scroll to pan, pinch to zoom."
        let a: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3]
        let fy = bounds.height - Self.footer + ((Self.footer - ceil(Theme.Typography.caption.ascender - Theme.Typography.caption.descender)) / 2).rounded() - 1
        (hint as NSString).draw(at: NSPoint(x: Theme.Spacing.md, y: fy), withAttributes: a)
        guard model?.graph != nil else { return }
        let sum = Self.summaryString(nodes.count, serialCount)
        sum.draw(at: NSPoint(x: bounds.width - Theme.Spacing.md - ceil(sum.size().width), y: fy))
    }

    /// The dotted well: the dots pan and zoom with the canvas.
    private func drawGrid(_ w: NSRect) {
        Theme.Colors.graphGrid.setFill()
        let pitch = Self.dotPitch * (nodes.isEmpty || offersStart ? 1 : max(canvas.zoom, 0.6))
        let ox = (nodes.isEmpty || offersStart ? 0 : canvas.pan.x).truncatingRemainder(dividingBy: pitch)
        let oy = (nodes.isEmpty || offersStart ? 0 : canvas.pan.y).truncatingRemainder(dividingBy: pitch)
        var y = w.minY + pitch / 2 + oy
        while y < w.maxY {
            var x = w.minX + pitch / 2 + ox
            while x < w.maxX { NSRect(x: x.rounded(), y: y.rounded(), width: 1, height: 1).fill(); x += pitch }
            y += pitch
        }
    }

    /// In, an 80 pt wire, Out: centered above the start page's text.
    private func drawStart() {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3]
        let i = NSAttributedString(string: "In", attributes: attrs), o = NSAttributedString(string: "Out", attributes: attrs)
        let iw = ceil(i.size().width), ow = ceil(o.size().width), th = ceil(i.size().height)
        let d = Self.startDot, gap = Theme.Spacing.iconToLabel
        let width = d + gap + iw + Self.startWire + ow + gap + d
        var x = (well.midX - width / 2).rounded()
        let cy = startPillsY + Self.pill.height / 2
        let ty = (cy - th / 2).rounded()
        Theme.Colors.label3.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: (cy - d / 2).rounded(), width: d, height: d)).fill()
        x += d + gap
        i.draw(at: NSPoint(x: x, y: ty))
        x += iw
        Theme.Colors.separator.setFill()
        NSRect(x: x + Theme.Spacing.xs, y: (cy - 0.5).rounded(), width: Self.startWire - 2 * Theme.Spacing.xs, height: 1).fill()
        x += Self.startWire
        o.draw(at: NSPoint(x: x, y: ty))
        x += ow + gap
        Theme.Colors.label3.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: (cy - d / 2).rounded(), width: d, height: d)).fill()
    }

    private func wirePath(_ w: StepsCanvas.Wire) -> NSBezierPath {
        let a = canvas.viewPoint(w.from), b = canvas.viewPoint(w.to)
        let k = max(abs(b.x - a.x) * 0.5, 12)
        let p = NSBezierPath()
        p.lineWidth = 1.5
        p.move(to: a)
        p.curve(to: b, controlPoint1: NSPoint(x: a.x + k, y: a.y), controlPoint2: NSPoint(x: b.x - k, y: b.y))
        return p
    }

    private func drawGraph() {
        let l = canvas.layout()
        let z = canvas.zoom
        let lifted = wireDrag?.replacing
        Theme.Colors.fillHover.setStroke()
        for w in canvas.wires() where w.link == nil || w.link != lifted { wirePath(w).stroke() }
        // Key wires: dashed, the secondary style.
        Theme.Colors.label3.setStroke()
        for w in canvas.keyWires() where w.link != lifted {
            let p = wirePath(w)
            p.lineWidth = 1
            p.setLineDash([3, 3], count: 2, phase: 0)
            p.stroke()
        }
        Theme.Colors.accent.setStroke()
        for w in canvas.previewWires() { let p = wirePath(w); p.lineWidth = 2; p.stroke() }

        for (c, head, r) in canvas.mixers(l) {
            mixer(canvas.viewRect(r), layer: columns[c].dropFirst().contains { $0.kind == .layer }, selected: head == selectedMixer)
        }
        slot(inLUT, canvas.viewRect(l.inSlot))
        slot(outLUT, canvas.viewRect(l.outSlot))
        endpoint("In", canvas.viewRect(l.inPill), dotFirst: true)
        endpoint("Out", canvas.viewRect(l.outPill), dotFirst: false)
        var number: [UUID: Int] = [:]
        for (i, n) in nodes.enumerated() { number[n.id] = i + 1 }
        let dragged = canvas.drag?.id
        for id in l.order where id != dragged {
            if let n = nodes.first(where: { $0.id == id }), let r = l.rects[id] { node(n, number: number[id] ?? 0, in: canvas.viewRect(r), zoom: z) }
        }
        if let id = dragged, let n = nodes.first(where: { $0.id == id }), let r = l.rects[id] {
            node(n, number: number[id] ?? 0, in: canvas.viewRect(r), zoom: z)
        }
        drawWireDrag(l)
        if let m = marquee {
            let r = m.rect.offsetBy(dx: 0, dy: 0)
            Theme.Colors.accent.withAlphaComponent(0.12).setFill(); r.fill()
            Theme.Colors.accent.setStroke()
            let b = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)); b.lineWidth = 1; b.stroke()
        }
        if let h = hoverInsert, let r = canvas.insertButtons(l).first(where: { $0.0 == h })?.1, canvas.drag == nil { insertDot(r) }
    }

    /// The box behind a stack: Parallel Steps are averaged, a Layer goes over the result.
    private func mixer(_ r: NSRect, layer: Bool, selected: Bool) {
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        Theme.Colors.content.setFill(); path.fill()
        Theme.Colors.fill.setFill(); path.fill()
        Theme.Colors.label3.setStroke()
        path.lineWidth = 1
        if layer { path.setLineDash([3, 3], count: 2, phase: 0) }
        path.stroke()
        if selected {
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: Theme.Radius.small + 1, yRadius: Theme.Radius.small + 1)
            Theme.Colors.accent.setStroke(); ring.lineWidth = 2; ring.stroke()
        }
        _ = icon(layer ? .stack : .plus, at: NSPoint(x: r.midX - 5, y: r.midY), size: 10, color: Theme.Colors.label2)
        connectorDots(r)
    }

    /// The input dot (left) and output dot (right) of a box, on the wire ends.
    private func connectorDots(_ r: NSRect, highlight: Bool = false) {
        let d = StepsCanvas.dotSize
        (highlight ? Theme.Colors.accent : Theme.Colors.label2).setFill()
        for x in [r.minX, r.maxX] { NSBezierPath(ovalIn: NSRect(x: x - d / 2, y: r.midY - d / 2, width: d, height: d)).fill() }
    }

    /// The Key input and output dots at the bottom corners: hollow, the secondary style; filled when a key wire uses them.
    private func keyDots(_ r: NSRect, inUsed: Bool = false, outUsed: Bool = false) {
        let d = StepsCanvas.dotSize
        let k = StepsCanvas.keyDots(r)
        let scale = r.width / StepsCanvas.node.width
        let pts = [NSPoint(x: r.minX + (k.input.x - r.minX) * scale, y: r.maxY), NSPoint(x: r.maxX - (r.maxX - k.output.x) * scale, y: r.maxY)]
        for (p, used) in zip(pts, [inUsed, outUsed]) {
            let o = NSBezierPath(ovalIn: NSRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
            (used ? Theme.Colors.label2 : Theme.Colors.content).setFill(); o.fill()
            Theme.Colors.label3.setStroke(); o.lineWidth = 1; o.stroke()
        }
    }

    /// While a wire is dragged (from an output dot, or an end picked up): the wire to the pointer, and the input it is over.
    /// A refused target shows red, and the wire snaps back on release.
    private func drawWireDrag(_ l: StepsCanvas.Layout) {
        if let f = refusedFlash, let c = (f.key ? canvas.keyDotCenter(f.port, output: false, l) : canvas.dotCenter(f.port, output: false, l)) {
            let b = canvas.viewPoint(c)
            let ring = NSBezierPath(ovalIn: NSRect(x: b.x - 6, y: b.y - 6, width: 12, height: 12))
            Theme.Colors.red.setStroke(); ring.lineWidth = 2; ring.stroke()
        }
        guard let w = wireDrag else { return }
        let start = w.isKey ? w.from.stepID.flatMap { canvas.keyDotCenter(.step($0), output: true, l) } : canvas.dotCenter(w.from, output: true, l)
        guard let c = start else { return }
        let a = canvas.viewPoint(c)
        let refused = w.refusal != nil
        if let t = w.target, let tc = (w.isKey ? canvas.keyDotCenter(t, output: false, l) : canvas.dotCenter(t, output: false, l)) {
            let b = canvas.viewPoint(tc)
            let ring = NSBezierPath(ovalIn: NSRect(x: b.x - 6, y: b.y - 6, width: 12, height: 12))
            (refused ? Theme.Colors.red : Theme.Colors.accent).setStroke(); ring.lineWidth = 2; ring.stroke()
        }
        let p = NSBezierPath()
        p.lineWidth = 2
        let k = max(abs(w.point.x - a.x) * 0.5, 12)
        p.move(to: a)
        p.curve(to: w.point, controlPoint1: NSPoint(x: a.x + k, y: a.y), controlPoint2: NSPoint(x: w.point.x - k, y: w.point.y))
        if w.isKey { p.setLineDash([3, 3], count: 2, phase: 0) }
        (refused ? Theme.Colors.red : Theme.Colors.accent).setStroke()
        p.stroke()
    }

    /// The Insert button that shows under the pointer: a dot with a plus.
    private func insertDot(_ r: NSRect) {
        let path = NSBezierPath(ovalIn: r)
        Theme.Colors.content.setFill(); path.fill()
        Theme.Colors.fillPressed.setFill(); path.fill()
        _ = icon(.plus, at: NSPoint(x: r.minX + (r.width - 8) / 2, y: r.midY), size: 8, color: Theme.Colors.label)
    }

    private func centered(_ s: String, in r: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let h = ceil(a.size().height)
        a.draw(with: NSRect(x: r.minX + 3, y: (r.midY - h / 2).rounded(), width: r.width - 6, height: h),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Version 9 `.pill`: a dot on the wire and its name ("In" before the dot's wire, "Out" behind it).
    private func endpoint(_ s: String, _ r: NSRect, dotFirst: Bool) {
        let d = Self.startDot, gap = Theme.Spacing.iconToLabel
        let a = NSAttributedString(string: s, attributes: [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3])
        let size = a.size(), tw = ceil(size.width)
        // The dot sits exactly on the wire end: "In" ends at the pill's right edge (name left of the dot), "Out" starts at
        // its left edge (name right of the dot).
        let dotX = dotFirst ? r.maxX - d / 2 : r.minX - d / 2
        let textX = dotFirst ? dotX - gap - tw : dotX + d + gap
        Theme.Colors.label3.setFill()
        NSBezierPath(ovalIn: NSRect(x: dotX, y: (r.midY - d / 2).rounded(), width: d, height: d)).fill()
        a.draw(at: NSPoint(x: textX, y: (r.midY - size.height / 2).rounded()))
    }

    /// The slot's width for its label (an empty slot says "LUT").
    static func slotWidth(_ name: String?) -> CGFloat {
        StepsCanvas.slotWidth(textWidth: ((name ?? "LUT") as NSString).size(withAttributes: [.font: Theme.Typography.caption]).width)
    }

    /// A LUT slot: dashed and "LUT" while empty, filled with the LUT's name once set.
    private func slot(_ name: String?, _ r: NSRect) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        Theme.Colors.content.setFill(); path.fill()
        if name != nil { Theme.Colors.fill.setFill(); path.fill() }
        (name != nil ? Theme.Colors.accent : Theme.Colors.label3).setStroke()
        path.lineWidth = 1
        if name == nil { path.setLineDash([3, 3], count: 2, phase: 0) }
        path.stroke()
        centered(name ?? "LUT", in: r, font: Theme.Typography.caption, color: name != nil ? Theme.Colors.label : Theme.Colors.label3)
        connectorDots(r)
    }

    private func icon(_ name: SQIcon, at pt: NSPoint, size: CGFloat, color: NSColor) -> CGFloat {
        let img = name.image(size: size, color: color)
        img.draw(in: NSRect(x: pt.x, y: (pt.y - img.size.height / 2).rounded(), width: img.size.width, height: img.size.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return img.size.width
    }

    private func node(_ n: Node, number: Int, in r: NSRect, zoom: CGFloat) {
        let isSel = selectedSet.contains(n.id) || n.id == selected
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        Theme.Colors.content.setFill(); path.fill()
        if n.enabled {
            (isSel ? Theme.Colors.fillPressed : (n.id == hoverStep ? Theme.Colors.fillHover : Theme.Colors.fill)).setFill(); path.fill()
        } else {
            let line = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
            Theme.Colors.separator.setStroke(); line.lineWidth = 1; line.stroke()
        }
        if n.kind == .layer {
            let line = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
            Theme.Colors.label3.setStroke(); line.lineWidth = 1; line.setLineDash([3, 3], count: 2, phase: 0); line.stroke()
        }
        if isSel {
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: Theme.Radius.small - 1, yRadius: Theme.Radius.small - 1)
            Theme.Colors.accent.setStroke(); ring.lineWidth = 2; ring.stroke()
        }
        // Image input and output dots on the wire ends; Key input and output at the bottom corners.
        connectorDots(r)
        keyDots(r, inUsed: n.keyIn, outUsed: n.keyOut)
        guard r.height >= 30 else { return }
        let pad = Theme.Spacing.sm
        var attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: n.enabled ? Theme.Colors.label : Theme.Colors.label3]
        if !n.enabled { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let name = NSAttributedString(string: n.label, attributes: attrs)
        let h = ceil(name.size().height)
        let eye = StepsCanvas.eyeRect(r)
        if editing != n.id {
            name.draw(with: NSRect(x: r.minX + pad, y: r.minY + 5, width: max(eye.minX - r.minX - pad, 0), height: h),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        _ = icon(n.enabled ? .eye : .eyeOff, at: NSPoint(x: eye.minX + 3, y: eye.midY), size: 10,
                 color: n.enabled ? Theme.Colors.label2 : Theme.Colors.label3)
        let mono = NSFont.monospacedDigitSystemFont(ofSize: Theme.Typography.caption.pointSize, weight: .regular)
        let num = NSAttributedString(string: String(format: "%02d", number), attributes: [.font: mono, .foregroundColor: Theme.Colors.label3])
        let by = r.maxY - 6 - ceil(num.size().height)
        num.draw(at: NSPoint(x: r.minX + pad, y: by))
        var x = r.minX + pad + ceil(num.size().width) + Theme.Spacing.iconToLabel
        let cy = by + ceil(num.size().height) / 2
        // Badges: what the Step holds. (There is no per-Step effect list in the model, so no Effects badge.)
        let mixText = n.mix < 100 ? NSAttributedString(string: "\(Int(n.mix.rounded()))%", attributes: [.font: mono, .foregroundColor: Theme.Colors.label2]) : nil
        let limit = r.maxX - 4 - (mixText.map { ceil($0.size().width) + Theme.Spacing.xs } ?? 0)
        let badgeColor = n.enabled ? Theme.Colors.label2 : Theme.Colors.label3
        for (on, symbol) in [(n.hasPrimaries, SQIcon.slidersVertical), (n.hasCurves, .curve), (n.hasQualifier, .eyedropper),
                             (n.hasWindow, .circleDashed), (n.hasLUT, .grid3)] where on {
            guard x + 9 <= limit else { break }
            x += icon(symbol, at: NSPoint(x: x, y: cy), size: 9, color: badgeColor) + Theme.Spacing.xs
        }
        if let m = mixText { m.draw(at: NSPoint(x: r.maxX - pad - ceil(m.size().width), y: by)) }
    }

    // MARK: Renaming

    private(set) var editing: UUID?
    private var editor: SQTextField?

    private func renameFrame(_ node: NSRect) -> NSRect {
        let eye = StepsCanvas.eyeRect(node)
        return NSRect(x: node.minX + 2, y: node.minY + 3, width: max(eye.minX - node.minX - 2, 40), height: 18)
    }

    /// Edits the Step's name in place; Return keeps it, Escape or a click elsewhere on the canvas leaves it.
    func beginRename(_ id: UUID) {
        guard let n = nodes.first(where: { $0.id == id }), let f = frame(ofStep: id) else { return }
        endRename(commit: true)
        let t = SQTextField(string: n.label)
        t.font = Theme.Typography.caption
        t.delegate = self
        t.frame = renameFrame(f)
        addSubview(t)
        editor = t
        editing = id
        window?.makeFirstResponder(t)
        t.selectText(nil)
        needsDisplay = true
    }

    func endRename(commit: Bool) {
        guard let id = editing, let t = editor else { return }
        editing = nil
        editor = nil
        let text = t.stringValue
        t.delegate = nil
        t.removeFromSuperview()
        window?.makeFirstResponder(self)
        if commit { model?.renameStep(id, to: text) }
        needsDisplay = true
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { endRename(commit: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        return false
    }

    public func controlTextDidEndEditing(_ obj: Notification) { endRename(commit: true) }

    // MARK: Mouse

    private var hoverInsert: UUID? { didSet { if hoverInsert != oldValue { needsDisplay = true } } }
    private var hoverStep: UUID? { didSet { if hoverStep != oldValue { needsDisplay = true } } }
    /// A wire being dragged: from an output dot (a new wire), or a wire picked up by one end (`replacing`). `point` is the
    /// pointer (view points of the canvas), `target` the input it is over and `refusal` why that one would not take it.
    struct WireDrag {
        var from: StepsPort
        var point: NSPoint
        var target: StepsPort?
        var isKey = false
        var replacing: GraphLink?
        var refusal: LinkRefusal?
    }
    private(set) var wireDrag: WireDrag?
    /// A refused drop stays marked for a moment (the wire has snapped back).
    private var refusedFlash: (port: StepsPort, key: Bool)? { didSet { needsDisplay = true } }
    /// A rectangle being dragged on empty canvas (view points of the canvas) and the selection it started from.
    struct Marquee { var start: NSPoint; var current: NSPoint; var base: Set<UUID>
        var rect: NSRect { NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y)) }
    }
    private(set) var marquee: Marquee?
    /// A click on a selected Step of a multi-selection keeps the group until the button goes up without a drag.
    private var collapseOnClick: UUID?
    /// A Shift-click toggles a Step on release; a Shift-drag takes it off its wires instead.
    private var toggleOnClick: UUID?
    private var spaceDown = false
    private var panning = false
    private var lastPan = NSPoint.zero
    private var trackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    public override func mouseMoved(with e: NSEvent) {
        let h = hit(at: convert(e.locationInWindow, from: nil))
        if case .insert(let id)? = h { hoverInsert = id } else { hoverInsert = nil }
        switch h {
        case .step(let id)?, .eye(let id)?: hoverStep = id
        default: hoverStep = nil
        }
    }
    public override func mouseExited(with e: NSEvent) { hoverInsert = nil; hoverStep = nil }

    private func screenPoint(_ e: NSEvent) -> NSPoint { window?.convertPoint(toScreen: e.locationInWindow) ?? e.locationInWindow }

    /// Stops whatever gesture is under way (Escape): a drag, a wire, a rectangle.
    private func cancelGesture() {
        canvas.cancelDrag()
        wireDrag = nil
        marquee = nil
        needsDisplay = true
    }

    /// The input a dragged wire is over, and whether the graph would take it.
    private func aim(_ w: WireDrag, at p: NSPoint) -> (StepsPort?, LinkRefusal?) {
        var target: StepsPort?
        if w.isKey {
            switch canvas.hit(at: p) {
            case .keyIn(let port)?: target = port
            case .step(let id)?, .eye(let id)?: target = .step(id)
            case .mixer(let head)?: target = .mixer(head)
            default: target = nil
            }
        } else {
            target = canvas.inputPort(at: p)
        }
        guard let t = target, var g = model?.graph else { return (nil, nil) }
        if let k = w.replacing { if w.isKey { g.disconnectKey(k) } else { g.disconnect(k) } }
        let why = w.isKey ? w.from.stepID.flatMap { g.keyRefusal(from: $0, to: t) } : g.refusal(from: w.from, to: t)
        return (t, why)
    }

    public override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { rightMouseDown(with: e); return }
        if editing != nil { endRename(commit: true) }
        window?.makeFirstResponder(self)
        refusedFlash = nil
        let pt = convert(e.locationInWindow, from: nil)
        if spaceDown, well.contains(pt), !nodes.isEmpty, !offersStart {
            panning = true
            lastPan = pt
            return
        }
        let shift = e.modifierFlags.contains(.shift), command = e.modifierFlags.contains(.command)
        let hitAt = hit(at: pt)
        switch hitAt {
        case .dotOut(let port)?:
            model?.selectedMixer = nil
            wireDrag = WireDrag(from: port, point: local(pt), target: nil)
        case .dotIn(let port)?:
            // An end with a wire picks the wire up: drop it on another input to move it, on empty canvas to remove it.
            if let k = canvas.wire(into: port) { wireDrag = WireDrag(from: k.from, point: local(pt), target: nil, replacing: k) }
        case .keyOut(let id)?:
            wireDrag = WireDrag(from: .step(id), point: local(pt), target: nil, isKey: true)
        case .keyIn(let port)?:
            if let k = canvas.keyLinks.first(where: { $0.to == port }) {
                wireDrag = WireDrag(from: k.from, point: local(pt), target: nil, isKey: true, replacing: k)
            }
        case .mixer(let head)?:
            model?.selectedMixer = head
            canvas.beginMixerDrag(head, at: local(pt))
            needsDisplay = true
        case .input?: menus?.showLUTMenu(.graphInput, at: screenPoint(e))
        case .output?: menus?.showLUTMenu(.graphOutput, at: screenPoint(e))
        case .eye(let id)?:
            if let s = model?.step(id) { model?.setStepEnabled(id, !s.enabled) }
        case .insert(let id)?: menus?.showInsertMenu(after: id, at: screenPoint(e))
        case .step(let id)?:
            model?.selectedMixer = nil
            if e.clickCount >= 2, !shift, !command { model?.selectStep(id); beginRename(id); return }
            if command {
                model?.selectStep(id, extend: true)
            } else if shift {
                toggleOnClick = id
                if !selectedSet.contains(id) { model?.selectStep(id) }
            } else if selectedSet.contains(id), selectedSet.count > 1 {
                collapseOnClick = id
                model?.selectedStep = id
            } else {
                model?.selectStep(id)
            }
            let group = selectedSet.contains(id) ? selectedSet : []
            canvas.beginDrag(id, at: local(pt), with: shift ? [] : group, extract: shift)
        case nil:
            guard !nodes.isEmpty, !offersStart, well.contains(pt) else { return }
            model?.selectedMixer = nil
            marquee = Marquee(start: local(pt), current: local(pt), base: shift || command ? selectedSet : [])
        }
    }

    public override func mouseDragged(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        if panning {
            canvas.panBy(CGSize(width: pt.x - lastPan.x, height: pt.y - lastPan.y))
            lastPan = pt
            needsDisplay = true
        } else if var w = wireDrag {
            w.point = local(pt)
            (w.target, w.refusal) = aim(w, at: w.point)
            wireDrag = w
            needsDisplay = true
        } else if var m = marquee {
            m.current = local(pt)
            marquee = m
            let ids = canvas.steps(in: m.rect)
            model?.selectSteps(ids.union(m.base))
            needsDisplay = true
        } else if canvas.drag != nil {
            canvas.continueDrag(to: local(pt))
            if canvas.drag?.moved == true { collapseOnClick = nil; toggleOnClick = nil }
            needsDisplay = true
        }
    }

    public override func mouseUp(with e: NSEvent) {
        panning = false
        if let w = wireDrag {
            wireDrag = nil
            finish(w)
            needsDisplay = true
            return
        }
        if let m = marquee {
            marquee = nil
            // A click on empty canvas (no rectangle) leaves the selection alone; the inspector keeps its Step.
            _ = m
            needsDisplay = true
            return
        }
        defer { collapseOnClick = nil; toggleOnClick = nil }
        guard let d = canvas.drag else { return }
        let moved = positionsBeforeDrop(d)
        guard let drop = canvas.endDrag() else { return }
        let id = d.id
        switch drop {
        case .click:
            if let c = collapseOnClick { model?.selectStep(c) }
            if let t = toggleOnClick { model?.selectStep(t, extend: true) }
        case .place(let p):
            if d.isMixer {
                model?.setMixerPosition(id, p)
            } else {
                var all = canvas.groupPositions(d)
                all[id] = p
                model?.placeSteps(all, freezingMixers: moved)
            }
        case .insertOnto(let link): model?.insertStep(id, onto: link)
        case .extract(let p): model?.extractStep(id, at: p)
        }
        needsDisplay = true
    }

    /// The boxes of the stacks the dragged Steps belong to, as they sat before the drag (so a stack's mixer box stays put).
    private func positionsBeforeDrop(_ d: StepsCanvas.Drag) -> [UUID: StepPosition] {
        guard !d.isMixer else { return [:] }
        var still = canvas
        still.cancelDrag()
        let l = still.layout()
        let moving = Set([d.id] + d.group.keys)
        var out: [UUID: StepPosition] = [:]
        for col in canvas.columns where col.count > 1 && col.contains(where: moving.contains) {
            if let head = col.first, let r = l.mixers[head] { out[head] = StepPosition(x: Double(r.minX), y: Double(r.minY)) }
        }
        return out
    }

    /// A wire dropped: connected, moved, removed (dropped on empty canvas) or refused (it snaps back, the target flashes red).
    private func finish(_ w: WireDrag) {
        guard let model else { return }
        guard let t = w.target else {
            if let k = w.replacing { if w.isKey { model.disconnectKey(k) } else { model.disconnect(k) } }
            return
        }
        if w.refusal != nil {
            refusedFlash = (t, w.isKey)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.refusedFlash = nil
            }
            return
        }
        if let k = w.replacing, k.from == w.from, k.to == t { return }
        if w.isKey {
            if let k = w.replacing { model.rewireKey(k, from: w.from, to: t) } else if let id = w.from.stepID { model.connectKey(from: id, to: t) }
        } else if let k = w.replacing {
            model.rewire(k, from: w.from, to: t)
        } else {
            model.connect(w.from, to: t)
        }
    }

    public override func otherMouseDown(with e: NSEvent) {
        panning = true
        lastPan = convert(e.locationInWindow, from: nil)
    }
    public override func otherMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    public override func otherMouseUp(with e: NSEvent) { panning = false }

    public override func scrollWheel(with e: NSEvent) {
        guard !nodes.isEmpty, !offersStart else { return }
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.command) {
            canvas.zoomBy(exp(e.scrollingDeltaY * 0.01), at: local(convert(e.locationInWindow, from: nil)))
        } else {
            canvas.panBy(CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY))
        }
        needsDisplay = true
    }

    public override func magnify(with e: NSEvent) {
        guard !nodes.isEmpty, !offersStart else { return }
        canvas.zoomBy(1 + e.magnification, at: local(convert(e.locationInWindow, from: nil)))
        needsDisplay = true
    }

    /// How many places a Step dragged by `dx` moves along a row: one per node pitch, kept inside the row.
    static func reorderDelta(dx: CGFloat, pitch: CGFloat, index: Int, count: Int) -> Int {
        guard pitch > 0, count > 0 else { return 0 }
        let raw = Int((dx / pitch).rounded())
        return min(max(raw, -index), count - 1 - index)
    }

    public override func rightMouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        switch hit(at: pt) {
        case .step(let id)?, .eye(let id)?:
            if !selectedSet.contains(id) { model?.selectStep(id) } else { model?.selectedStep = id }
            model?.selectedMixer = nil
            menus?.showStepMenu(id, at: screenPoint(e))
        case .mixer(let head)?:
            model?.selectedMixer = head
            menus?.showMixerMenu(head, at: screenPoint(e))
        case .dotOut?, .dotIn?, .keyOut?, .keyIn?: break
        case .insert(let id)?: menus?.showInsertMenu(after: id, at: screenPoint(e))
        case .input?: menus?.showLUTMenu(.graphInput, at: screenPoint(e))
        case .output?: menus?.showLUTMenu(.graphOutput, at: screenPoint(e))
        case nil:
            if !nodes.isEmpty, !offersStart { menus?.showCanvasMenu(at: screenPoint(e)) }
        }
    }

    // MARK: Keyboard

    public override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 { spaceDown = false; panning = false } else { super.keyUp(with: e) }
    }

    public override func keyDown(with e: NSEvent) {
        if e.keyCode == 49, !nodes.isEmpty, !offersStart { spaceDown = true; return }       // space: drag pans while held
        if let head = selectedMixer, !offersStart {
            switch e.keyCode {
            case 51, 117: model?.removeMixer(head); return
            case 53: cancelGesture(); model?.selectedMixer = nil; return
            default: break
            }
        }
        guard !offersStart, selected != nil || !selectedSet.isEmpty else { super.keyDown(with: e); return }
        switch e.keyCode {
        case 51, 117: model?.removeSelectedSteps()                           // delete, forward delete
        case 0 where e.modifierFlags.contains(.command): model?.selectSteps(Set(nodes.map(\.id)))
        case 123 where e.modifierFlags.contains(.option): if let id = selected { model?.moveStep(id, by: -1) }
        case 124 where e.modifierFlags.contains(.option): if let id = selected { model?.moveStep(id, by: 1) }
        case 53: cancelGesture()                                             // escape
        default: super.keyDown(with: e)
        }
    }
}
