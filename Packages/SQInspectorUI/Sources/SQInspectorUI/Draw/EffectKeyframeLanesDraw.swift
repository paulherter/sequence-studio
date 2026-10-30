import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The keyframe lanes of Effect Controls on the shared toolkit: `EffectKeyframeLanesView` translated. Hit testing,
/// selection, the key drag (one undo step, Option leaves copies, Shift snaps), the marquee, zoom / pan and the key menu
/// are the Mac code paths on the same model calls; only drawing and event glue are new. Coordinates: lane points,
/// y down, (0, 0) = the lanes' top-left; rows are placed at `row.y - scrollY` like the rows column beside them.
@MainActor public final class EffectKeyframeLanesDraw {
    public let model: EffectControlsModel
    public var theme = DrawTheme()
    public var rows: [EffectRow] = []
    public var size: CGSize = .zero
    /// The rows column's scroll offset (the lanes scroll with it).
    public var scrollY: CGFloat = 0
    /// Where the rows column's content ends; the "No keyframes" hint starts below it.
    public var contentBottom: CGFloat = 0
    /// The key menu (right click): items and anchor in lane points; the host shows them with its one menu system.
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// A key tool's dialog (Scale Time, Loop, Wiggle, Velocity, Save Curve): the host shows `prompt` and reports the typed
    /// texts in field order, nil when canceled. nil hook = the menu leaves those tools out.
    public var onPrompt: (@MainActor (_ prompt: KeyToolPrompt, _ done: @escaping @MainActor ([String]?) -> Void) -> Void)?

    static let hitRadius: CGFloat = EffectKeyframeLanesGeometry.hitRadius
    private static let dragThreshold: CGFloat = 3

    public enum Hit: Equatable, Sendable {
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
    public private(set) var marquee: CGRect?
    private var hoverHit: Hit = .none
    private var escapeCancelled = false

    public init(model: EffectControlsModel) { self.model = model }

    var geometry: KeyframeLaneGeometry { model.laneGeometry(width: size.width) }
    private func contentY(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y + scrollY) }

    // MARK: Drawing (EffectKeyframeLanesView.draw + buildCache)

    public func draw(_ c: inout Canvas) {
        let t = theme, bounds = CGRect(origin: .zero, size: size)
        c.saveGState()
        c.clip(to: bounds)
        c.fill(bounds, t.lane)                                          // v9 `.kg > .r`
        let geo = geometry, slack = Self.hitRadius * 2
        func inView(_ x: CGFloat) -> Bool { x >= -slack && x <= size.width + slack }
        var plain: [(KeyShape, CGPoint, CGFloat)] = [], selected = plain, tracked = plain, trackedSelected = plain
        for row in rows {
            let top = row.y - scrollY
            guard top + row.height > 0, top < size.height else { continue }
            c.fill(CGRect(x: 0, y: top + row.height - 1, width: size.width, height: 1), t.trackRowLine)   // one 1 pt line per row
            let cy = top + row.height / 2, side = ControlsMetrics.keySide
            switch row.kind {
            case .property(let p):
                let sel = model.selectedKeyIDs(p)
                for k in model.track(p)?.glyphs ?? [] {
                    let x = geo.x(for: k.time)
                    guard inView(x) else { continue }
                    if sel.contains(k.id) { selected.append((k.glyph.shape, CGPoint(x: x, y: cy), side)) }
                    else { plain.append((k.glyph.shape, CGPoint(x: x, y: cy), side)) }
                }
            case .section(let s):
                guard showsSectionSummary(s) else { continue }
                for key in model.summaryKeys(s) { addSummary(key, cy, geo, &plain, &selected) }
            case .colorGroup(let id, let key):
                guard showsGroupSummary(id, key) else { continue }
                for k in model.colorGroupSummaryKeys(id, key) { addSummary(k, cy, geo, &plain, &selected) }
            case .maskControls(let id):
                let p = EffectProperty.maskPath(id), sel = model.selectedKeyIDs(p)
                for k in model.track(p)?.glyphs ?? [] {
                    let x = geo.x(for: k.time)
                    guard inView(x) else { continue }
                    if sel.contains(k.id) { selected.append((k.glyph.shape, CGPoint(x: x, y: cy), side)) }
                    else { plain.append((k.glyph.shape, CGPoint(x: x, y: cy), side)) }
                }
                for k in model.magicKeys(id) {
                    let x = geo.x(for: k.time)
                    guard inView(x) else { continue }
                    let at = CGPoint(x: x, y: cy), on = sel.contains(k.id)
                    if k.isCorrection { if on { selected.append((.diamond, at, side)) } else { plain.append((.diamond, at, side)) } }
                    else if on { trackedSelected.append((.diamond, at, side * ControlsMetrics.trackedKeyScale)) }
                    else { tracked.append((.diamond, at, side * ControlsMetrics.trackedKeyScale)) }
                }
            default: break
            }
        }
        if let hc = hoverCenter {
            let r = Self.hitRadius + 2
            c.fill(roundedRect: CGRect(x: hc.x - r, y: hc.y - r, width: 2 * r, height: 2 * r), radius: CGFloat(DrawTheme.Radius.small), t.fillHover)
        }
        // v9 `.dm`: every key sits on a 1.5 pt ring of the lane color, so neighbors stay apart.
        for (shape, at, side) in plain + selected { Self.glyph(&c, shape, at: at, side: side, grow: ControlsMetrics.keyRing, t.lane) }
        for (shape, at, side) in tracked { Self.glyph(&c, shape, at: at, side: side, grow: 0, t.keyframeTracked) }
        for (shape, at, side) in plain { Self.glyph(&c, shape, at: at, side: side, grow: 0, t.keyframe) }
        for (shape, at, side) in selected + trackedSelected { Self.glyph(&c, shape, at: at, side: side, grow: 0, t.accent) }
        if let m = marquee {
            let r = m.offsetBy(dx: 0, dy: -scrollY)
            c.fill(r, t.accentTint)
            let e = r.insetBy(dx: 0.5, dy: 0.5)
            c.stroke(polygon: [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.maxX, y: e.maxY),
                               CGPoint(x: e.minX, y: e.maxY)], width: 1, t.accent)
        }
        drawEmptyHint(&c)
        if model.playheadInClip {           // v9 `.kph`: 2 pt
            c.fill(CGRect(x: geo.x(for: model.localPlayhead).rounded() - 1, y: 0, width: 2, height: size.height), t.playhead)
        }
        c.restoreGState()
    }

    /// `KeyGlyphPath.add`: diamond = steady, circle = eased, square = hold, pointed square = hold ahead; `grow` widens
    /// the glyph on every side (the lane-colored ring under a key).
    /// shortcut: the diamond's 1.5 pt corner rounding is not drawn (the canvas fills straight polygons); upgrade with a
    /// rounded-polygon primitive.
    static func glyph(_ c: inout Canvas, _ shape: KeyShape, at p: CGPoint, side: CGFloat, grow: CGFloat, _ color: DrawColor) {
        switch shape {
        case .diamond: c.fill(polygon: InspectorDraw.diamond(p, size: side * 2.0.squareRoot() + 2 * grow * 2.0.squareRoot()), color)
        case .circle:
            let d = side + 1 + 2 * grow        // v9 `.dm.k-e`: 10 pt beside the 9 pt diamond
            c.fill(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d), color)
        case .ahead: c.fill(polygon: KeyShape.ahead.corners(at: p, size: (side + 2 * grow) / 0.82), color)
        case .square:
            let s = side + 2 * grow
            c.fill(roundedRect: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s), radius: 1 + grow, color)
        }
    }

    private func addSummary(_ key: SummaryKey, _ cy: CGFloat, _ geo: KeyframeLaneGeometry,
                            _ plain: inout [(KeyShape, CGPoint, CGFloat)], _ selected: inout [(KeyShape, CGPoint, CGFloat)]) {
        let x = geo.x(for: key.time)
        guard x >= -Self.hitRadius * 2, x <= size.width + Self.hitRadius * 2 else { return }
        let g = (EffectKeyframeLanesGeometry.summaryGlyph(key, model: model).shape, CGPoint(x: x, y: cy), ControlsMetrics.keySide)
        if model.isSelected(key) { selected.append(g) } else { plain.append(g) }
    }

    /// "No keyframes" under the rows while the clip has no key (INTERACTION-AUDIT §10, `EmptyStateView`).
    private func drawEmptyHint(_ c: inout Canvas) {
        let top = max(rows.last.map { $0.y + $0.height } ?? 0, contentBottom) - scrollY
        let h = size.height - top
        guard EffectKeyframeLanesGeometry.showsNoKeysHint(model), h >= 48 else { return }
        let midY = top + h / 2, t = theme
        c.draw(SQL10n.string("No keyframes"), in: CGRect(x: 8, y: midY - 18, width: max(size.width - 16, 0), height: 16),
               fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2, align: .center)
        c.draw(SQL10n.string("Click a property's diamond to animate it"), in: CGRect(x: 8, y: midY + 2, width: max(size.width - 16, 0), height: 14),
               fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label3, align: .center)
    }

    /// A section or group row carries summary keys only while it is collapsed (a key never shows twice).
    func showsSectionSummary(_ s: EffectSection) -> Bool { model.collapsedSections.contains(s) }
    func showsGroupSummary(_ id: ClipEffect.ID, _ key: String) -> Bool {
        !model.openColorGroups.contains(EffectControlsModel.colorGroupID(id, key))
    }

    // MARK: Hit testing (EffectKeyframeLanesView.hit)

    /// What lies under `p` (lane points).
    public func hit(at p0: CGPoint) -> Hit {
        let p = contentY(p0)
        guard let row = EffectControlsLayout.row(at: p.y, in: rows) else { return .none }
        let geo = geometry, start = model.clip?.start ?? .zero
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

    /// Center of the hovered glyph in lane points (nil = nothing hovered).
    var hoverCenter: CGPoint? {
        let row: EffectRow?, time: Time
        switch hoverHit {
        case .key(let p, _, let t): row = rows.first { EffectKeyframeLanesGeometry.row($0, shows: p) }; time = t
        case .summary(let s, let t): row = rows.first { if case .section(s) = $0.kind { true } else { false } }; time = t
        case .groupSummary(let id, let key, let t): row = rows.first { if case .colorGroup(id, key) = $0.kind { true } else { false } }; time = t
        case .none: return nil
        }
        guard let row else { return nil }
        return CGPoint(x: geometry.x(for: time), y: row.y - scrollY + row.height / 2)
    }

    /// The hovered key's shape name (Linear, Eased, Hold, Hold Ahead): the tooltip.
    public func help(at p: CGPoint) -> String? {
        guard case .key(let prop, let id, _) = hit(at: p), let g = model.track(prop)?.glyphs.first(where: { $0.id == id }) else { return nil }
        return g.glyph.shape.title
    }

    // MARK: Mouse (EffectKeyframeLanesView.mouseDown / Dragged / Up)

    public func mouseMoved(to p: CGPoint?) {
        guard drag == nil else { return }
        hoverHit = p.map { hit(at: $0) } ?? .none
    }

    public func mouseDown(at p0: CGPoint, modifiers: InputModifiers) {
        escapeCancelled = false
        if modifiers.contains(.secondary) { contextMenu(at: p0); return }
        let p = contentY(p0), shift = modifiers.contains(.shift)
        let h = hit(at: p0)
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

    public func mouseDragged(to p0: CGPoint, modifiers: InputModifiers) {
        if escapeCancelled { return }
        let p = contentY(p0)
        switch drag {
        case .keys(let downX, let downTime, let started, let h, let shift, let was, let dup)?:
            var duplicate = dup
            if !started {
                guard abs(p.x - downX) >= Self.dragThreshold else { return }
                model.beginGesture()
                hoverHit = .none
                duplicate = modifiers.contains(.option)      // Option-drag leaves copies behind
                drag = .keys(downX: downX, downTime: downTime, started: true, hit: h, shift: shift, wasSelected: was, duplicate: duplicate)
            }
            let now = geometry.unclampedTime(at: p.x, frameDuration: model.frameDuration)
            var delta = now - downTime
            if modifiers.contains(.shift) {                 // Shift snaps to the playhead and other keys
                delta = model.snappedMoveDelta(delta, thresholdSeconds: Double(KeyframeSnap.thresholdPoints) / max(geometry.pointsPerSecond, 1e-6))
            }
            model.moveSelection(by: delta, duplicate: duplicate)
        case .marquee(let origin, let base, let shift)?:
            let r = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y), width: abs(p.x - origin.x), height: abs(p.y - origin.y))
            marquee = r
            model.select(Array((shift ? base : []).union(marqueeMembers(r))), extend: false)
        case nil: break
        }
    }

    public func mouseUp(at p: CGPoint) {
        if escapeCancelled { escapeCancelled = false; return }
        defer { drag = nil; marquee = nil; hoverHit = hit(at: p) }
        guard case .keys(_, _, let started, let h, let shift, let was, _)? = drag else { return }
        if started { model.endKeyMove() }       // one undo step; the moved keys are deselected
        else if was && !shift { select(h, extend: false) }   // plain click on a selected key collapses the selection to it
    }

    public var isDragging: Bool { drag != nil }

    /// A marquee that started in an opened row's curve and reaches into the lanes (`externalMarquee` of the Mac view):
    /// `rect` in content coordinates, nil when it ends. Draws it here too and returns the lane keys inside; the caller
    /// owns the selection.
    public func externalMarquee(_ rect: CGRect?) -> Set<SummaryMember> {
        guard let rect else { marquee = nil; return [] }
        marquee = rect
        return marqueeMembers(rect)
    }

    /// The keys a marquee (content coordinates) covers: every key of the rows it touches whose time lies under it.
    private func marqueeMembers(_ r: CGRect) -> Set<SummaryMember> {
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

    // MARK: Wheel and keys

    /// Horizontal wheel pans, Option / Ctrl + vertical zooms around the pointer; plain vertical is left to the rows.
    public func scroll(at p: CGPoint, dx: CGFloat, dy: CGFloat, modifiers: InputModifiers) -> Bool {
        switch KeyframeZoomInput.classify(dx: dx, dy: dy, modifiers: modifiers) {
        case .zoom(let f): model.zoom(by: f, around: geometry.seconds(atX: p.x)); return true
        case .pan(let pts): model.panViewport(bySeconds: -Double(pts) / max(geometry.pointsPerSecond, 1e-6)); return true
        case .none: return false
        }
    }

    /// Escape during a key drag puts the keys back; + / - / \ zoom; Delete removes the selected keys (or the effect).
    public func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        if k == .escape, case .keys(_, _, true, _, _, _, _)? = drag {
            _ = model.moveSelection(by: .zero)
            model.endKeyMove()
            drag = nil; marquee = nil; escapeCancelled = true
            return true
        }
        if KeyframeZoomInput.key(k, modifiers: modifiers, model: model) { return true }
        switch k {
        case .delete, .backspace: model.deleteSelectionOrEffect(); return true
        default: return false
        }
    }

    // MARK: Right-click menu (Premiere: temporal interpolation, copy, paste, delete)

    public func contextMenu(at p: CGPoint) {
        let h = hit(at: p)
        if h != .none, !isSelected(h) { select(h, extend: false) }
        if case .key(let prop, _, _) = h { model.focusedProperty = prop }
        onMenu?(makeKeyItems(onKey: h != .none), CGRect(x: p.x, y: p.y, width: 0, height: 0))
    }

    /// `EffectKeyframeLanesView.makeKeyItems`: the same entries; the dialogs go through `onPrompt`.
    public func makeKeyItems(onKey: Bool) -> [SQMenuItem] {
        let has = !model.selection.isEmpty
        var items: [SQMenuItem] = []
        let model = model
        if onKey && has {
            let ahead: [KeyInterpolationChoice] = model.selectionTakesHoldAhead ? [.holdAhead] : []
            for choice in [KeyInterpolationChoice.linear, .easyEase, .easeIn, .easeOut, .hold] + ahead {
                items.append(SQMenuItem(title: choice.title) { model.applyInterpolation(choice) })
            }
            items.append(SQMenuItem(title: EaseName.customMenu) { model.revealCustomCurve() })
            let temporal = ([KeyInterpolationChoice.linear, .bezier, .autoBezier, .continuousBezier, .hold] + ahead + [.easeIn, .easeOut]).map { choice in
                SQMenuItem(title: choice.fullTitle) { model.applyInterpolation(choice) }
            }
            items.append(SQMenuItem(title: "Temporal Interpolation", submenu: temporal))
            if model.hasSelectedVectorKey {
                let spatial = EffectControlsModel.SpatialChoice.allCases.map { choice in
                    SQMenuItem(title: choice.title) { model.applySpatialInterpolation(choice) }
                }
                items.append(SQMenuItem(title: "Spatial Interpolation", submenu: spatial))
            }
            items.append(.separator)
            if let ask = onPrompt {
                items.append(SQMenuItem(title: "Keyframe Velocity\u{2026}") { [weak self] in self?.askVelocity(ask) })
                items.append(SQMenuItem(title: "Scale Time\u{2026}") {
                    ask(.scaleTime) { t in if let r = t.flatMap({ KeyToolsInput.timeScaleRatio($0[0]) }) { model.scaleSelectionTime(by: r.num, over: r.den) } }
                })
            }
            if model.hasSelectedVectorKey { items.append(SQMenuItem(title: "Rove") { model.roveSelectedKeys() }) }
            if let ask = onPrompt {
                items.append(SQMenuItem(title: "Loop\u{2026}") {
                    ask(.loop) { t in if let n = t.flatMap({ KeyToolsInput.wholeNumber($0[0], in: 1...100) }) { model.loopSelectedTracks(cycles: n) } }
                })
            }
            items.append(SQMenuItem(title: "Convert to Keys") { model.bakeSelectedKeys(samplesPerSecond: 30) })
            if model.hasSelectedScalarKey, let ask = onPrompt {
                items.append(SQMenuItem(title: "Wiggle\u{2026}") {
                    ask(.wiggle) { t in
                        if let r = t.flatMap({ KeyToolsInput.wiggle(frequency: $0[0], amount: $0[1], seed: $0[2]) }) {
                            model.wiggleSelectedKeys(perSecond: r.perSecond, amount: r.amount, seed: r.seed)
                        }
                    }
                })
            }
            items.append(.separator)
            var presets: [SQMenuItem] = []
            for c in [EasingCurve.fastStart, .fastEnd, .premiereDefault, .easeOut100, .easeIn100] + model.easingLibrary.userCurves {
                presets.append(SQMenuItem(title: EasingMenuSpec.title(of: c)) { model.applyEasing(c, side: .both) })
            }
            if let ask = onPrompt {
                presets.append(.separator)
                presets.append(SQMenuItem(title: "Save as preset\u{2026}") {
                    ask(.saveCurve) { t in
                        guard let name = t?.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
                        model.saveCurveFromSelection(name: name)
                    }
                })
            }
            items.append(SQMenuItem(title: "Presets", submenu: presets))
            items.append(.separator)
            items.append(SQMenuItem(title: "Copy", shortcut: "\u{2318}C") { _ = model.copyKeys() })
        }
        if model.canPasteKeys { items.append(SQMenuItem(title: "Paste", shortcut: "\u{2318}V") { _ = model.pasteKeys() }) }
        if onKey && has {
            items.append(.separator)
            items.append(SQMenuItem(title: "Delete", shortcut: "\u{232B}") { model.deleteSelection() })
        }
        return items
    }

    private func askVelocity(_ ask: @escaping @MainActor (KeyToolPrompt, @escaping @MainActor ([String]?) -> Void) -> Void) {
        guard let m = model.selection.first else { return }
        let inc = model.graphVelocity(of: m, side: .incoming), out = model.graphVelocity(of: m, side: .outgoing)
        guard let unit = (out ?? inc)?.unit else { return }
        let model = model
        ask(.velocity(incoming: inc.map { ($0.speed, $0.influence) }, outgoing: out.map { ($0.speed, $0.influence) }, unit: unit)) { t in
            guard let t else { return }
            let r = KeyToolPrompt.velocityAnswer(t, hasIncoming: inc != nil, hasOutgoing: out != nil)
            if let i = r.incoming { model.setGraphVelocity(speed: i.speed, influence: i.influence, side: .incoming) }
            if let o = r.outgoing { model.setGraphVelocity(speed: o.speed, influence: o.influence, side: .outgoing) }
        }
    }
}

/// The keyframe ruler above the lanes on the shared toolkit (`KeyframeRulerView` translated): ticks, short timecode labels,
/// the playhead; a press or drag scrubs the session playhead (Shift snaps to keys), the wheel zooms and pans.
@MainActor public final class KeyframeRulerDraw {
    public let model: EffectControlsModel
    public var theme = DrawTheme()
    public var size: CGSize = .zero
    private var dragging = false
    private var hoverX: CGFloat?

    public init(model: EffectControlsModel) { self.model = model }

    var geometry: KeyframeLaneGeometry { model.laneGeometry(width: size.width) }

    public func draw(_ c: inout Canvas) {
        let t = theme, bounds = CGRect(origin: .zero, size: size), rh = size.height
        c.saveGState()
        c.clip(to: bounds)
        c.fill(bounds, t.lane)
        if let clip = model.clip {
            let geo = geometry, tc = TimecodeFormat(frameDuration: model.frameDuration)
            // v9 `.kruler span`: a caption label with an 8 pt tick at its left, at the bottom of the row; minor ticks 4 pt.
            for tick in KeyframeRulerLayout.ticks(geometry: geo, frameDuration: model.frameDuration, nominalFPS: tc.nominalFPS) {
                let x = geo.x(for: tick.local).rounded()
                if tick.major {
                    c.fill(CGRect(x: x, y: rh - 8, width: 1, height: 8), t.rulerLine)
                    let label = KeyframeRulerLayout.shortLabel(tc.string(for: clip.start + tick.local, frameDuration: model.frameDuration))
                    c.draw(label, in: CGRect(x: x + 4, y: 5, width: 80, height: 13), fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label3)
                } else {
                    c.fill(CGRect(x: x, y: rh - 4, width: 1, height: 4), t.rulerMinor)
                }
            }
            if let hx = hoverX, !dragging { c.fill(CGRect(x: hx.rounded() - 0.5, y: 0, width: 1, height: rh), t.label3) }
            if model.playheadInClip {
                let x = geo.x(for: model.localPlayhead).rounded()
                c.fill(CGRect(x: x - 1, y: 0, width: 2, height: rh), t.playhead)
                // shortcut: a plain pentagon head; the timeline's gradient head (SQDrawTimeline TimelineSkin.drawHead) is not
                // shared yet. Upgrade by moving that head into SQDrawKit.
                c.fill(polygon: [CGPoint(x: x - 6, y: 0), CGPoint(x: x + 6, y: 0), CGPoint(x: x + 6, y: 7), CGPoint(x: x, y: 12),
                                 CGPoint(x: x - 6, y: 7)], t.playhead)
            }
        }
        c.fill(CGRect(x: 0, y: rh - 1, width: size.width, height: 1), t.trackRowLine)
        c.restoreGState()
    }

    private func target(_ p: CGPoint, shift: Bool) -> Time? {
        guard model.clip != nil else { return nil }
        let geo = geometry
        let local = geo.time(at: p.x, frameDuration: model.frameDuration)
        return model.scrubTarget(local: local, snap: shift, thresholdSeconds: Double(KeyframeSnap.thresholdPoints) / max(geo.pointsPerSecond, 1e-6))
    }

    public func mouseMoved(to p: CGPoint?) { hoverX = model.clip == nil ? nil : p?.x }

    public func mouseDown(at p: CGPoint, modifiers: InputModifiers) {
        if dragging { model.scrubUp(); dragging = false }     // a lost mouse-up must not leave the ruler stuck
        if let t = target(p, shift: modifiers.contains(.shift)) { dragging = true; model.scrubDown(to: t) }
    }

    public func mouseDragged(to p: CGPoint, modifiers: InputModifiers) {
        guard dragging, let t = target(p, shift: modifiers.contains(.shift)) else { return }
        model.scrubDrag(to: t)
    }

    public func mouseUp(at p: CGPoint) {
        if dragging { model.scrubUp() }
        dragging = false
    }

    public func scroll(at p: CGPoint, dx: CGFloat, dy: CGFloat, modifiers: InputModifiers) -> Bool {
        switch KeyframeZoomInput.classify(dx: dx, dy: dy, modifiers: modifiers) {
        case .zoom(let f): model.zoom(by: f, around: geometry.seconds(atX: p.x)); return true
        case .pan(let pts): model.panViewport(bySeconds: -Double(pts) / max(geometry.pointsPerSecond, 1e-6)); return true
        case .none: return false
        }
    }
}

/// The lane rules shared by the Mac lanes view and the shared-toolkit lanes.
public enum EffectKeyframeLanesGeometry {
    public static let hitRadius: CGFloat = 6

    /// Summary glyph: per side hold if every member is hold, eased if any member is eased, else linear.
    @MainActor public static func summaryGlyph(_ key: SummaryKey, model: EffectControlsModel) -> KeyGlyph {
        var glyphs: [KeyGlyph] = []
        for m in key.members {
            let t = model.track(EffectProperty(rawValue: m.property.rawValue) ?? .opacity)
            if let g = t?.glyphs.first(where: { $0.id == m.keyID }) { glyphs.append(g.glyph) }
        }
        return KeyGlyph.merged(glyphs)
    }

    /// True while the shown clip has no keyframe on any property or mask path.
    @MainActor public static func showsNoKeysHint(_ model: EffectControlsModel) -> Bool {
        guard let c = model.clip else { return false }
        return !EffectControlsModel.allProperties(in: c).contains { model.isAnimated($0) }
            && !c.masks.contains { $0.source == .magic && !model.magicKeys($0.id).isEmpty }
    }

    /// The row whose lane carries the keys of `p`: its own row, or for a mask's Path the mask's controls row.
    public static func row(_ r: EffectRow, shows p: EffectProperty) -> Bool {
        switch r.kind {
        case .property(let q): q == p
        case .maskControls(let id): p == .maskPath(id)
        default: false
        }
    }
}
