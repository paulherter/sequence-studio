import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The Template section of Controls on the shared toolkit: `TemplateSlotsView` translated. One row per editable slot of
/// an applied title template (text, color, font, number), then "Keep intro and outro" and, while the zones are on, the
/// Middle choice (Hold / Stretch). A slot edit goes out as `(slot, value, continuesGesture)` so a drag or a typing run
/// is one undo step. Coordinates: points, y down, (0, 0) = the block's top-left.
@MainActor final class TemplateSlotsDraw {
    var theme = DrawTheme()
    var width: CGFloat = 320
    var onSlotChange: ((TemplateSlot.ID, SlotValue, Bool) -> Void)?
    var onZonesToggle: ((Bool) -> Void)?
    var onMiddleChange: ((AnimationZones.Middle) -> Void)?
    var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    var onPickColor: (@MainActor (_ current: EffectColor, _ anchor: CGRect,
                                  _ change: @escaping @MainActor (EffectColor?) -> Void) -> Void)?
    /// The installed font families for a font slot's popup.
    var fontFamilies: () -> [String] = { [] }
    var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }

    private(set) var slots: [TemplateSlot] = []
    private(set) var zones: AnimationZones?
    private var gestureOpen: Set<TemplateSlot.ID> = []
    private var texts: [TemplateSlot.ID: TextFieldControl] = [:]
    private var numbers: [TemplateSlot.ID: ScrubFieldControl] = [:]
    private(set) var focused: TemplateSlot.ID?

    static let rowHeight = ControlsGrid.rowHeight
    static let segmentWidth: CGFloat = 64
    static let swatchHeight: CGFloat = 18

    var height: CGFloat { CGFloat(slots.count + 1 + (zones != nil ? 1 : 0)) * Self.rowHeight }

    /// Shows `slots` and the zones of the selected template clip. Values update in place; a field being typed in or
    /// dragged keeps its own value. True when the height changed.
    @discardableResult
    func show(slots new: [TemplateSlot], zones z: AnimationZones?) -> Bool {
        let before = height
        if new.map(\.id) != slots.map(\.id) {
            texts = [:]; numbers = [:]; gestureOpen = []; focused = nil; pressed = nil
        }
        slots = new
        zones = z
        for s in new {
            switch s.value {
            case .text(let t):
                var f = texts[s.id] ?? TextFieldControl(text: t)
                f.alignment = .left
                f.fontSize = CGFloat(DrawTheme.TypeSize.body)
                if !f.isEditing { f.text = t }
                texts[s.id] = f
            case .number(let n):
                var f = numbers[s.id] ?? ScrubFieldControl(value: n)
                f.range = 1...1000
                if !f.isDragging, !f.isEditing { f.value = n }
                numbers[s.id] = f
            default: break
            }
        }
        return height != before
    }

    // MARK: Layout

    enum Control: Hashable { case slot(Int), zones, middle(Int) }

    func rowY(_ i: Int) -> CGFloat { CGFloat(i) * Self.rowHeight }

    /// The control's frame (block coordinates).
    func frame(_ k: Control) -> CGRect {
        let h = Self.rowHeight, ch = ControlsGrid.controlHeight
        switch k {
        case .slot(let i):
            let y = rowY(i)
            switch slots[i].kind {
            case .text, .font:
                return CGRect(x: ControlsGrid.valueX, y: y + ((h - ch) / 2).rounded(),
                              width: max(width - ControlsGrid.valueX - ControlsGrid.trailing, 0), height: ch)
            case .color:
                return CGRect(x: ControlsGrid.valueX, y: y + ((h - Self.swatchHeight) / 2).rounded(), width: ControlsGrid.valueWidth,
                              height: Self.swatchHeight)
            case .number:
                return CGRect(x: ControlsGrid.valueX, y: y + ((h - ch) / 2).rounded(), width: ControlsGrid.valueWidth, height: ch)
            }
        case .zones:
            return CGRect(x: ControlsGrid.valueX, y: rowY(slots.count), width: max(width - ControlsGrid.valueX - ControlsGrid.trailing, 0), height: h)
        case .middle(let i):
            return CGRect(x: ControlsGrid.valueX + CGFloat(i) * Self.segmentWidth, y: rowY(slots.count + 1) + ((h - ch) / 2).rounded(),
                          width: Self.segmentWidth, height: ch)
        }
    }

    func control(at p: CGPoint) -> Control? {
        guard p.y >= 0, p.y < height else { return nil }
        let row = Int(p.y / Self.rowHeight)
        if row < slots.count { return frame(.slot(row)).contains(p) ? .slot(row) : nil }
        if row == slots.count {
            let f = frame(.zones)
            return p.x >= f.minX && p.x < f.minX + 16 + checkLabelWidth ? .zones : nil
        }
        return (0..<2).first { frame(.middle($0)).contains(p) }.map { .middle($0) }
    }

    private var checkLabelWidth: CGFloat = 160

    // MARK: Drawing

    func draw(_ c: inout Canvas) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body), h = Self.rowHeight
        for (i, s) in slots.enumerated() {
            label(&c, s.name, y: rowY(i))
            let f = frame(.slot(i)), hov = hover == .slot(i)
            switch s.value {
            case .text:
                guard var fd = texts[s.id] else { continue }
                fd.hovering = hov
                fd.draw(&c, in: f, theme: t, focused: false)
            case .color(let r, let g, let b, let a):
                InspectorDraw.colorWell(&c, DrawColor(Float(r), Float(g), Float(b), Float(a)), in: f, hovering: hov, t)
            case .font(let n):
                InspectorDraw.popup(&c, title: n.isEmpty ? SQL10n.string("Default") : n, in: f, hovering: hov, open: false,
                                    enabled: true, t)
            case .number:
                guard var fd = numbers[s.id] else { continue }
                fd.hovering = hov
                fd.draw(&c, in: f, theme: t, focused: focused == s.id)
            }
        }
        // Keep intro and outro: a checkbox with its title, then Middle while the zones are on.
        let zy = rowY(slots.count), box = CGRect(x: ControlsGrid.valueX, y: zy + ((h - 14) / 2).rounded(), width: 14, height: 14)
        InspectorDraw.checkbox(&c, zones == nil ? .off : .on, box: box, hovering: hover == .zones, pressed: pressed == .zones,
                               enabled: true, t)
        let title = SQL10n.string("Keep intro and outro")
        checkLabelWidth = c.size(of: title, fontSize: fs).width + 6
        c.draw(title, in: CGRect(x: box.maxX + 6, y: zy, width: max(width - box.maxX - 6 - ControlsGrid.trailing, 0), height: h),
               fontSize: fs, t.label)
        guard let z = zones else { return }
        label(&c, "Middle", y: rowY(slots.count + 1))
        for (i, name) in ["Hold", "Stretch"].enumerated() {
            let f = frame(.middle(i)), on = (z.middle == .stretch) == (i == 1)
            c.fill(roundedRect: f.insetBy(dx: 1, dy: 0), radius: CGFloat(DrawTheme.Radius.small),
                   on ? t.fillPressed : (hover == .middle(i) ? t.fillHover : t.fill))
            c.draw(SQL10n.string(name), in: f, fontSize: fs, on ? t.label : t.label2, align: .center)
        }
    }

    private func label(_ c: inout Canvas, _ s: String, y: CGFloat) {
        c.draw(SQL10n.string(s), in: CGRect(x: ControlsGrid.labelX, y: y, width: ControlsGrid.valueX - ControlsGrid.labelX - ControlsGrid.gap,
                                            height: Self.rowHeight), fontSize: CGFloat(DrawTheme.TypeSize.body), theme.label2)
    }

    // MARK: Pointer and keys

    private(set) var hover: Control?
    private(set) var pressed: Control?
    private var counter = ClickCounter()

    func mouseMoved(to p: CGPoint?) { if pressed == nil { hover = p.flatMap(control) } }

    func mouseDown(at p: CGPoint, clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        let k = control(at: p)
        if let id = focused, k.flatMap(slotID) != id { resignFocus() }
        pressed = k
        guard case .slot(let i)? = k else { return }
        let s = slots[i]
        switch s.kind {
        case .text:
            guard var fd = texts[s.id] else { return }
            fd.mouseDown()
            texts[s.id] = fd
            focused = s.id
            pressed = nil
        case .number:
            guard var fd = numbers[s.id] else { return }
            apply(fd.mouseDown(x: Float(p.x), clickCount: n), s.id)
            numbers[s.id] = fd
            focused = s.id
        case .font:
            pressed = nil
            let cur: String? = if case .font(let n) = s.value { n } else { nil }
            let items = fontFamilies().map { f in
                SQMenuItem(title: f, isChecked: f == cur) { [weak self] in
                    self?.send(s.id, .font(f)); self?.gestureOpen.remove(s.id)
                }
            }
            if !items.isEmpty { onMenu?(items, frame(.slot(i))) }
        case .color: break
        }
    }

    private func slotID(_ k: Control) -> TemplateSlot.ID? {
        if case .slot(let i) = k { slots[i].id } else { nil }
    }

    func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        guard case .slot(let i)? = pressed, slots[i].kind == .number, var fd = numbers[slots[i].id] else { return }
        apply(fd.mouseDragged(x: Float(p.x), modifiers: modifiers), slots[i].id)
        numbers[slots[i].id] = fd
    }

    func mouseUp(at p: CGPoint) {
        let k = pressed
        pressed = nil
        defer { mouseMoved(to: p) }
        if case .slot(let i)? = k, slots[i].kind == .number, var fd = numbers[slots[i].id] {
            apply(fd.mouseUp(), slots[i].id)
            numbers[slots[i].id] = fd
            return
        }
        guard let k, control(at: p) == k else { return }
        switch k {
        case .slot(let i) where slots[i].kind == .color: pickColor(i)
        case .zones: onZonesToggle?(zones == nil)
        case .middle(let i): onMiddleChange?(i == 1 ? .stretch : .hold)
        default: break
        }
    }

    /// The SQ color picker through the host; one picker session is one undo step.
    private func pickColor(_ i: Int) {
        guard let pick = onPickColor, case .color(let r, let g, let b, let a) = slots[i].value else { return }
        let id = slots[i].id
        gestureOpen.remove(id)
        pick(EffectColor(red: r, green: g, blue: b, alpha: a), frame(.slot(i))) { [weak self] color in
            guard let self else { return }
            guard let color else { gestureOpen.remove(id); return }
            send(id, .color(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
        }
    }

    private func apply(_ events: [ScrubFieldControl.Event], _ id: TemplateSlot.ID) {
        for e in events {
            switch e {
            case .begin: gestureOpen.remove(id)
            case .live(let v), .change(let v): send(id, .number(v))
            case .end(let v): send(id, .number(v)); gestureOpen.remove(id)
            case .cancel(let v): send(id, .number(v)); gestureOpen.remove(id)
            }
        }
    }

    private func send(_ id: TemplateSlot.ID, _ value: SlotValue) {
        let continues = gestureOpen.contains(id)
        gestureOpen.insert(id)
        onSlotChange?(id, value, continues)
    }

    /// Keys for the focused slot: typing goes out live (one undo step per run), Return / Tab / Esc end the field.
    func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        guard let id = focused else { return false }
        if var fd = texts[id], fd.isEditing {
            let before = fd.editor?.string
            let committed = fd.key(k, modifiers: modifiers)
            texts[id] = fd
            if let s = fd.editor?.string, s != before { send(id, .text(s)) }
            if let committed, committed != before { send(id, .text(committed)) }
            if !fd.isEditing { gestureOpen.remove(id); focused = nil }
            return true
        }
        if var fd = numbers[id] {
            apply(fd.key(k, modifiers: modifiers, now: clock()), id)
            numbers[id] = fd
            return true
        }
        return false
    }

    func resignFocus() {
        guard let id = focused else { return }
        focused = nil
        if var fd = texts[id] {
            let before = fd.editor?.string
            if let s = fd.commit(), s != before { send(id, .text(s)) }
            texts[id] = fd
        }
        if var fd = numbers[id] { apply(fd.resignFocus(), id); numbers[id] = fd }
        gestureOpen.remove(id)
    }

    /// Ends idle arrow / wheel bursts of the number slots.
    func tick() {
        for id in Array(numbers.keys) {
            guard var fd = numbers[id] else { continue }
            apply(fd.tick(now: clock()), id)
            numbers[id] = fd
        }
    }

    func help(at p: CGPoint) -> String? {
        switch control(at: p) {
        case .zones: SQL10n.string("The first and last moments of the title keep their length when you trim or stretch the clip.")
        case .middle: SQL10n.string("Middle of the title when the clip length changes")
        case .slot(let i): slots[i].name
        case nil: nil
        }
    }
}
