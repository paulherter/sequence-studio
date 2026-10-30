import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The property rows of the Graphics panel on the shared toolkit: the Mac `InspectorSection` / `InspectorRow` /
/// `AppearanceRow` stack that `GraphicsPanelView.rebuild` fills, as a list of rows whose values are read through closures
/// on every draw (the Mac panel's `refreshers`). Sections fold (kept under `sq.inspector.open.graphics.<key>` like the Mac
/// `InspectorSection`), an Appearance row's chevron opens its detail rows. Coordinates: points, y down, (0, 0) = the
/// form's top-left; the panel scrolls it.
@MainActor final class GraphicsFormDraw {
    typealias Getter = () -> Double?
    typealias Setter = (Double) -> Void

    struct IconItem {
        var icon: SQIcon
        var title: String
        var enabled: () -> Bool = { true }
        var selected: () -> Bool = { false }
        var action: () -> Void
    }

    struct TextButton {
        var title: String
        var action: (CGRect) -> Void
    }

    enum Kind {
        /// Section header: chevron, title; an effect section has the enable eye and a remove button.
        case section(title: String, key: String, enabled: (() -> Bool)?, setEnabled: ((Bool) -> Void)?, remove: (() -> Void)?)
        /// One to two ScrubFields; `keyed` tints them while the property has keys; `link` is the Scale link button.
        case numbers(title: String, keyed: (() -> Bool)?, link: IconItem?)
        case popup(title: String, titles: [String], selected: () -> Int?, enabled: () -> Bool, choose: (Int) -> Void)
        case segments(title: String, labels: [String], selected: () -> Int, enabled: (Int) -> Bool, choose: (Int) -> Void)
        case icons(title: String?, [IconItem])
        case check(title: String, state: () -> InspectorDraw.CheckState, toggle: () -> Void)
        case color(title: String, get: () -> EffectColor?, set: (EffectColor) -> Void)
        /// Check, swatch and the main value (field 0) inline; detail rows (`detailOf` = key) open under the chevron.
        case appearance(title: String, key: String, on: () -> Bool?, setOn: (Bool) -> Void, color: () -> EffectColor?,
                        setColor: (EffectColor) -> Void, hasDetail: Bool)
        case label(title: String, value: String)
        case buttons([TextButton])
    }

    final class Row {
        let kind: Kind
        /// Appearance key of the row this one details (shown while that row is open).
        var detailOf: String?
        /// The section key this row belongs to (hidden while it is folded).
        var section: String?
        var fields: [ScrubFieldControl] = []
        var getters: [Getter] = []
        var setters: [Setter] = []
        init(_ kind: Kind) { self.kind = kind }
    }

    var theme = DrawTheme()
    var width: CGFloat = 300
    var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    var onPickColor: (@MainActor (_ current: EffectColor, _ anchor: CGRect,
                                  _ change: @escaping @MainActor (EffectColor?) -> Void) -> Void)?
    /// A gesture opens (drag, typed value, picker session, popup choice): one undo step (`GraphicsEditor.beginGesture`).
    var onBeginGesture: (() -> Void)?
    /// Something the rows depend on changed shape (a fold, a detail opened): the host re-lays out.
    var onHeightChange: (() -> Void)?

    private(set) var rows: [Row] = []
    private var currentSection: String?
    private(set) var openDetails: Set<String> = []
    private let defaults = UserDefaults.standard

    static let rowHeight = ControlsGrid.rowHeight
    static let fieldWidth: CGFloat = 64
    static let iconSlot: CGFloat = 22
    static let swatch = CGSize(width: 32, height: 18)

    // MARK: Building (GraphicsPanelView begin / add / numberRow)

    func reset() {
        resignFocus()
        rows = []
        currentSection = nil
        hover = nil; pressed = nil
    }

    func begin(_ title: String, key: String, enabled: (() -> Bool)? = nil, setEnabled: ((Bool) -> Void)? = nil,
               remove: (() -> Void)? = nil) {
        currentSection = nil
        add(.section(title: title, key: key, enabled: enabled, setEnabled: setEnabled, remove: remove))
        currentSection = key
    }

    @discardableResult
    func add(_ kind: Kind, detailOf: String? = nil) -> Row {
        let r = Row(kind)
        r.section = currentSection
        r.detailOf = detailOf
        rows.append(r)
        return r
    }

    /// A row of ScrubFields (drag, click to type, arrows step, double-click resets to `reset`), each read and written
    /// through its closure pair.
    @discardableResult
    func numbers(_ title: String, unit: String, keyed: (() -> Bool)? = nil, decimals: Int = 1, reset: [Double]? = nil,
                 range: ClosedRange<Double>? = nil, fields: [(get: Getter, set: Setter)], link: IconItem? = nil,
                 detailOf: String? = nil) -> Row {
        let r = add(.numbers(title: title, keyed: keyed, link: link), detailOf: detailOf)
        attach(r, unit: unit, decimals: decimals, reset: reset, range: range, fields: fields)
        return r
    }

    /// The Appearance row with its main value as field 0.
    @discardableResult
    func appearance(_ title: String, key: String, on: @escaping () -> Bool?, setOn: @escaping (Bool) -> Void,
                    color: @escaping () -> EffectColor?, setColor: @escaping (EffectColor) -> Void, value: @escaping Getter,
                    setValue: @escaping Setter, unit: String, reset: Double, hasDetail: Bool) -> Row {
        let r = add(.appearance(title: title, key: key, on: on, setOn: setOn, color: color, setColor: setColor, hasDetail: hasDetail))
        attach(r, unit: unit, decimals: 0, reset: [reset], range: nil, fields: [(value, setValue)])
        return r
    }

    private func attach(_ r: Row, unit: String, decimals: Int, reset: [Double]?, range: ClosedRange<Double>?,
                        fields: [(get: Getter, set: Setter)]) {
        for (i, f) in fields.enumerated() {
            var s = ScrubFieldControl(value: f.get() ?? 0)
            s.isPlain = true
            s.decimals = decimals
            s.step = decimals >= 2 ? 0.01 : 1
            s.unit = unit
            if let range { s.range = range }
            if let reset, i < reset.count { s.defaultValue = reset[i] }
            r.fields.append(s)
            r.getters.append(f.get)
            r.setters.append(f.set)
        }
    }

    // MARK: Layout

    func isFolded(_ key: String) -> Bool { defaults.object(forKey: "sq.inspector.open.graphics.\(key)") as? Bool == false }

    func setFolded(_ key: String, _ folded: Bool) {
        defaults.set(!folded, forKey: "sq.inspector.open.graphics.\(key)")
        resignFocus()
        onHeightChange?()
    }

    /// The rows on screen in order (folded sections and closed details left out) with their y.
    var visible: [(row: Row, y: CGFloat)] {
        var out: [(Row, CGFloat)] = [], y: CGFloat = 0
        for r in rows {
            if let s = r.section, isFolded(s) { continue }
            if let d = r.detailOf, !openDetails.contains(d) { continue }
            out.append((r, y))
            y += Self.rowHeight
        }
        return out
    }

    var height: CGFloat { CGFloat(visible.count) * Self.rowHeight }

    enum Part: Equatable {
        case fold, enable, remove, field(Int), link, popup, segment(Int), icon(Int), check, well, appCheck, appWell, chevron, button(Int)
    }

    struct Hit: Equatable { var row: Int; var part: Part }

    private func index(of r: Row) -> Int { rows.firstIndex { $0 === r } ?? -1 }

    private func controlY(_ y: CGFloat, _ h: CGFloat = ControlsGrid.controlHeight) -> CGFloat { y + ((Self.rowHeight - h) / 2).rounded() }

    /// The frame of a part in the row at `y` (form coordinates).
    func frame(_ part: Part, of r: Row, y: CGFloat) -> CGRect? {
        let h = Self.rowHeight, ch = ControlsGrid.controlHeight, vx = ControlsGrid.valueX
        let gap = CGFloat(DrawTheme.Spacing.xs)
        let right = max(width - ControlsGrid.trailing, vx)
        switch (r.kind, part) {
        case (.section, .fold): return CGRect(x: 0, y: y, width: width, height: h)
        case (.section(_, _, let en, _, _), .enable) where en != nil:
            return CGRect(x: right - Self.iconSlot * 2 - gap, y: y, width: Self.iconSlot, height: h)
        case (.section(_, _, _, _, let rm), .remove) where rm != nil:
            return CGRect(x: right - Self.iconSlot, y: y, width: Self.iconSlot, height: h)
        case (.numbers, .field(let i)), (.appearance, .field(let i)):
            guard r.fields.indices.contains(i) else { return nil }
            var x = vx + CGFloat(i) * (Self.fieldWidth + gap)
            if case .appearance = r.kind { x = vx + Self.swatch.width + gap }
            return CGRect(x: x, y: controlY(y), width: Self.fieldWidth, height: ch)
        case (.numbers(_, _, let link), .link) where link != nil:
            let x = vx + CGFloat(r.fields.count) * (Self.fieldWidth + gap)
            return CGRect(x: x, y: y, width: Self.iconSlot, height: h)
        case (.popup, .popup):
            return CGRect(x: vx, y: controlY(y), width: min(128, right - vx), height: ch)
        case (.segments(_, let labels, _, _, _), .segment(let i)) where labels.indices.contains(i):
            return CGRect(x: vx + CGFloat(i) * 64, y: controlY(y), width: 64, height: ch)
        case (.icons(_, let items), .icon(let i)) where items.indices.contains(i):
            return CGRect(x: iconsX(r) + CGFloat(i) * (Self.iconSlot + gap), y: controlY(y, Self.iconSlot), width: Self.iconSlot,
                          height: Self.iconSlot)
        case (.check, .check): return CGRect(x: vx, y: y, width: max(right - vx, 0), height: h)
        case (.color, .well): return CGRect(origin: CGPoint(x: vx, y: controlY(y, Self.swatch.height)), size: Self.swatch)
        case (.appearance, .appCheck): return CGRect(x: ControlsGrid.toggleX, y: y, width: ControlsGrid.toggleWidth, height: h)
        case (.appearance, .appWell): return CGRect(origin: CGPoint(x: vx, y: controlY(y, Self.swatch.height)), size: Self.swatch)
        case (.appearance(_, _, _, _, _, _, let detail), .chevron) where detail:
            return CGRect(x: right - Self.iconSlot, y: y, width: Self.iconSlot, height: h)
        case (.buttons(let bs), .button(let i)) where bs.indices.contains(i):
            var x = ControlsGrid.toggleX
            for k in 0..<i { x += buttonWidth(bs[k].title) + gap }
            return CGRect(x: x, y: controlY(y), width: buttonWidth(bs[i].title), height: ch)
        default: return nil
        }
    }

    /// The icon strip starts in the value column when the row has a title, else at the toggle column (Arrange).
    private func iconsX(_ r: Row) -> CGFloat {
        if case .icons(let title, _) = r.kind, title != nil { return ControlsGrid.valueX }
        return ControlsGrid.toggleX
    }

    private var measure: ((String) -> CGFloat)?
    private func buttonWidth(_ title: String) -> CGFloat {
        (measure?(SQL10n.string(title)) ?? CGFloat(title.count) * 6.5) + 20
    }

    private func parts(_ r: Row) -> [Part] {
        switch r.kind {
        case .section: [.enable, .remove, .fold]
        case .numbers: r.fields.indices.map { .field($0) } + [.link]
        case .popup: [.popup]
        case .segments(_, let l, _, _, _): l.indices.map { .segment($0) }
        case .icons(_, let items): items.indices.map { .icon($0) }
        case .check: [.check]
        case .color: [.well]
        case .appearance: [.appCheck, .appWell, .field(0), .chevron]
        case .label: []
        case .buttons(let bs): bs.indices.map { .button($0) }
        }
    }

    func hit(at p: CGPoint) -> Hit? {
        for (r, y) in visible where p.y >= y && p.y < y + Self.rowHeight {
            for part in parts(r) { if let f = frame(part, of: r, y: y), f.contains(p) { return Hit(row: index(of: r), part: part) } }
            return nil
        }
        return nil
    }

    private func y(of row: Int) -> CGFloat? { visible.first { $0.row === rows[row] }?.y }

    // MARK: Drawing

    func draw(_ c: inout Canvas) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        measure = { [c] s in c.size(of: s, fontSize: fs).width }
        let gap = CGFloat(DrawTheme.Spacing.xs)
        for (r, y) in visible {
            let i = index(of: r), h = Self.rowHeight
            func hov(_ p: Part) -> Bool { hover == Hit(row: i, part: p) }
            func prs(_ p: Part) -> Bool { pressed == Hit(row: i, part: p) }
            refreshFields(r)
            switch r.kind {
            case .section(let title, let key, let enabled, _, let remove):
                if i > 0 { c.fill(CGRect(x: 0, y: y, width: width, height: 1), t.separator) }
                let folded = isFolded(key)
                icon(&c, folded ? .chevronRight : .chevronDown, in: CGRect(x: ControlsGrid.headerToggleX, y: y, width: ControlsGrid.toggleWidth, height: h),
                     size: 9, t.label3)
                let on = enabled?() ?? true
                c.draw(SQL10n.string(title), in: CGRect(x: ControlsGrid.headerLabelX, y: y, width: max(width - ControlsGrid.headerLabelX - 60, 0), height: h),
                       fontSize: fs, on ? t.label : t.label3)
                if enabled != nil, let f = frame(.enable, of: r, y: y) { icon(&c, on ? .eye : .eyeOff, in: f, tint(hov(.enable))) }
                if remove != nil, let f = frame(.remove, of: r, y: y) { icon(&c, .minusCircle, in: f, tint(hov(.remove))) }
            case .numbers(let title, let keyed, let link):
                label(&c, title, y)
                let animated = keyed?() ?? false
                for k in r.fields.indices {
                    guard let f = frame(.field(k), of: r, y: y) else { continue }
                    var fd = r.fields[k]
                    fd.hovering = hov(.field(k))
                    fd.valueTint = animated ? t.keyframe : nil
                    fd.draw(&c, in: f, theme: t, focused: focused == Hit(row: i, part: .field(k)))
                }
                if let link, let f = frame(.link, of: r, y: y) {
                    icon(&c, link.icon, in: f, size: 11, link.selected() ? t.accent : tint(hov(.link)))
                }
            case .popup(let title, let titles, let selected, let enabled, _):
                label(&c, title, y)
                if let f = frame(.popup, of: r, y: y) {
                    let s = selected().flatMap { titles.indices.contains($0) ? titles[$0] : nil } ?? "—"
                    InspectorDraw.popup(&c, title: SQL10n.string(s), in: f, hovering: hov(.popup), open: false, enabled: enabled(), t)
                }
            case .segments(let title, let labels, let selected, let enabled, _):
                label(&c, title, y)
                let sel = selected()
                for (k, l) in labels.enumerated() {
                    guard let f = frame(.segment(k), of: r, y: y) else { continue }
                    let on = k == sel, en = enabled(k)
                    c.fill(roundedRect: f.insetBy(dx: 1, dy: 0), radius: CGFloat(DrawTheme.Radius.small),
                           on ? t.fillPressed : (hov(.segment(k)) && en ? t.fillHover : t.fill))
                    c.draw(SQL10n.string(l), in: f, fontSize: fs, en ? (on ? t.label : t.label2) : t.label3, align: .center)
                }
            case .icons(let title, let items):
                if let title { label(&c, title, y) }
                for (k, it) in items.enumerated() {
                    guard let f = frame(.icon(k), of: r, y: y) else { continue }
                    let en = it.enabled(), sel = it.selected()
                    if sel { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.small), t.accentTint) }
                    else if hov(.icon(k)) && en { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.small), t.fillHover) }
                    icon(&c, it.icon, in: f, size: 12, sel ? t.accent : tint(hov(.icon(k)), enabled: en))
                }
            case .check(let title, let state, _):
                let box = CGRect(x: ControlsGrid.valueX, y: controlY(y, 14), width: 14, height: 14)
                InspectorDraw.checkbox(&c, state(), box: box, hovering: hov(.check), pressed: prs(.check), enabled: true, t)
                c.draw(SQL10n.string(title), in: CGRect(x: box.maxX + 6, y: y, width: max(width - box.maxX - 6 - ControlsGrid.trailing, 0), height: h),
                       fontSize: fs, t.label)
            case .color(let title, let get, _):
                label(&c, title, y)
                if let f = frame(.well, of: r, y: y) { well(&c, get(), f, hov(.well)) }
            case .appearance(let title, let key, let on, _, let color, _, let detail):
                let state = on()
                if let f = frame(.appCheck, of: r, y: y) {
                    let box = CGRect(x: f.midX - 7, y: controlY(y, 14), width: 14, height: 14)
                    InspectorDraw.checkbox(&c, state == nil ? .mixed : (state! ? .on : .off), box: box, hovering: hov(.appCheck),
                                           pressed: prs(.appCheck), enabled: true, t)
                }
                label(&c, title, y)
                if let f = frame(.appWell, of: r, y: y) { well(&c, state == false ? nil : color(), f, hov(.appWell)) }
                if let f = frame(.field(0), of: r, y: y), var fd = r.fields.first {
                    fd.hovering = hov(.field(0))
                    fd.isEnabled = state != false
                    fd.draw(&c, in: f, theme: t, focused: focused == Hit(row: i, part: .field(0)))
                }
                if detail, let f = frame(.chevron, of: r, y: y) {
                    icon(&c, openDetails.contains(key) ? .chevronDown : .chevronRight, in: f, size: 9, tint(hov(.chevron)))
                }
                _ = gap
            case .label(let title, let value):
                label(&c, title, y)
                c.draw(value, in: CGRect(x: ControlsGrid.valueX, y: y, width: max(width - ControlsGrid.valueX - ControlsGrid.trailing, 0), height: h),
                       fontSize: fs, t.label2)
            case .buttons(let bs):
                for (k, b) in bs.enumerated() {
                    guard let f = frame(.button(k), of: r, y: y) else { continue }
                    InspectorDraw.button(&c, title: SQL10n.string(b.title), in: f, hovering: hov(.button(k)), pressed: prs(.button(k)),
                                            enabled: true, t)
                }
            }
        }
    }

    private func refreshFields(_ r: Row) {
        for k in r.fields.indices where !r.fields[k].isEditing && !r.fields[k].isDragging {
            let v = r.getters[k]()
            r.fields[k].isMixed = v == nil
            if let v { r.fields[k].value = v }
        }
    }

    private func label(_ c: inout Canvas, _ s: String, _ y: CGFloat) {
        c.draw(SQL10n.string(s), in: CGRect(x: ControlsGrid.labelX, y: y, width: ControlsGrid.valueX - ControlsGrid.labelX - ControlsGrid.gap,
                                            height: Self.rowHeight), fontSize: CGFloat(DrawTheme.TypeSize.body), theme.label2)
    }

    private func icon(_ c: inout Canvas, _ i: SQIcon, in r: CGRect, size s: CGFloat = 10, _ color: DrawColor) {
        c.draw(icon: i, at: CGPoint(x: (r.midX - s / 2).rounded(), y: (r.midY - s / 2).rounded()), size: s, color)
    }

    private func tint(_ hovered: Bool, enabled: Bool = true) -> DrawColor {
        let base = hovered && enabled ? theme.label : theme.label2
        return enabled ? base : base.alpha(base.a * InspectorTokens.disabledAlpha)
    }

    /// An empty swatch (mixed or off) draws the field fill with a slash.
    private func well(_ c: inout Canvas, _ color: EffectColor?, _ f: CGRect, _ hovering: Bool) {
        if let color {
            InspectorDraw.colorWell(&c, DrawColor(Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha)), in: f,
                                    hovering: hovering, theme)
        } else {
            c.fill(roundedRect: f, radius: InspectorTokens.radius(f), theme.field)
            c.stroke(roundedRect: f, radius: InspectorTokens.radius(f), width: 1, theme.fieldEdge)
            c.strokeLine(from: CGPoint(x: f.minX + 3, y: f.maxY - 3), to: CGPoint(x: f.maxX - 3, y: f.minY + 3), width: 1, theme.label3)
        }
    }

    // MARK: Pointer and keys

    private(set) var hover: Hit?
    private(set) var pressed: Hit?
    private(set) var focused: Hit?
    private var counter = ClickCounter()

    func mouseMoved(to p: CGPoint?) { if pressed == nil { hover = p.flatMap(hit) } }

    func mouseDown(at p: CGPoint, clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        let h = hit(at: p)
        if let f = focused, f != h { resignFocus() }
        pressed = h
        guard let h, case .field(let k) = h.part else { return }
        let r = rows[h.row]
        apply(r.fields[k].mouseDown(x: Float(p.x), clickCount: n), r, k)
        focused = h
    }

    func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        guard let h = pressed, case .field(let k) = h.part else { return }
        let r = rows[h.row]
        apply(r.fields[k].mouseDragged(x: Float(p.x), modifiers: modifiers), r, k)
    }

    func mouseUp(at p: CGPoint) {
        let h = pressed
        pressed = nil
        defer { mouseMoved(to: p) }
        guard let h else { return }
        let r = rows[h.row]
        if case .field(let k) = h.part { apply(r.fields[k].mouseUp(), r, k); return }
        guard hit(at: p) == h, let y = y(of: h.row) else { return }
        let anchor = frame(h.part, of: r, y: y) ?? .zero
        switch (r.kind, h.part) {
        case (.section(_, let key, _, _, _), .fold): setFolded(key, !isFolded(key))
        case (.section(_, _, let en, let set, _), .enable): onBeginGesture?(); set?(!(en?() ?? true))
        case (.section(_, _, _, _, let remove), .remove): remove?()
        case (.numbers(_, _, let link), .link): link?.action()
        case (.popup(_, let titles, let selected, let enabled, let choose), .popup):
            guard enabled() else { return }
            let cur = selected()
            let items = titles.enumerated().map { k, title in
                SQMenuItem(title: SQL10n.string(title), isChecked: k == cur) { [weak self] in self?.onBeginGesture?(); choose(k) }
            }
            onMenu?(items, anchor)
        case (.segments(_, _, let selected, let enabled, let choose), .segment(let k)):
            if enabled(k), k != selected() { choose(k) }
        case (.icons(_, let items), .icon(let k)): if items[k].enabled() { items[k].action() }
        case (.check(_, _, let toggle), .check): onBeginGesture?(); toggle()
        case (.color(_, let get, let set), .well): pick(get(), anchor, set)
        case (.appearance(_, _, let on, let setOn, _, _, _), .appCheck): onBeginGesture?(); setOn(!(on() ?? true))
        case (.appearance(_, _, let on, _, let color, let setColor, _), .appWell):
            if on() != false { pick(color(), anchor, setColor) }
        case (.appearance(_, let key, _, _, _, _, _), .chevron):
            if openDetails.contains(key) { openDetails.remove(key) } else { openDetails.insert(key) }
            onHeightChange?()
        case (.buttons(let bs), .button(let k)): bs[k].action(anchor)
        default: break
        }
    }

    /// The SQ color picker through the host; one picker session is one undo step.
    private func pick(_ current: EffectColor?, _ anchor: CGRect, _ set: @escaping (EffectColor) -> Void) {
        guard let pick = onPickColor else { return }
        onBeginGesture?()
        pick(current ?? .white, anchor) { c in if let c { set(c) } }
    }

    private func apply(_ events: [ScrubFieldControl.Event], _ r: Row, _ k: Int) {
        for e in events {
            switch e {
            case .begin: onBeginGesture?()
            case .live(let v), .change(let v), .end(let v), .cancel(let v): r.setters[k](v)
            }
        }
    }

    /// Keys for the focused field: typing, arrows step, Return / Tab / Esc end it.
    func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        guard let h = focused, case .field(let i) = h.part, rows.indices.contains(h.row) else { return false }
        let r = rows[h.row]
        apply(r.fields[i].key(k, modifiers: modifiers, now: clock()), r, i)
        return true
    }

    func scroll(at p: CGPoint, dy: CGFloat, precise: Bool, modifiers: InputModifiers) -> Bool {
        guard let h = hit(at: p), case .field(let i) = h.part else { return false }
        let r = rows[h.row]
        let (used, events) = r.fields[i].scroll(delta: Double(dy), precise: precise, modifiers: modifiers, focused: focused == h, now: clock())
        apply(events, r, i)
        return used
    }

    func resignFocus() {
        guard let h = focused else { return }
        focused = nil
        guard rows.indices.contains(h.row), case .field(let i) = h.part else { return }
        let r = rows[h.row]
        apply(r.fields[i].resignFocus(), r, i)
    }

    /// Ends idle arrow / wheel bursts.
    func tick() {
        for r in rows { for i in r.fields.indices { apply(r.fields[i].tick(now: clock()), r, i) } }
    }

    func help(at p: CGPoint) -> String? {
        guard let h = hit(at: p) else { return nil }
        switch (rows[h.row].kind, h.part) {
        case (.icons(_, let items), .icon(let k)): return SQL10n.string(items[k].title)
        case (.numbers(_, _, let link), .link): return link.map { SQL10n.string($0.title) }
        case (.section(let title, _, _, _, _), .remove): return SQL10n.format("Remove %@", SQL10n.string(title))
        case (.section(let title, _, _, _, _), .enable): return SQL10n.format("Enable %@", SQL10n.string(title))
        default: return nil
        }
    }
}
