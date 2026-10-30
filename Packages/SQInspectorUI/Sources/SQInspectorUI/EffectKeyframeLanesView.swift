import AppKit
import SQCore

/// The right side of Effect Controls: one keyframe lane per row, clip range edge to edge.
/// Property rows show their own keys; a section row shows summary keys (all children, one glyph per time), open or
/// collapsed. Key glyphs per the design source (`.kf`): diamond = steady, round = eased, selected = accent.
/// Click selects (Shift toggles), drag moves the selection in time (frame snapped, one undo step),
/// drag on empty space is a marquee, right-click opens the easing menu. Never mutates anything itself:
/// every change goes through `EffectControlsModel`.
public final class EffectKeyframeLanesView: NSView {
    public let model: EffectControlsModel
    public var rows: [EffectRow] = [] { didSet { displayCache = nil; needsDisplay = true } }
    /// The collapsed sections and open color groups the current `rows` were built for (set by the panel together with
    /// `rows`). Summary strips follow this, not the live model: between the model change and the rebuild the old rows
    /// are still drawn, and mixing them with the new state showed every key twice (strip and own row) for a frame.
    var rowsCollapsed: Set<EffectSection>?
    var rowsOpenGroups: Set<String>?
    private var collapsedForDrawing: Set<EffectSection> { rowsCollapsed ?? model.collapsedSections }
    private var openGroupsForDrawing: Set<String> { rowsOpenGroups ?? model.openColorGroups }
    /// Asks for a preset name. Default: modal alert with a text field. Return nil to cancel.
    public var namePrompt: @MainActor (String) -> String? = EffectKeyframeLanesView.runNameAlert

    static let hitRadius: CGFloat = EffectKeyframeLanesGeometry.hitRadius
    private static let dragThreshold: CGFloat = 3

    enum Hit: Equatable {
        case key(EffectProperty, UUID, Time)
        case summary(EffectSection, Time)
        case groupSummary(ClipEffect.ID, String, Time)
        case none
    }

    private enum Drag {
        case keys(downX: CGFloat, downTime: Time, started: Bool, hit: Hit, shift: Bool, wasSelected: Bool, duplicate: Bool)
        case marquee(origin: CGPoint, base: Set<SummaryMember>, shift: Bool)
    }
    private var drag: Drag?
    private var marquee: CGRect?

    public init(model: EffectControlsModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Keyframes")
        wantsLayer = true
        playheadLine.isHidden = true
        addSubview(playheadLine)
        emptyHint.isHidden = true
        addSubview(emptyHint)
        NotificationCenter.default.addObserver(self, selector: #selector(magicFramesChanged), name: MagicTrackedFrames.changed, object: nil)
    }

    /// A Magic mask's tracked frames were read or changed: redraw if the shown ones did.
    @objc private func magicFramesChanged() { refreshContent() }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var geometry: KeyframeLaneGeometry { model.laneGeometry(width: bounds.width) }

    // MARK: Display cache, playhead layer, drawing

    private let playheadLine = PlayheadLineView(color: Theme.Colors.playhead)
    /// No key anywhere on the clip: the empty area under the rows says how to make one (INTERACTION-AUDIT §10).
    let emptyHint = EmptyStateView(title: "No keyframes", hint: "Click a property's diamond to animate it")

    /// True while the shown clip has no keyframe on any property or mask path.
    var showsNoKeysHint: Bool { EffectKeyframeLanesGeometry.showsNoKeysHint(model) }

    /// Where the Controls column's content ends (rows and the sections placed after them: Audio, the caption list).
    /// The panel sets it together with `rows`; the hint starts below it, never beside a section.
    var contentBottom: CGFloat = 0 { didSet { if oldValue != contentBottom { layoutEmptyHint() } } }

    private func layoutEmptyHint() {
        let top = max(rows.last.map { $0.y + $0.height } ?? 0, contentBottom)
        let h = bounds.height - top
        emptyHint.isHidden = !showsNoKeysHint || h < 48
        emptyHint.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(h, 0))
    }

    /// Everything the drawn glyphs depend on except the playhead.
    private struct DisplayKey: Equatable {
        var revision: Int; var selection: Set<SummaryMember>; var viewport: KeyframeViewport; var size: CGSize
        var collapsed: Set<EffectSection>; var openGroups: Set<String>; var magicRevision: Int
    }
    /// Row backgrounds and one path per glyph look (4 fills draw every key), built when `DisplayKey` or the rows change.
    private struct DisplayCache {
        var key: DisplayKey
        var laneLines = CGMutablePath()      // 1 pt line under every row
        var plain = CGMutablePath(), selected = CGMutablePath(), summary = CGMutablePath(), summarySelected = CGMutablePath()
        /// A Magic mask's tracked frames (smaller, dimmer glyphs); selected ones go to `trackedSelected`.
        var tracked = CGMutablePath(), trackedSelected = CGMutablePath()
    }
    private var displayCache: DisplayCache?
    private(set) var cacheBuilds = 0         // tests: how often the cache was rebuilt
    private(set) var contentDrawCount = 0    // tests: how often draw ran

    private var displayKey: DisplayKey {
        DisplayKey(revision: model.clipRevision, selection: model.selection, viewport: model.viewport, size: bounds.size,
                   collapsed: collapsedForDrawing, openGroups: openGroupsForDrawing, magicRevision: model.magicFrames.revision)
    }

    /// Model change other than the playhead: redraws only when something drawn changed.
    func refreshContent() {
        if displayCache?.key != displayKey { needsDisplay = true; layoutEmptyHint() }
        movePlayhead()
    }

    /// Playhead tick: moves the playhead layer, nothing is redrawn.
    func movePlayhead() {
        playheadLine.isHidden = !model.playheadInClip
        guard model.playheadInClip else { return }
        playheadLine.frame = PlayheadLineView.frame(centerX: geometry.x(for: model.localPlayhead), height: bounds.height)   // v9 `.kph`: 2 pt
    }

    public override func layout() { super.layout(); layoutEmptyHint(); movePlayhead() }

    /// Y of the 1 pt baseline of a property row: its bottom edge (view is flipped, rows grow downward).
    static func baselineY(row y: CGFloat, height: CGFloat) -> CGFloat { y + height - 1 }
    private static func addGlyph(_ shape: KeyShape, at c: CGPoint, to path: CGMutablePath) {
        KeyGlyphPath.add(shape, at: c, side: ControlsMetrics.keySide, to: path)
    }

    private func buildCache() -> DisplayCache {
        cacheBuilds += 1
        var cache = DisplayCache(key: displayKey)
        let geo = geometry
        // One uniform background; one 1 pt neutral line under every row (Premiere look). No zebra, no connectors.
        for row in rows {
            cache.laneLines.addRect(CGRect(x: 0, y: Self.baselineY(row: row.y, height: row.height), width: bounds.width, height: 1))
        }
        let slack = Self.hitRadius * 2     // keys outside the visible x range are not drawn
        func inView(_ x: CGFloat) -> Bool { x >= -slack && x <= bounds.width + slack }
        for row in rows {
            let cy = row.y + row.height / 2
            switch row.kind {
            case .property(let p):
                let sel = model.selectedKeyIDs(p)
                let glyphs = model.track(p)?.glyphs ?? []
                for k in glyphs {
                    let x = geo.x(for: k.time)
                    guard inView(x) else { continue }
                    Self.addGlyph(k.glyph.shape, at: CGPoint(x: x, y: cy), to: sel.contains(k.id) ? cache.selected : cache.plain)
                }
            case .section(let s):
                guard showsSectionSummary(s) else { continue }
                for key in model.summaryKeys(s) { addSummary(key, cy, geo, &cache) }
            case .colorGroup(let id, let key):
                guard showsGroupSummary(id, key) else { continue }
                for k in model.colorGroupSummaryKeys(id, key) { addSummary(k, cy, geo, &cache) }
            case .maskControls(let id):
                // The mask's Path keys, or a Magic mask's tracked frames (correction frames as normal keys).
                let p = EffectProperty.maskPath(id)
                let sel = model.selectedKeyIDs(p)
                for k in model.track(p)?.glyphs ?? [] {
                    let x = geo.x(for: k.time)
                    guard inView(x) else { continue }
                    Self.addGlyph(k.glyph.shape, at: CGPoint(x: x, y: cy), to: sel.contains(k.id) ? cache.selected : cache.plain)
                }
                for k in model.magicKeys(id) {
                    let x = geo.x(for: k.time)
                    guard inView(x) else { continue }
                    let c = CGPoint(x: x, y: cy), on = sel.contains(k.id)
                    if k.isCorrection { Self.addGlyph(.diamond, at: c, to: on ? cache.selected : cache.plain) }
                    else {
                        KeyGlyphPath.add(.diamond, at: c, side: ControlsMetrics.keySide * ControlsMetrics.trackedKeyScale,
                                         to: on ? cache.trackedSelected : cache.tracked)
                    }
                }
            default: break
            }
        }
        return cache
    }

    /// A section or group row carries summary keys only while it is collapsed: open, the keys live on the property rows
    /// (the maintainer: a key must not show twice, on the header and on its property).
    func showsSectionSummary(_ s: EffectSection) -> Bool { Self.showsSummary(open: !collapsedForDrawing.contains(s)) }
    func showsGroupSummary(_ id: ClipEffect.ID, _ key: String) -> Bool {
        Self.showsSummary(open: openGroupsForDrawing.contains(EffectControlsModel.colorGroupID(id, key)))
    }
    static func showsSummary(open: Bool) -> Bool { !open }

    private func addSummary(_ key: SummaryKey, _ cy: CGFloat, _ geo: KeyframeLaneGeometry, _ cache: inout DisplayCache) {
        let x = geo.x(for: key.time)
        guard x >= -Self.hitRadius * 2, x <= bounds.width + Self.hitRadius * 2 else { return }
        let shape = Self.summaryGlyph(key, model: model).shape
        Self.addGlyph(shape, at: CGPoint(x: x, y: cy), to: model.isSelected(key) ? cache.summarySelected : cache.summary)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        contentDrawCount += 1
        if displayCache?.key != displayKey { displayCache = nil }
        let cache = displayCache ?? buildCache()
        displayCache = cache
        ctx.setFillColor(Theme.Colors.lane.cgColor); ctx.fill(bounds)       // v9 `.kg > .r`
        ctx.setFillColor(Theme.Colors.trackRowLine.cgColor); ctx.addPath(cache.laneLines); ctx.fillPath()
        if let c = hoverCenter {
            let r = Self.hitRadius + 2
            ctx.setFillColor(Theme.Selection.hover.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r),
                               cornerWidth: Theme.Radius.small, cornerHeight: Theme.Radius.small, transform: nil))
            ctx.fillPath()
        }
        // v9 `.dm`: every key sits on a 1.5 pt ring of the lane color, so neighbors stay apart.
        ctx.setStrokeColor(Theme.Colors.lane.cgColor); ctx.setLineWidth(2 * ControlsMetrics.keyRing)
        for path in [cache.plain, cache.summary, cache.selected, cache.summarySelected] { ctx.addPath(path) }
        ctx.strokePath()
        ctx.setFillColor(Theme.Colors.keyframeTracked.cgColor); ctx.addPath(cache.tracked); ctx.fillPath()
        ctx.setFillColor(Theme.Colors.keyframe.cgColor); ctx.addPath(cache.plain); ctx.fillPath()
        ctx.setFillColor(Theme.Colors.keyframe.cgColor); ctx.addPath(cache.summary); ctx.fillPath()
        ctx.setFillColor(Theme.Colors.accent.cgColor)
        ctx.addPath(cache.selected); ctx.addPath(cache.summarySelected); ctx.addPath(cache.trackedSelected); ctx.fillPath()
        if let m = marquee {
            ctx.setFillColor(Theme.Colors.accentTint.cgColor); ctx.fill(m)
            ctx.setStrokeColor(Theme.Colors.accent.cgColor); ctx.setLineWidth(1)
            ctx.stroke(m.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// Summary glyph: per side hold if every member is hold, eased if any member is eased, else linear.
    static func summaryGlyph(_ key: SummaryKey, model: EffectControlsModel) -> KeyGlyph {
        EffectKeyframeLanesGeometry.summaryGlyph(key, model: model)
    }

    // MARK: Hit testing

    func hit(at p: CGPoint) -> Hit {
        guard let row = EffectControlsLayout.row(at: p.y, in: rows) else { return .none }
        let geo = geometry
        let start = model.clip?.start ?? .zero
        switch row.kind {
        case .property(let p0):
            let ks = model.keys(p0)
            let locals = ks.map { $0.time - start }
            if let i = geo.nearestIndex(toX: p.x, in: locals, radius: Self.hitRadius) { return .key(p0, ks[i].id, locals[i]) }
        case .section(let s):
            guard showsSectionSummary(s) else { break }
            let groups = model.summaryKeys(s)
            if let i = geo.nearestIndex(toX: p.x, in: groups.map(\.time), radius: Self.hitRadius) { return .summary(s, groups[i].time) }
        case .colorGroup(let id, let key):
            guard showsGroupSummary(id, key) else { break }
            let groups = model.colorGroupSummaryKeys(id, key)
            if let i = geo.nearestIndex(toX: p.x, in: groups.map(\.time), radius: Self.hitRadius) { return .groupSummary(id, key, groups[i].time) }
        case .maskControls(let id):
            let mp = EffectProperty.maskPath(id)
            let ks = model.laneKeys(mp)
            if let i = geo.nearestIndex(toX: p.x, in: ks.map(\.time), radius: Self.hitRadius) { return .key(mp, ks[i].id, ks[i].time) }
        default: break
        }
        return .none
    }

    private func select(_ h: Hit, extend: Bool) {
        switch h {
        case .key(let p, let id, _): model.selectKey(p, id: id, extend: extend)
        case .summary(let s, let t):
            if let k = model.summaryKeys(s).first(where: { $0.time == t }) { model.selectSummary(k, extend: extend) }
        case .groupSummary(let id, let key, let t):
            if let k = model.colorGroupSummaryKeys(id, key).first(where: { $0.time == t }) { model.selectSummary(k, extend: extend) }
        case .none: break
        }
    }

    private func isSelected(_ h: Hit) -> Bool {
        switch h {
        case .key(let p, let id, _): model.selectedKeyIDs(p).contains(id)
        case .summary(let s, let t): model.summaryKeys(s).first { $0.time == t }.map(model.isSelected) ?? false
        case .groupSummary(let id, let key, let t): model.colorGroupSummaryKeys(id, key).first { $0.time == t }.map(model.isSelected) ?? false
        case .none: false
        }
    }

    // MARK: Hover and cursors (INTERACTION-AUDIT §7)

    private var hoverHit: Hit = .none
    private var tracking: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    /// Center of the hovered glyph (nil = nothing hovered).
    var hoverCenter: CGPoint? { center(of: hoverHit) }

    private func center(of h: Hit) -> CGPoint? {
        let row: EffectRow?, time: Time
        switch h {
        case .key(let p, _, let t): row = rows.first { Self.row($0, shows: p) }; time = t
        case .summary(let s, let t): row = rows.first { if case .section(s) = $0.kind { return true } else { return false } }; time = t
        case .groupSummary(let id, let key, let t):
            row = rows.first { if case .colorGroup(id, key) = $0.kind { return true } else { return false } }; time = t
        case .none: return nil
        }
        guard let row else { return nil }
        return CGPoint(x: geometry.x(for: time), y: row.y + row.height / 2)
    }

    /// The row whose lane carries the keys of `p`: its own row, or for a mask's Path the mask's controls row.
    static func row(_ r: EffectRow, shows p: EffectProperty) -> Bool { EffectKeyframeLanesGeometry.row(r, shows: p) }

    private func setHover(_ h: Hit) {
        guard h != hoverHit else { return }
        hoverHit = h
        if case .key(let p, let id, _) = h, let g = model.track(p)?.glyphs.first(where: { $0.id == id }) {
            toolTip = g.glyph.shape.title      // the shape's name: Linear, Eased, Hold, Hold Ahead
        } else {
            toolTip = nil
        }
        needsDisplay = true
    }


    public override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let h = hit(at: convert(event.locationInWindow, from: nil))
        setHover(h)
        KeyframeCursor.cursor(overGrip: h != .none, dragging: false).set()
    }

    public override func mouseExited(with event: NSEvent) {
        guard drag == nil else { return }
        setHover(.none)
        NSCursor.arrow.set()
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        escapeCancelled = false
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        let h = hit(at: p)
        if h == .none {
            if let row = EffectControlsLayout.row(at: p.y, in: rows), case .property(let prop) = row.kind { model.focusedProperty = prop }
            let base = shift ? model.selection : []
            if !shift { model.clearSelection() }
            drag = .marquee(origin: p, base: base, shift: shift)
            return
        }
        let was = isSelected(h)
        if shift { select(h, extend: true) } else if !was { select(h, extend: false) }
        drag = .keys(downX: p.x, downTime: geometry.time(at: p.x, frameDuration: model.frameDuration),
                     started: false, hit: h, shift: shift, wasSelected: was, duplicate: false)
    }

    public override func mouseDragged(with event: NSEvent) {
        if escapeCancelled { return }
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .keys(let downX, let downTime, let started, let h, let shift, let was, let dup)?:
            var duplicate = dup
            if !started {
                guard abs(p.x - downX) >= Self.dragThreshold else { return }
                model.beginGesture()
                KeyframeCursor.cursor(overGrip: true, dragging: true).set()
                setHover(.none)
                duplicate = event.modifierFlags.contains(.option)      // Option-drag leaves copies behind
                drag = .keys(downX: downX, downTime: downTime, started: true, hit: h, shift: shift, wasSelected: was, duplicate: duplicate)
            }
            let now = geometry.unclampedTime(at: p.x, frameDuration: model.frameDuration)
            var delta = now - downTime
            if event.modifierFlags.contains(.shift) {                 // Shift snaps to the playhead and other keys
                delta = model.snappedMoveDelta(delta, thresholdSeconds: Double(KeyframeSnap.thresholdPoints) / max(geometry.pointsPerSecond, 1e-6))
            }
            model.moveSelection(by: delta, duplicate: duplicate)
        case .marquee(let origin, let base, let shift)?:
            let r = NSRect(x: min(origin.x, p.x), y: min(origin.y, p.y), width: abs(p.x - origin.x), height: abs(p.y - origin.y))
            marquee = r
            applyMarquee(r, base: base, shift: shift)
            needsDisplay = true
        case nil: break
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if escapeCancelled { escapeCancelled = false; return }
        defer {
            drag = nil; marquee = nil; needsDisplay = true
            let h = hit(at: convert(event.locationInWindow, from: nil))
            setHover(h)
            KeyframeCursor.cursor(overGrip: h != .none, dragging: false).set()
        }
        guard case .keys(_, _, let started, let h, let shift, let was, _)? = drag else { return }
        if started { model.endKeyMove() }       // one undo step; the moved keys are deselected
        else if was && !shift { select(h, extend: false) }   // plain click on a selected key collapses the selection to it
    }

    private func applyMarquee(_ r: NSRect, base: Set<SummaryMember>, shift: Bool) {
        model.select(Array((shift ? base : []).union(marqueeMembers(r))), extend: false)
    }

    var marqueeForTests: CGRect? { marquee }

    /// A marquee that started in another view over the lanes (the curve of an opened row) and reaches into them:
    /// `rect` in `view`'s coordinates, nil when it ends. Draws it here too and returns the lane keys inside; the
    /// caller owns the selection.
    func externalMarquee(_ rect: CGRect?, from view: NSView) -> Set<SummaryMember> {
        guard let rect else {
            if marquee != nil { marquee = nil; needsDisplay = true }
            return []
        }
        let r = convert(rect, from: view)
        marquee = r; needsDisplay = true
        return marqueeMembers(r)
    }

    /// The keys a marquee covers: every key of the rows it touches whose time lies under it.
    private func marqueeMembers(_ r: NSRect) -> Set<SummaryMember> {
        var props = Set<EffectProperty>()
        var groupSummaries: [SummaryKey] = []
        for row in rows where row.y < r.maxY && row.y + row.height > r.minY {
            switch row.kind {
            case .property(let p): props.insert(p)
            case .maskControls(let id): props.insert(.maskPath(id))
            case .section(let s) where model.collapsedSections.contains(s): props.formUnion(s.keyProperties)
            case .colorGroup(let id, let key): groupSummaries += model.colorGroupSummaryKeys(id, key)   // closed groups only
            default: break
            }
        }
        let geo = geometry, fd = model.frameDuration
        let half = Time(fd.value, fd.timescale * 2)
        let lo = geo.time(at: r.minX, frameDuration: fd) - half
        let hi = geo.time(at: r.maxX, frameDuration: fd) + half
        var hit = model.keys(in: lo ... hi, properties: props)
        for k in groupSummaries where k.time >= lo && k.time <= hi { hit.formUnion(k.members) }
        return hit
    }

    // MARK: Zoom

    public override func magnify(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        model.zoom(by: KeyframeZoomInput.magnifyFactor(event.magnification), around: geometry.seconds(atX: x))
    }

    public override func scrollWheel(with event: NSEvent) {
        switch KeyframeZoomInput.scroll(event) {
        case .zoom(let f): model.zoom(by: f, around: geometry.seconds(atX: convert(event.locationInWindow, from: nil).x))
        case .pan(let pts): model.panViewport(bySeconds: -Double(pts) / max(geometry.pointsPerSecond, 1e-6))
        case .none: super.scrollWheel(with: event)
        }
    }

    /// Escape during a key drag: the keys go back to where they were (relative to the drag start), the rest of the drag is ignored.
    private var escapeCancelled = false

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, case .keys(_, _, true, _, _, _, _)? = drag {
            _ = model.moveSelection(by: .zero)
            model.endKeyMove()
            drag = nil; marquee = nil; escapeCancelled = true
            needsDisplay = true
            return
        }
        if KeyframeZoomInput.key(event, model: model) { return }
        switch event.keyCode {
        case 51, 117: model.deleteSelectionOrEffect()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Right-click menu (Premiere: temporal interpolation, copy, paste, delete)

    public override func rightMouseDown(with event: NSEvent) {
        let h = hit(at: convert(event.locationInWindow, from: nil))
        if h != .none, !isSelected(h) { select(h, extend: false) }
        if h != .none, case .key(let p, _, _) = h { model.focusedProperty = p }
        SQContextMenu.show(items: makeKeyItems(onKey: h != .none), for: event, in: self)
    }

    /// Entries only for what exists: on a key the six interpolations, saved curves, Copy, Paste, Delete; on empty
    /// space only Paste when something is on the clipboard.
    public func makeKeyItems(onKey: Bool) -> [SQMenuItem] {
        let has = !model.selection.isEmpty
        var items: [SQMenuItem] = []
        if onKey && has {
            // Hold Ahead only where every selected key can store it (not on Animation In/Out rows).
            let ahead: [KeyInterpolationChoice] = model.selectionTakesHoldAhead ? [.holdAhead] : []
            // Board order and wording; Bezier, Auto Bezier and Continuous Bezier are reached through "Custom\u{2026}".
            for choice in [KeyInterpolationChoice.linear, .easyEase, .easeIn, .easeOut, .hold] + ahead {
                items.append(SQMenuItem(title: choice.title) { [weak self] in
                    self?.model.applyInterpolation(choice)
                })
            }
            items.append(SQMenuItem(title: EaseName.customMenu) { [weak self] in self?.model.revealCustomCurve() })
            // The full Premiere set under its own heading (Linear, Bezier, Auto / Continuous Bezier, Hold, Ease In / Out) and our Hold Ahead under Hold.
            let temporal = ([KeyInterpolationChoice.linear, .bezier, .autoBezier, .continuousBezier, .hold] + ahead + [.easeIn, .easeOut]).map { choice in
                SQMenuItem(title: choice.fullTitle) { [weak self] in self?.model.applyInterpolation(choice) }
            }
            items.append(SQMenuItem(title: "Temporal Interpolation", submenu: temporal))
            if model.hasSelectedVectorKey {
                let spatial = EffectControlsModel.SpatialChoice.allCases.map { choice in
                    SQMenuItem(title: choice.title) { [weak self] in self?.model.applySpatialInterpolation(choice) }
                }
                items.append(SQMenuItem(title: "Spatial Interpolation", submenu: spatial))
            }
            items.append(.separator)
            items.append(SQMenuItem(title: "Keyframe Velocity\u{2026}") { [weak self] in self?.runVelocityDialog() })
            items.append(SQMenuItem(title: "Scale Time\u{2026}") { [weak self] in
                guard let self, let r = KeyToolsDialogs.runScaleTime() else { return }
                self.model.scaleSelectionTime(by: r.num, over: r.den)
            })
            if model.hasSelectedVectorKey {
                items.append(SQMenuItem(title: "Rove") { [weak self] in self?.model.roveSelectedKeys() })
            }
            items.append(SQMenuItem(title: "Loop\u{2026}") { [weak self] in
                guard let self, let n = KeyToolsDialogs.runLoop() else { return }
                self.model.loopSelectedTracks(cycles: n)
            })
            items.append(SQMenuItem(title: "Convert to Keys") { [weak self] in self?.model.bakeSelectedKeys(samplesPerSecond: 30) })
            if model.hasSelectedScalarKey {
                items.append(SQMenuItem(title: "Wiggle\u{2026}") { [weak self] in
                    guard let self, let r = KeyToolsDialogs.runWiggle() else { return }
                    self.model.wiggleSelectedKeys(perSecond: r.perSecond, amount: r.amount, seed: r.seed)
                })
            }
            items.append(.separator)
            var presets: [SQMenuItem] = []
            for c in [EasingCurve.fastStart, .fastEnd, .premiereDefault, .easeOut100, .easeIn100] + model.easingLibrary.userCurves {
                presets.append(SQMenuItem(title: EasingMenuSpec.title(of: c)) { [weak self] in
                    self?.model.applyEasing(c, side: .both)
                })
            }
            presets.append(.separator)
            presets.append(SQMenuItem(title: "Save as preset\u{2026}") { [weak self] in
                guard let self, let name = self.namePrompt("Curve")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
                self.model.saveCurveFromSelection(name: name)
            })
            items.append(SQMenuItem(title: "Presets", submenu: presets))
            items.append(.separator)
            items.append(SQMenuItem(title: "Copy", shortcut: "\u{2318}C") { [weak self] in self?.model.copyKeys() })
        }
        if model.canPasteKeys {
            items.append(SQMenuItem(title: "Paste", shortcut: "\u{2318}V") { [weak self] in self?.model.pasteKeys() })
        }
        if onKey && has {
            items.append(.separator)
            items.append(SQMenuItem(title: "Delete", shortcut: "\u{232B}") { [weak self] in self?.model.deleteSelection() })
        }
        return items
    }

    private func runVelocityDialog() {
        guard let m = model.selection.first else { return }
        let inc = model.graphVelocity(of: m, side: .incoming)
        let out = model.graphVelocity(of: m, side: .outgoing)
        guard let unit = (out ?? inc)?.unit,
              let r = KeyToolsDialogs.runVelocity(incoming: inc.map { ($0.speed, $0.influence) },
                                                  outgoing: out.map { ($0.speed, $0.influence) }, unit: unit) else { return }
        if let i = r.incoming { model.setGraphVelocity(speed: i.speed, influence: i.influence, side: .incoming) }
        if let o = r.outgoing { model.setGraphVelocity(speed: o.speed, influence: o.influence, side: .outgoing) }
    }

    @MainActor private static func runNameAlert(_ suggestion: String) -> String? {
        let alert = SQDialog()
        alert.messageText = "Save Curve"
        alert.informativeText = "Name for the new easing preset."
        let field = SQDialog.makeField(width: 240)
        field.stringValue = suggestion
        alert.accessoryView = field
        alert.addButton("Save")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        return alert.runModal() == .first ? field.stringValue : nil
    }
}

/// The one cursor rule for keyframes and curve handles (lanes, inline graphs, Graph Editor, easing popover;
/// INTERACTION-AUDIT §7): always the normal arrow (the maintainer: no hand over keys or handles, not even while dragging).
enum KeyframeCursor {
    static func cursor(overGrip: Bool, dragging: Bool) -> NSCursor {
        .arrow
    }
}
