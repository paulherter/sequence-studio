import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The whole Effect Controls panel on the shared toolkit: `EffectControlsView.layout` translated. Clip line across the
/// top, then the "Property" header beside the keyframe ruler, then the rows column (`EffectControlsDrawPanel`) left of
/// the divider and the keyframe lanes (`EffectKeyframeLanesDraw`) right of it, scrolling together. Coordinates: points,
/// y down, (0, 0) = the panel's top-left.
@MainActor public final class EffectControlsDrawView {
    public let model: EffectControlsModel
    public let rowsPanel: EffectControlsDrawPanel
    public let lanes: EffectKeyframeLanesDraw
    public let ruler: KeyframeRulerDraw
    /// The Graph Editor: replaces the lanes while `model.graphEditor` is on.
    public let graphEditor: GraphEditorDraw
    public var theme = DrawTheme() {
        didSet {
            rowsPanel.theme = theme; lanes.theme = theme; ruler.theme = theme; graphEditor.theme = theme
            for g in graphs.values { g.theme = theme }
            for v in valueGraphs.values { for (_, g) in v { g.theme = theme } }
        }
    }
    /// The value graphs of opened rows in value mode (one per component, stacked), made on first use.
    private var valueGraphs: [EffectProperty: [(EffectComponent, KeyframeGraphDraw)]] = [:]
    /// The component graph a press in value mode went to.
    private var valuePress: Int?
    /// The curve panes of opened rows (`SpeedGraphRow.speedGraph`), made on first use.
    private var graphs: [EffectProperty: InlineSpeedGraphDraw] = [:]
    public var size: CGSize = .zero { didSet { if size != oldValue { layout() } } }
    /// The divider position (Mac: `EffectControlsView.labelWidth`), clamped by `EffectControlsSplit`.
    public private(set) var labelWidth: CGFloat = EffectControlsSplit.load()
    public var persistLabelWidth: (CGFloat) -> Void = { EffectControlsSplit.save($0) }

    /// Popups and right-click menus of rows and lanes; the anchor is in panel points.
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)? {
        didSet {
            rowsPanel.onMenu = { [weak self] items, a in self?.onMenu?(items, a.offsetBy(dx: 0, dy: self?.top ?? 0)) }
            lanes.onMenu = { [weak self] items, a in
                guard let self else { return }
                onMenu?(items, a.offsetBy(dx: laneX, dy: top))
            }
        }
    }
    /// Key-tool dialogs (Scale Time, Loop, Wiggle, Velocity, Save Curve); nil leaves them out of the key menu.
    public var onPrompt: (@MainActor (_ prompt: KeyToolPrompt, _ done: @escaping @MainActor ([String]?) -> Void) -> Void)? {
        didSet { lanes.onPrompt = onPrompt; for v in valueGraphs.values { for (_, g) in v { g.onPrompt = onPrompt } } }
    }

    public init(model: EffectControlsModel) {
        self.model = model
        rowsPanel = EffectControlsDrawPanel(model: model)
        lanes = EffectKeyframeLanesDraw(model: model)
        ruler = KeyframeRulerDraw(model: model)
        graphEditor = GraphEditorDraw(model: model)
        graphEditor.keyMenu = { [weak self] onKey in self?.lanes.makeKeyItems(onKey: onKey) ?? [] }
    }

    private var editorOn: Bool { hasClip && model.graphEditor }

    // MARK: Layout

    private var hasClip: Bool { model.clip != nil }
    /// Clip line plus the header row; no clip = the rows column (its empty state) fills the panel.
    var top: CGFloat { hasClip ? ControlsMetrics.clipLine + ControlsMetrics.header : showsCaptions ? ControlsMetrics.clipLine : 0 }
    /// No clip and the column lists the captions (EffectControlsView.showsCaptions): the clip line names the caption
    /// track and the count; no "Property" header, ruler or lanes.
    private var showsCaptions: Bool { !hasClip && rowsPanel.clipSections?.mode == .captions }
    /// Left edge of the lanes = the divider.
    var laneX: CGFloat { hasClip ? EffectControlsSplit.clamp(labelWidth, total: size.width) : size.width }
    var lanesSize: CGSize { CGSize(width: max(size.width - laneX, 0), height: max(size.height - top, 0)) }

    /// After a model change (the host's dirty flag): rows first, then the lanes take them.
    public func relayout() {
        rowsPanel.relayout()
        layout()
    }

    func layout() {
        rowsPanel.size = CGSize(width: laneX, height: max(size.height - top, 0))
        lanes.size = lanesSize
        graphEditor.size = lanesSize
        ruler.size = CGSize(width: lanesSize.width, height: ControlsMetrics.header)
        syncLanes()
    }

    private func syncLanes() {
        lanes.rows = rowsPanel.rows
        lanes.scrollY = rowsPanel.scrollY
        lanes.contentBottom = rowsPanel.contentHeight
        for (p, g) in graphs { g.size = CGSize(width: lanesSize.width, height: graphRow(p)?.height ?? 0) }
    }

    public func tick() { rowsPanel.tick() }

    // MARK: Opened rows (SpeedGraphRow: the pane left of the divider is the rows column's, the curve sits over the lanes)

    /// The curve pane of an opened row, wired to the lanes as on the Mac (key items under the presets; a marquee that
    /// leaves the curve goes on over the lanes).
    func graph(_ p: EffectProperty) -> InlineSpeedGraphDraw {
        if let g = graphs[p] { return g }
        let g = InlineSpeedGraphDraw(property: p, model: model)
        g.theme = theme
        g.size = CGSize(width: lanesSize.width, height: graphRow(p)?.height ?? 0)
        g.extraMenu = { [weak self] in self?.lanes.makeKeyItems(onKey: true) ?? [] }
        g.outerMarquee = { [weak self] rect in
            guard let self, let row = graphRow(p) else { return [] }
            return lanes.externalMarquee(rect?.offsetBy(dx: 0, dy: row.y))
        }
        graphs[p] = g
        return g
    }

    /// `SpeedGraphRow`'s value graphs: one per component, wired to the model as on the Mac.
    func valueGraphs(_ p: EffectProperty) -> [(EffectComponent, KeyframeGraphDraw)] {
        if let v = valueGraphs[p] { return v }
        let model = model
        let v: [(EffectComponent, KeyframeGraphDraw)] = model.valueComponents(p).map { c in
            let g = KeyframeGraphDraw()
            g.theme = theme
            g.mode = .value
            g.displayScale = p == .volume ? 1 : max(abs(p.display(1, picture: model.displayPicture) - p.display(0, picture: model.displayPicture)), 1e-9)
            g.insets = GraphInsets(top: 14, left: 10, bottom: 14, right: 10)      // the lanes' inset: curve under the keys
            g.onEdit = { t in model.applyGraphEdit(p, component: c, track: t) }
            g.onSelectionChange = { ids in model.setSelection(for: p, ids: ids) }
            g.onLibraryChange = { lib in model.easingLibrary = lib; model.onLibraryChange?(lib) }
            g.onModeChange = { model.setGraphMode($0, for: p) }
            g.onZoom = { f, anchor in model.zoom(by: f, around: anchor) }
            g.onPan = { model.panViewport(bySeconds: $0) }
            g.onPrompt = onPrompt
            return (c, g)
        }
        valueGraphs[p] = v
        return v
    }

    /// `SpeedGraphRow.update` + `layout` for the value graphs of `p` in a pane `size` big.
    private func syncValueGraphs(_ p: EffectProperty, size: CGSize) -> [(KeyframeGraphDraw, CGRect)] {
        let v = valueGraphs(p), h = size.height / CGFloat(max(v.count, 1))
        let local = model.localPlayhead, sel = model.selectedKeyIDs(p)
        return v.enumerated().map { i, e in
            let (c, g) = e
            g.size = CGSize(width: size.width, height: h)
            let t = model.graphTrack(p, component: c)
            if g.track != t { g.track = t }
            g.selectedKeyIDs = sel
            g.playheadSeconds = model.playheadInClip ? Double(local.value) / Double(local.timescale) : nil
            g.frameDuration = model.frameDuration
            g.maxTime = model.duration
            g.visibleTime = model.viewport.range
            g.easingLibrary = model.easingLibrary
            return (g, CGRect(x: 0, y: CGFloat(i) * h, width: size.width, height: h))
        }
    }

    private func isSpeed(_ p: EffectProperty) -> Bool { model.graphMode(for: p) == .speed }

    private func graphRow(_ p: EffectProperty) -> EffectRow? { rowsPanel.rows.first { $0.kind == .graph(p) } }

    /// The opened rows on screen with their pane in panel points.
    private func graphFrames() -> [(EffectProperty, CGRect)] {
        guard hasClip, lanesSize.width > 0 else { return [] }
        return rowsPanel.rows.compactMap { r in
            guard case .graph(let p) = r.kind else { return nil }
            let f = CGRect(x: laneX, y: top + r.y - rowsPanel.scrollY, width: lanesSize.width, height: r.height)
            return f.maxY > top && f.minY < size.height ? (p, f) : nil
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let t = theme, bounds = CGRect(origin: .zero, size: size)
        syncLanes()
        c.saveGState()
        c.clip(to: bounds)
        c.fill(bounds, t.panel)
        if hasClip { drawHeader(&c) } else if showsCaptions { drawCaptionHeader(&c) }
        let lw = laneX, top = top
        c.saveGState()
        c.translateBy(x: 0, y: top)
        rowsPanel.draw(&c)
        c.restoreGState()
        if hasClip, lanesSize.width > 0 {
            c.saveGState(); c.translateBy(x: lw, y: ControlsMetrics.clipLine); ruler.draw(&c); c.restoreGState()
            c.saveGState(); c.translateBy(x: lw, y: top)
            if editorOn { graphEditor.size = lanesSize; graphEditor.draw(&c) } else { lanes.draw(&c) }
            c.restoreGState()
            c.saveGState()
            c.clip(to: CGRect(x: lw, y: top, width: lanesSize.width, height: lanesSize.height))
            for (p, f) in graphFrames() {
                c.saveGState(); c.translateBy(x: f.minX, y: f.minY)
                if isSpeed(p) {
                    let g = graph(p)
                    g.size = f.size
                    g.draw(&c)
                } else {
                    for (g, r) in syncValueGraphs(p, size: f.size) {
                        c.saveGState(); c.translateBy(x: r.minX, y: r.minY); g.draw(&c); c.restoreGState()
                    }
                }
                c.restoreGState()
            }
            c.restoreGState()
            // The divider: a 1 pt line from the clip line down (its 7 pt grab zone is invisible).
            c.fill(CGRect(x: lw, y: ControlsMetrics.clipLine, width: 1, height: max(size.height - ControlsMetrics.clipLine, 0)),
                   dividerActive ? t.accent : t.trackHeaderLine)
        }
        c.restoreGState()
    }

    /// v9 `.clhead`: icon, name, meta with the panel's 12 pt inset; then "Property" over the rows column.
    private func drawHeader(_ c: inout Canvas) {
        guard let clip = model.clip else { return }
        let t = theme, ch = ControlsMetrics.clipLine, rh = ControlsMetrics.header
        let lead = CGFloat(DrawTheme.Spacing.md), trail = ControlsGrid.trailing, iconSide: CGFloat = 14
        let fs = CGFloat(DrawTheme.TypeSize.body)
        c.draw(icon: clip.kind == .audio ? .waveform : .film, at: CGPoint(x: lead, y: ((ch - iconSide) / 2).rounded()),
               size: iconSide, t.label2)
        let name = model.isMulti ? "\(model.peers.count + 1) clips selected" : clip.name
        let nameX = lead + iconSide + CGFloat(DrawTheme.Spacing.sm), room = max(size.width - nameX - trail, 0)
        let nameW = min(c.size(of: name, fontSize: fs, face: c.semibold).width + 4, room)
        c.draw(name, in: CGRect(x: nameX, y: 0, width: nameW, height: ch), fontSize: fs, t.label, face: c.semibold)
        let infoX = nameX + nameW + CGFloat(DrawTheme.Spacing.sm)
        c.draw(clipMeta(clip), in: CGRect(x: infoX, y: 0, width: max(size.width - trail - infoX, 0), height: ch), fontSize: fs, t.label3)
        c.fill(CGRect(x: 0, y: ch - 1, width: size.width, height: 1), t.trackRowLine)
        c.draw(SQL10n.string("Property"), in: CGRect(x: lead, y: ch, width: max(laneX - lead - trail, 0), height: rh),
               fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label3)
        c.fill(CGRect(x: 0, y: ch + rh - 1, width: laneX, height: 1), t.trackRowLine)
    }

    /// The caption track in focus and "Captions · count" on the clip line (EffectControlsView.updateHeader).
    private func drawCaptionHeader(_ c: inout Canvas) {
        guard let s = rowsPanel.clipSections?.captionSummary else { return }
        let t = theme, ch = ControlsMetrics.clipLine, lead = CGFloat(DrawTheme.Spacing.md), iconSide: CGFloat = 14
        let fs = CGFloat(DrawTheme.TypeSize.body)
        c.draw(icon: .captions, at: CGPoint(x: lead, y: ((ch - iconSide) / 2).rounded()), size: iconSide, t.label2)
        let nameX = lead + iconSide + CGFloat(DrawTheme.Spacing.sm), room = max(size.width - nameX - ControlsGrid.trailing, 0)
        let nameW = min(c.size(of: s.name, fontSize: fs, face: c.semibold).width + 4, room)
        c.draw(s.name, in: CGRect(x: nameX, y: 0, width: nameW, height: ch), fontSize: fs, t.label, face: c.semibold)
        let infoX = nameX + nameW + CGFloat(DrawTheme.Spacing.sm)
        c.draw(SQL10n.string("Captions") + " \u{00B7} \(s.count)", in: CGRect(x: infoX, y: 0, width: max(size.width - ControlsGrid.trailing - infoX, 0), height: ch),
               fontSize: fs, t.label3)
        c.fill(CGRect(x: 0, y: ch - 1, width: size.width, height: 1), t.trackRowLine)
    }

    private func clipMeta(_ c: Clip) -> String {
        let kindName = ClipSectionMode.resolve(c).kindName
        let timeline = model.timeline?()
        let track = timeline?.tracks.first { $0.clips.contains { $0.id == c.id } }.flatMap { timeline?.trackLabel($0.id) }
        return EffectControlsHeaderText.clipMeta(sequence: timeline?.name, track: track, start: c.start, end: c.start + model.duration,
                                                 frameDuration: model.frameDuration, kindName: kindName)
    }

    /// Kind and duration of the shown clip: the tooltip over the meta text.
    func clipInfoTip() -> String? {
        guard let c = model.clip else { return nil }
        return EffectControlsHeaderText.clipInfo(kind: c.kind, duration: model.duration, frameDuration: model.frameDuration,
                                                 kindName: ClipSectionMode.resolve(c).kindName)
    }

    // MARK: Input

    public enum Part: Equatable, Sendable { case header, rows, ruler, lanes, graph(EffectProperty), graphEditor, divider, none }

    public func part(at p: CGPoint) -> Part {
        guard p.x >= 0, p.y >= 0, p.x < size.width, p.y < size.height else { return .none }
        guard hasClip else { return showsCaptions && p.y < top ? .header : .rows }
        let lw = laneX
        if p.y >= ControlsMetrics.clipLine, lanesSize.width > 0, abs(p.x - lw) <= 3.5 { return .divider }
        if p.y < ControlsMetrics.clipLine { return .header }
        if p.x >= lw {
            if p.y < top { return .ruler }
            if editorOn { return .graphEditor }
            if let g = graphFrames().first(where: { $0.1.contains(p) }) { return .graph(g.0) }
            return .lanes
        }
        return p.y < top ? .header : .rows
    }

    private var capture: Part = .none
    private var pressModifiers: InputModifiers = []
    private var divider: (x: CGFloat, width: CGFloat)?
    var dividerActive: Bool { divider != nil || hoverPart == .divider }
    private var hoverPart: Part = .none
    /// The last press was in the lanes or ruler: keys go to the lanes (Delete removes keys, Ctrl+C / V copy keys).
    public private(set) var lanesFocused = false

    private func lanePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - laneX, y: p.y - top) }
    private func rulerPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - laneX, y: p.y - ControlsMetrics.clipLine) }
    private func rowsPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y - top) }
    private func graphPoint(_ p: CGPoint, _ prop: EffectProperty) -> CGPoint {
        let y = graphRow(prop).map { top + $0.y - rowsPanel.scrollY } ?? top
        return CGPoint(x: p.x - laneX, y: p.y - y)
    }

    public func mouseDown(at p: CGPoint, clickCount: Int, modifiers: InputModifiers) {
        capture = part(at: p); pressModifiers = modifiers
        switch capture {
        case .rows:
            lanesFocused = false
            rowsPanel.mouseDown(at: rowsPoint(p), clickCount: clickCount, modifiers: modifiers)
        case .lanes:
            lanesFocused = true
            model.onPointerDown?()
            lanes.mouseDown(at: lanePoint(p), modifiers: modifiers)
        case .ruler:
            lanesFocused = true
            if !modifiers.contains(.secondary) { ruler.mouseDown(at: rulerPoint(p), modifiers: modifiers) }
        case .graph(let prop):
            lanesFocused = true
            model.onPointerDown?()
            let gp = graphPoint(p, prop)
            if !isSpeed(prop), let row = graphRow(prop) {
                let parts = syncValueGraphs(prop, size: CGSize(width: lanesSize.width, height: row.height))
                guard let i = parts.firstIndex(where: { gp.y < $0.1.maxY }) ?? parts.indices.last else { break }
                let (g, r) = parts[i], lp = CGPoint(x: gp.x, y: gp.y - r.minY)
                if modifiers.contains(.secondary) {
                    capture = .none
                    let items = g.contextMenu(at: lp)
                    if !items.isEmpty { onMenu?(items, CGRect(origin: p, size: .zero)) }
                } else {
                    valuePress = i
                    g.mouseDown(at: lp, shift: modifiers.contains(.shift))
                }
                break
            }
            let g = graph(prop)
            if modifiers.contains(.secondary) {
                capture = .none
                let items = g.contextMenu(at: gp)
                if !items.isEmpty { onMenu?(items, CGRect(origin: p, size: .zero)) }
            } else {
                g.press(at: gp, shift: modifiers.contains(.shift))
            }
        case .graphEditor:
            lanesFocused = true
            model.onPointerDown?()
            if modifiers.contains(.secondary) {
                capture = .none
                let items = graphEditor.contextMenu(at: lanePoint(p))
                if !items.isEmpty { onMenu?(items, CGRect(origin: p, size: .zero)) }
            } else {
                graphEditor.mouseDown(at: lanePoint(p), modifiers: modifiers)
            }
        case .divider: divider = (p.x, laneX)
        case .header, .none: break
        }
        syncLanes()
    }

    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers? = nil) {
        let m = modifiers ?? pressModifiers
        switch capture {
        case .rows: rowsPanel.mouseDragged(to: rowsPoint(p), modifiers: modifiers)
        case .lanes: lanes.mouseDragged(to: lanePoint(p), modifiers: m)
        case .ruler: ruler.mouseDragged(to: rulerPoint(p), modifiers: m)
        case .graph(let prop):
            if let (g, r) = valuePressed(prop) {
                let gp = graphPoint(p, prop)
                g.mouseDragged(to: CGPoint(x: gp.x, y: gp.y - r.minY), shift: m.contains(.shift))
            } else {
                graph(prop).dragGesture(to: graphPoint(p, prop), shift: m.contains(.shift))
            }
        case .graphEditor: graphEditor.mouseDragged(to: lanePoint(p), modifiers: m)
        case .divider:
            if let d = divider { setLabelWidth(d.width + p.x - d.x) }
        case .header, .none: break
        }
        syncLanes()
    }

    public func mouseUp(at p: CGPoint) {
        switch capture {
        case .rows: rowsPanel.mouseUp(at: rowsPoint(p))
        case .lanes: lanes.mouseUp(at: lanePoint(p))
        case .ruler: ruler.mouseUp(at: rulerPoint(p))
        case .graph(let prop):
            if let (g, r) = valuePressed(prop) {
                let gp = graphPoint(p, prop)
                g.mouseUp(at: CGPoint(x: gp.x, y: gp.y - r.minY))
            } else {
                graph(prop).release()
            }
            valuePress = nil
        case .graphEditor: graphEditor.mouseUp(at: lanePoint(p))
        case .divider: if divider != nil { persistLabelWidth(labelWidth) }; divider = nil
        case .header, .none: break
        }
        capture = .none
        syncLanes()
    }

    public func mouseMoved(to p: CGPoint?) {
        let at = p.map(part(at:)) ?? .none
        hoverPart = at
        rowsPanel.mouseMoved(to: at == .rows ? p.map(rowsPoint) : nil)
        lanes.mouseMoved(to: at == .lanes ? p.map(lanePoint) : nil)
        ruler.mouseMoved(to: at == .ruler ? p.map(rulerPoint) : nil)
        graphEditor.mouseMoved(to: at == .graphEditor ? p.map(lanePoint) : nil)
        for (prop, g) in graphs { g.mouseMoved(to: at == .graph(prop) ? p.map { graphPoint($0, prop) } : nil) }
        for (prop, v) in valueGraphs {
            let h = (graphRow(prop)?.height ?? 0) / CGFloat(max(v.count, 1))
            for (i, e) in v.enumerated() {
                e.1.mouseMoved(to: at == .graph(prop) ? p.map { let gp = graphPoint($0, prop); return CGPoint(x: gp.x, y: gp.y - CGFloat(i) * h) } : nil)
            }
        }
    }

    public var isDragging: Bool { capture != .none }

    /// The value graph a press went to, with its frame in the pane.
    private func valuePressed(_ p: EffectProperty) -> (KeyframeGraphDraw, CGRect)? {
        guard let i = valuePress, let row = graphRow(p) else { return nil }
        let parts = syncValueGraphs(p, size: CGSize(width: lanesSize.width, height: row.height))
        return i < parts.count ? parts[i] : nil
    }

    /// Sets the divider position (clamped) and lays out again.
    public func setLabelWidth(_ w: CGFloat) {
        let c = EffectControlsSplit.clamp(w, total: size.width)
        guard c != labelWidth else { return }
        labelWidth = c
        layout()
    }

    /// Tooltip at `p`: a row's help, a key's shape, the clip's kind and duration.
    public func help(at p: CGPoint) -> String? {
        switch part(at: p) {
        case .rows: rowsPanel.help(at: rowsPoint(p))
        case .lanes: lanes.help(at: lanePoint(p))
        case .graphEditor: graphEditor.help(at: lanePoint(p))
        case .header: p.y < ControlsMetrics.clipLine ? clipInfoTip() : nil
        default: nil
        }
    }

    /// Wheel: over the lanes or ruler horizontal pans and Option / Ctrl zooms; plain vertical scrolls the rows (and with
    /// them the lanes).
    @discardableResult
    public func scroll(at p: CGPoint, dx: CGFloat, dy: CGFloat, precise: Bool, modifiers: InputModifiers) -> Bool {
        let at = part(at: p)
        if at == .graphEditor, graphEditor.scroll(at: lanePoint(p), dx: dx, dy: dy, modifiers: modifiers) { return true }
        if at == .lanes || { if case .graph = at { true } else { false } }(), lanes.scroll(at: lanePoint(p), dx: dx, dy: dy, modifiers: modifiers) { return true }
        if at == .ruler, ruler.scroll(at: rulerPoint(p), dx: dx, dy: dy, modifiers: modifiers) { return true }
        // Over the lanes the rows scroll at a point no field sits under.
        let rp = at == .rows ? rowsPoint(p) : CGPoint(x: -1, y: p.y - top)
        let used = rowsPanel.scroll(at: rp, dy: dy, precise: precise, modifiers: at == .rows ? modifiers : [])
        syncLanes()
        return used
    }

    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        // Cmd+C / X / V belong to Effect Controls whenever it has the keys (the host only sends them here when the panel is
        // focused), not only with the lanes focused: the selected keyframes, else the selected effect (the AppKit
        // `copyFocused` / `cutFocused` / `pasteFocused`). While a value is typed they edit the text instead. Without
        // anything to copy or paste, the key falls through to the timeline.
        if modifiers == .command, rowsPanel.focusedField == nil, rowsPanel.focusedText == nil {
            switch k {
            case .character("c") where model.canCopyFocused: return model.copyFocused()
            case .character("x") where model.canCutFocused: model.cutFocused(); return true
            case .character("v") where model.canPasteFocused || model.hasKeyClipboard: _ = model.pasteFocused(); return true
            default: break
            }
        }
        if lanesFocused {
            if modifiers.contains(.command) {
                switch k {
                case .character("c"): return model.copyKeys()
                case .character("v"): return model.pasteKeys()
                default: break
                }
            }
            if editorOn { if graphEditor.key(k, modifiers: modifiers) { return true } }
            else if lanes.key(k, modifiers: modifiers) { return true }
        }
        let used = rowsPanel.key(k, modifiers: modifiers)
        syncLanes()
        return used
    }

    // MARK: Pixels

    private var clicks = ClickCounter()

    /// Host glue: an `InputEvent` in pixels, the panel at `origin` (points) in the window, `scale` pixels per point.
    /// shortcut: a drag keeps the modifiers of its press (`InputEvent.mouseDragged` has none); upgrade when hosts send them.
    @discardableResult
    public func handle(_ e: InputEvent, scale: Float, origin: CGPoint = .zero) -> Bool {
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x / scale) - origin.x, y: CGFloat(y / scale) - origin.y) }
        switch e {
        case .mouseDown(let x, let y, let mods):
            let p = pt(x, y)
            mouseDown(at: p, clickCount: clicks.press(x: Float(p.x), y: Float(p.y), now: rowsPanel.clock()), modifiers: mods)
        case .mouseDragged(let x, let y): mouseDragged(to: pt(x, y))
        case .mouseUp(let x, let y): mouseUp(at: pt(x, y))
        case .mouseMoved(let x, let y):
            mouseMoved(to: pt(x, y))
            HostHover.current.offerTip(help(at: pt(x, y)))
        case .scroll(let x, let y, let dx, let dy, let mods):
            return scroll(at: pt(x, y), dx: CGFloat(dx / scale), dy: CGFloat(dy / scale), precise: true, modifiers: mods)
        case .keyDown(let k, let mods): return key(k, modifiers: mods)
        }
        return true
    }
}
