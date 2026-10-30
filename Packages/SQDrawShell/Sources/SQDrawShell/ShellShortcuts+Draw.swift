import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// Layout, drawing and events of Keyboard Shortcuts: the Mac L modal (860 x 640: header 56, body 516, footer 68) with
/// the `KeyboardLayoutView` picture, the legend, the info line, the search row and `ShortcutList`, on the canvas.
extension ShellShortcutsEditor {
    /// `Theme.Modal.widthL`, `SQDialogMetrics`, `Theme.Row.list`, the Mac constraint constants.
    enum M {
        static let cardW: CGFloat = 860, cardH: CGFloat = 640, header: CGFloat = 56, footer: CGFloat = 68
        static let side: CGFloat = 20, pad: CGFloat = 16, gap: CGFloat = 8, radius: CGFloat = 14
        static let control: CGFloat = 24, presetW: CGFloat = 210, layoutW: CGFloat = 150, countW: CGFloat = 110
        static let wellPad: CGFloat = 16, row: CGFloat = 24, scopeW: CGFloat = 190
        static let keyRadius: CGFloat = 8, wellRadius: CGFloat = 8, ctlRadius: CGFloat = 6
        static let fBody: CGFloat = 12, fTitle: CGFloat = 13, fCap: CGFloat = 11
        static let legendColumns = 5, legendColumnGap: CGFloat = 28, legendRow: CGFloat = 14
    }

    enum Hit: Equatable {
        case preset, layout, reset, modifier(Int), key(Key), search, clearSearch, row(Int), set, assign, remove, done
    }

    struct Parts {
        var card = CGRect.zero, body = CGRect.zero
        var preset = CGRect.zero, layout = CGRect.zero, reset = CGRect.zero
        var modifiers: [CGRect] = []
        var well = CGRect.zero, picture = CGRect.zero
        var legendTop: CGFloat = 0, info = CGRect.zero, note = CGRect.zero
        var search = CGRect.zero, count = CGRect.zero, list = CGRect.zero
        var set = CGRect.zero, assign: CGRect?, remove: CGRect?, done = CGRect.zero
    }

    var keyColumnWidth: CGFloat { platform == .mac ? 90 : 130 }

    func textWidth(_ s: String, _ size: CGFloat) -> CGFloat { ceil(menu.measure.width(SQL10n.string(s), size: size)) }

    func buttonWidth(_ title: String) -> CGFloat { max(textWidth(title, ShellDialog.M.buttonFont) + 2 * ShellDialog.M.buttonPadding, 64) }

    func parts() -> Parts {
        var p = Parts()
        let w = Swift.min(M.cardW, frame.width), h = Swift.min(M.cardH, frame.height)
        p.card = CGRect(x: (frame.midX - w / 2).rounded(), y: (frame.midY - h / 2).rounded(), width: w, height: h)
        p.body = CGRect(x: p.card.minX, y: p.card.minY + M.header, width: w, height: Swift.max(h - M.header - M.footer, 0))
        let x0 = p.body.minX + M.pad, x1 = p.body.maxX - M.pad
        var y = p.body.minY + M.gap
        p.preset = CGRect(x: x0, y: y, width: M.presetW, height: M.control)
        p.layout = CGRect(x: p.preset.maxX + M.gap, y: y, width: M.layoutW, height: M.control)
        p.reset = CGRect(x: p.layout.maxX + M.gap, y: y, width: textWidth("Reset to Defaults", M.fBody) + 22, height: M.control)
        let segW: CGFloat = platform == .mac ? 30 : 48
        var sx = x1 - segW * CGFloat(modifierChoices.count)
        p.modifiers = modifierChoices.map { _ in defer { sx += segW }; return CGRect(x: sx, y: y, width: segW, height: M.control) }
        y += M.control
        let wellH = CGFloat(KeyboardLayout.height) + 2 * M.wellPad
        let pw = CGFloat(KeyboardLayout.width)
        p.well = CGRect(x: p.body.midX - pw / 2, y: y, width: pw, height: wellH)
        p.picture = CGRect(x: p.well.minX, y: y + M.wellPad, width: pw, height: CGFloat(KeyboardLayout.height))
        p.legendTop = p.well.maxY + 11
        p.info = CGRect(x: x0, y: p.well.maxY + 53.5 - 8, width: x1 - x0, height: 16)
        p.note = p.info.offsetBy(dx: 0, dy: 15)
        p.search = CGRect(x: x0, y: p.well.maxY + 78, width: x1 - x0 - M.countW - M.gap, height: M.control)
        p.count = CGRect(x: x1 - M.countW, y: p.search.minY, width: M.countW, height: M.control)
        p.list = CGRect(x: x0, y: p.search.maxY + M.gap, width: x1 - x0, height: Swift.max(p.body.maxY - M.pad - p.search.maxY - M.gap, 0))
        // Footer: Set Shortcut, Assign to …, Remove at the left, Done at the right (`SQDialog.footerRow`).
        let by = p.card.maxY - ShellDialog.M.alertFooterHeight, bh = ShellDialog.M.buttonHeight
        var bx = p.card.minX + M.side
        p.set = CGRect(x: bx, y: by, width: buttonWidth("Set Shortcut…"), height: bh)
        bx = p.set.maxX + M.gap
        if selectedKey != nil {
            let r = CGRect(x: bx, y: by, width: buttonWidth(assignTitle), height: bh)
            p.assign = r
            bx = r.maxX + M.gap
        }
        if selectedRow?.entry != nil { p.remove = CGRect(x: bx, y: by, width: buttonWidth("Remove"), height: bh) }
        let dw = buttonWidth("Done")
        p.done = CGRect(x: p.card.maxX - M.side - dw, y: by, width: dw, height: bh)
        return p
    }

    func capRect(_ cap: KeyCap, _ p: Parts) -> CGRect {
        CGRect(x: p.picture.minX + CGFloat(cap.x), y: p.picture.minY + CGFloat(cap.y), width: CGFloat(cap.w), height: CGFloat(cap.h))
    }

    /// The caps of the picture; Windows names the modifier and edit keys in words.
    var caps: [KeyCap] {
        let caps = KeyboardLayout.caps(style)
        guard platform == .windows else { return caps }
        let words = ["fn": "Fn", "⌃": "Win", "⌥": "Alt", "⌘": "Ctrl", "⇧": "Shift", "⇪": "Caps", "⇥": "Tab", "↩": "Enter", "⌫": "Bksp"]
        return caps.map { var c = $0; c.label = words[c.label] ?? c.label; return c }
    }

    func rowsVisible(_ p: Parts) -> Int { Int(p.list.height / M.row) }

    func scrollToRow(_ i: Int) {
        let p = parts()
        let top = CGFloat(i) * M.row
        if top < scroll { scroll = top } else if top + M.row > scroll + p.list.height { scroll = top + M.row - p.list.height }
    }

    // MARK: Hit testing

    func hit(at q: CGPoint) -> Hit? {
        let p = parts()
        if p.preset.contains(q) { return .preset }
        if p.layout.contains(q) { return .layout }
        if p.reset.contains(q) { return .reset }
        if let i = p.modifiers.firstIndex(where: { $0.contains(q) }) { return .modifier(i) }
        if p.picture.contains(q), let k = caps.first(where: { $0.key != nil && !$0.isGhost && capRect($0, p).contains(q) })?.key { return .key(k) }
        if p.search.contains(q) { return !query.isEmpty && q.x > p.search.maxX - 24 ? .clearSearch : .search }
        if p.list.contains(q) {
            let i = Int((q.y - p.list.minY + scroll) / M.row)
            return rows.indices.contains(i) ? .row(i) : nil
        }
        if p.set.contains(q) { return .set }
        if let a = p.assign, a.contains(q) { return .assign }
        if let r = p.remove, r.contains(q) { return .remove }
        if p.done.contains(q) { return .done }
        return nil
    }

    // MARK: Events

    /// Every event while the editor is up (it is modal). `scale` turns pixels into points.
    public func handle(_ e: InputEvent, scale: Float) {
        let k = CGFloat(Swift.max(scale, 0.01))
        if menu.isOpen { _ = menu.handle(e, scale: scale); return }
        switch e {
        case .mouseDown(let x, let y, _):
            let q = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            if capturing { endCapture() }
            let h = hit(at: q)
            if h != .search, h != .clearSearch, search.isEditing { _ = search.commit() }
            pressed = h
            if let h { press(h) }
        case .mouseUp:
            pressed = nil
        case .mouseMoved(let x, let y), .mouseDragged(let x, let y):
            hover = hit(at: CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k))
        case .scroll(let x, let y, _, let dy, _):
            let p = parts()
            guard p.list.contains(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)) else { return }
            let maxScroll = Swift.max(CGFloat(rows.count) * M.row - p.list.height, 0)
            scrollBody.wheel(dy: dy, scale: k, maxOffset: maxScroll, extent: p.list.height)
        case .keyDown(let key, let m):
            keyDown(key, m)
        }
    }

    func keyDown(_ key: InputKey, _ m: InputModifiers) {
        if capturing { capture(key, m); return }
        switch key {
        case .up, .down:
            guard !rows.isEmpty else { return }
            let next = selectedIndex.map { $0 + (key == .down ? 1 : -1) } ?? 0
            select(index: Swift.min(Swift.max(next, 0), rows.count - 1))
            return
        case .escape:
            if search.isEditing, !query.isEmpty { setQuery(""); search.mouseDown(); return }
            host?.hideShortcuts()
            return
        case .enter:
            if search.isEditing { _ = search.commit() }
            host?.hideShortcuts()
            return
        case .character("f") where m == .command, .character("F") where m == .command:
            search.mouseDown()
            return
        default: break
        }
        if !search.isEditing {
            // Typing goes to the search field (the Mac window keeps it first responder).
            guard m.subtracting(.shift).isEmpty, case .character = key else { return }
            search.mouseDown()
        }
        _ = search.key(key, modifiers: m)
        queryChanged()
    }

    func press(_ h: Hit) {
        let p = parts()
        switch h {
        case .preset: menu.popUp(items: templateMenuItems(), below: p.preset)
        case .layout:
            let items = KeyboardLayout.Style.allCases.map { s in
                SQMenuItem(title: s.title, isChecked: s == style) { [weak self] in self?.setStyle(s) }
            }
            menu.popUp(items: items, below: p.layout)
        case .reset: if canReset { host?.spawn { [weak self] in await self?.resetAll() } }
        case .modifier(let i): toggleModifier(modifierChoices[i].mod)
        case .key(let key): selectKey(key)
        case .search: search.mouseDown()
        case .clearSearch: setQuery("")
        case .row(let i): select(index: i)
        case .set: beginCapture()
        case .assign: if selectedRow != nil { host?.spawn { [weak self] in await self?.assignToKey() } }
        case .remove: removeShortcut()
        case .done: host?.hideShortcuts()
        }
    }

    // MARK: Drawing

    /// Board colors of the command groups (`KeyboardLayoutView.color`: the system palette in the dark appearance).
    static func color(_ g: KeyGroup, _ t: DrawTheme) -> DrawColor {
        switch g {
        case .transport: t.accent
        case .marking: DrawColor(hex: 0xFF9F0A)
        case .tools: DrawColor(hex: 0x30D158)
        case .editing: DrawColor(hex: 0xBF5AF2)
        case .clipboard: DrawColor(hex: 0x64D2FF)
        case .view, .other: DrawColor(hex: 0x98989D)
        case .file: DrawColor(hex: 0xFF453A)
        case .audio: DrawColor(hex: 0xFFD60A)
        case .keyframes: DrawColor(hex: 0xFF375F)
        }
    }

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        let p = parts()
        c.fill(frame, DrawColor(0, 0, 0, ShellDialog.M.scrimAlpha))
        c.shadow(roundedRect: p.card, radius: M.radius, blur: 24, dy: 8, DrawColor(0, 0, 0, 0.35), opaqueAbove: true)
        c.fill(roundedRect: p.card, radius: M.radius, t.overlay)
        c.stroke(roundedRect: p.card.insetBy(dx: 0.25, dy: 0.25), radius: M.radius, width: 0.5, MenuListView.overlayEdge(t))
        c.draw("Keyboard Shortcuts", in: CGRect(x: p.card.minX + M.side, y: p.card.minY + 20, width: p.card.width - 2 * M.side, height: 16),
               fontSize: M.fTitle, t.label)
        drawTopRow(&c, t, p)
        drawKeyboard(&c, t, p)
        drawLegend(&c, t, p)
        c.draw(info, in: p.info, fontSize: M.fBody, capturing ? t.accent : t.label2)
        c.draw("Keys follow your keyboard layout.", in: p.note, fontSize: M.fBody, t.label3)
        drawSearch(&c, t, p)
        drawList(&c, t, p)
        drawFooter(&c, t, p)
        menu.draw(&c, theme: t)
    }

    private func control(_ c: inout Canvas, _ t: DrawTheme, _ r: CGRect, _ title: String, hit: Hit, enabled: Bool = true,
                         on: Bool = false, chevron: Bool = false) {
        let fill = on ? t.accentFill : (pressed == hit ? t.fillPressed : (hover == hit && enabled ? t.fillHover : t.fill))
        c.fill(roundedRect: r, radius: M.ctlRadius, fill)
        let text = on ? DrawColor.white : (enabled ? t.label : t.label3)
        if chevron {
            c.draw(SQL10n.string(title), in: CGRect(x: r.minX + 10, y: r.minY, width: r.width - 32, height: r.height), fontSize: M.fBody, text)
            c.draw(icon: .chevronDown, at: CGPoint(x: r.maxX - 20, y: r.midY - 6), size: 12, t.label2)
        } else {
            c.draw(SQL10n.string(title), in: r, fontSize: M.fBody, text, align: .center)
        }
    }

    private func drawTopRow(_ c: inout Canvas, _ t: DrawTheme, _ p: Parts) {
        control(&c, t, p.preset, config.baseTitle, hit: .preset, chevron: true)
        control(&c, t, p.layout, style.title, hit: .layout, chevron: true)
        control(&c, t, p.reset, "Reset to Defaults", hit: .reset, enabled: canReset)
        for (i, r) in p.modifiers.enumerated() {
            let ch = modifierChoices[i]
            control(&c, t, r, ch.label, hit: .modifier(i), on: modifiers.contains(ch.mod))
        }
    }

    private func drawKeyboard(_ c: inout Canvas, _ t: DrawTheme, _ p: Parts) {
        c.fill(roundedRect: p.well, radius: M.wellRadius, t.content)
        let model = layoutModel
        for cap in caps where !cap.isGhost {
            let r = capRect(cap, p)
            let group = cap.key.flatMap { model.group(for: $0) }
            c.fill(roundedRect: r, radius: M.keyRadius, group.map { Self.color($0, t).alpha(0.24) } ?? t.fill)
            c.stroke(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), radius: M.keyRadius - 0.5, width: 1,
                     group.map { Self.color($0, t).alpha(0.6) } ?? t.fieldEdge)
            if let k = cap.key, k == selectedKey {
                c.stroke(roundedRect: r.insetBy(dx: -1, dy: -1), radius: M.keyRadius + 1, width: 2, t.yellow)
            }
            c.draw(cap.label, in: r.insetBy(dx: 2, dy: 0), fontSize: M.fBody, t.label, align: .center)
        }
    }

    private func drawLegend(_ c: inout Canvas, _ t: DrawTheme, _ p: Parts) {
        let groups = KeyGroup.allCases.filter { $0 != .other }
        let widths = groups.map { 8 + 6 + textWidth($0.title, M.fBody) }
        // Column widths: the widest item of each column (NSGridView), 28 between columns, 4 between the rows.
        var colW = [CGFloat](repeating: 0, count: M.legendColumns)
        for (i, w) in widths.enumerated() { colW[i % M.legendColumns] = Swift.max(colW[i % M.legendColumns], w) }
        for (i, g) in groups.enumerated() {
            let col = i % M.legendColumns, row = i / M.legendColumns
            let x = p.body.minX + M.pad + colW.prefix(col).reduce(0, +) + CGFloat(col) * M.legendColumnGap
            let y = p.legendTop + CGFloat(row) * (M.legendRow + 4)
            c.fill(ellipseIn: CGRect(x: x, y: y + (M.legendRow - 8) / 2, width: 8, height: 8), Self.color(g, t))
            c.draw(SQL10n.string(g.title), in: CGRect(x: x + 14, y: y, width: colW[col], height: M.legendRow), fontSize: M.fBody, t.label2)
        }
    }

    private func drawSearch(_ c: inout Canvas, _ t: DrawTheme, _ p: Parts) {
        let f = p.search
        c.fill(roundedRect: f, radius: M.ctlRadius, t.field)
        c.draw(icon: .search, at: CGPoint(x: f.minX + 8, y: f.midY - 6), size: 12, t.label3)
        let textRect = CGRect(x: f.minX + 26, y: f.minY, width: f.width - 26 - 28, height: f.height)
        search.draw(&c, in: textRect, theme: t, focused: search.isEditing)
        if query.isEmpty, !search.isEditing {
            c.draw("Search", in: textRect, fontSize: M.fBody, t.label3)
        } else if !query.isEmpty {
            c.draw(icon: .closeCircleFilled, at: CGPoint(x: f.maxX - 22, y: f.midY - 8), size: 16, t.label3)
        }
        if search.isEditing { c.stroke(roundedRect: f.insetBy(dx: -1, dy: -1), radius: M.ctlRadius + 1, width: 2, t.accent) }
        c.draw(countText, in: p.count, fontSize: M.fBody, t.label3, align: .right)
    }

    private func drawList(_ c: inout Canvas, _ t: DrawTheme, _ p: Parts) {
        let l = p.list
        c.fill(roundedRect: l, radius: M.wellRadius, t.content)
        c.saveGState()
        c.clip(to: l)
        if rows.isEmpty {
            c.draw("No matching shortcuts", in: CGRect(x: l.minX, y: l.midY - 16, width: l.width, height: 16), fontSize: M.fBody, t.label2, align: .center)
            c.draw("Try another name or key", in: CGRect(x: l.minX, y: l.midY + 2, width: l.width, height: 14), fontSize: M.fCap, t.label3, align: .center)
        }
        let first = Swift.max(0, Int(scroll / M.row)), last = Swift.min(rows.count - 1, Int((scroll + l.height) / M.row))
        if first <= last {
            let keyW = keyColumnWidth, pad: CGFloat = 12
            for i in first...last {
                let r = CGRect(x: l.minX, y: l.minY + CGFloat(i) * M.row - scroll, width: l.width, height: M.row)
                if i == selectedIndex { c.fill(r, search.isEditing ? t.selection : t.accentFill.alpha(0.35)) }
                else if hover == .row(i) { c.fill(r, t.inkFill(0.06)) }
                let it = rows[i].listing
                let keyX = r.maxX - pad - M.scopeW - keyW
                c.draw(SQL10n.string(it.command), in: CGRect(x: r.minX + pad, y: r.minY, width: keyX - r.minX - pad - 8, height: r.height), fontSize: M.fBody, t.label)
                c.draw(it.shortcut, in: CGRect(x: keyX, y: r.minY, width: keyW, height: r.height), fontSize: M.fBody, t.label2)
                c.draw(SQL10n.string(it.scope), in: CGRect(x: r.maxX - pad - M.scopeW, y: r.minY, width: M.scopeW, height: r.height), fontSize: M.fBody, t.label3)
            }
        }
        c.restoreGState()
    }

    private func drawFooter(_ c: inout Canvas, _ t: DrawTheme, _ p: Parts) {
        func button(_ r: CGRect, _ title: String, _ h: Hit, enabled: Bool, accent: Bool) {
            var fill = accent ? t.accentFill : (pressed == h ? t.fillPressed : (hover == h && enabled ? t.fillHover : t.fill))
            if accent, pressed == h { fill = fill.lifted(-0.1) }
            if !enabled { fill = fill.alpha(fill.a * 0.5) }
            c.fill(roundedRect: r, radius: ShellDialog.M.buttonRadius, fill)
            let text = accent ? DrawColor.white : t.label
            c.draw(SQL10n.string(title), in: r, fontSize: ShellDialog.M.buttonFont, enabled ? text : text.alpha(0.45), align: .center)
        }
        button(p.set, "Set Shortcut…", .set, enabled: selectedRow != nil && !capturing, accent: true)
        if let a = p.assign { button(a, assignTitle, .assign, enabled: selectedRow != nil, accent: false) }
        if let r = p.remove { button(r, "Remove", .remove, enabled: true, accent: false) }
        button(p.done, "Done", .done, enabled: true, accent: true)
    }
}
