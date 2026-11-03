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
        static let cardW: CGFloat = 860, cardH: CGFloat = 640, header: CGFloat = 48, footer: CGFloat = 56
        static let side: CGFloat = 20, pad: CGFloat = 16, gap: CGFloat = 8, radius: CGFloat = 12
        static let control: CGFloat = 24, presetW: CGFloat = 148, layoutW: CGFloat = 123, countW: CGFloat = 110
        static let wellPad: CGFloat = 16, keyH: CGFloat = 24, keyPitchY: CGFloat = 34, row: CGFloat = 24, scopeW: CGFloat = 115
        static let keyRadius: CGFloat = 4, wellRadius: CGFloat = 8, ctlRadius: CGFloat = 6
        static let fBody: CGFloat = 11, fTitle: CGFloat = 13, fCap: CGFloat = 10
        static let legendColumns = 5, legendColumnGap: CGFloat = 28, legendRow: CGFloat = 14, legendBar = CGSize(width: 10, height: 3)
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
        y += M.control + 9
        // art.html: keys 42 x 24 on a 48 x 34 pitch, the board left-aligned in a 182 high well (the model's 50 x 42 keys, 56 x 48 pitch).
        let pw = CGFloat(KeyboardLayout.width) * Self.keyScaleX
        p.well = CGRect(x: x0, y: y, width: x1 - x0, height: 182)
        p.picture = CGRect(x: p.well.minX + M.wellPad, y: y + 7, width: pw, height: 4 * M.keyPitchY + M.keyH)
        p.legendTop = p.well.maxY + 11
        p.info = CGRect(x: x0, y: p.well.maxY + 52, width: x1 - x0, height: 16)
        p.note = p.info.offsetBy(dx: 0, dy: 15)
        p.search = CGRect(x: x0, y: p.well.maxY + 75, width: x1 - x0 - M.countW - M.gap, height: 22)
        p.count = CGRect(x: x1 - M.countW, y: p.search.minY, width: M.countW, height: M.control)
        p.list = CGRect(x: x0, y: p.search.maxY + 10, width: x1 - x0, height: Swift.max(p.body.maxY - M.pad - p.search.maxY - 10, 0))
        // Footer: Set Shortcut, Assign to …, Remove at the left, Done at the right (`SQDialog.footerRow`).
        let bh = ShellDialog.M.buttonHeight, by = p.card.maxY - M.footer + ((M.footer - bh) / 2).rounded()
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

    static let keyScaleX: CGFloat = 48.0 / 56.0
    func capRect(_ cap: KeyCap, _ p: Parts) -> CGRect {
        let row = (CGFloat(cap.y) / CGFloat(KeyboardLayout.keyHeight + KeyboardLayout.gap)).rounded()
        return CGRect(x: p.picture.minX + CGFloat(cap.x) * Self.keyScaleX, y: p.picture.minY + row * M.keyPitchY,
                      width: CGFloat(cap.w) * Self.keyScaleX, height: M.keyH)
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
        // art.html legend swatches (same in both appearances).
        // Order of `KeyGroup.allCases`: transport, marking, tools, editing, clipboard, view, file, audio, keyframes, other.
        let table: [UInt32] = [0x4855C9, 0x8F620C, 0x2E7D50, 0x7445C9, 0x0E7A75, 0x55555D, 0xB63A70, 0x2A62C9, 0x6D6D74, 0x55555D]
        let rgb = table[KeyGroup.allCases.firstIndex(of: g) ?? 9]
        return DrawColor(hex: rgb)
    }

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        let p = parts()
        c.fill(frame, DrawColor(0, 0, 0, t.palette.isDark ? ShellDialog.M.scrimAlpha : ShellDialog.M.scrimAlphaLight))
        c.shadow(roundedRect: p.card, radius: M.radius, blur: ShellDialog.M.shadowBlur, dy: ShellDialog.M.shadowDY,
                 DrawColor(0, 0, 0, ShellDialog.M.shadowAlpha), opaqueAbove: true)
        c.fill(roundedRect: p.card, radius: M.radius, t.panel)
        // art.html `.dlg`: header 48 and footer 56 bands, each split by a 1 px `hair` line.
        c.fill(CGRect(x: p.card.minX, y: p.card.minY + M.header - 1, width: p.card.width, height: 1), t.hair)
        c.fill(CGRect(x: p.card.minX, y: p.card.maxY - M.footer, width: p.card.width, height: 1), t.hair)
        c.stroke(roundedRect: p.card.insetBy(dx: 0.25, dy: 0.25), radius: M.radius, width: 0.5, MenuListView.overlayEdge(t))
        c.draw("Keyboard Shortcuts", in: CGRect(x: p.card.minX + M.side, y: p.card.minY + ((M.header - 16) / 2).rounded(), width: p.card.width - 2 * M.side, height: 16),
               fontSize: M.fTitle, t.label, face: c.semibold)
        drawTopRow(&c, t, p)
        drawKeyboard(&c, t, p)
        drawLegend(&c, t, p)
        // Artifact: one 10 pt line, the note follows the info.
        c.draw(info, in: p.info, fontSize: M.fCap, capturing ? t.accent : t.label3)
        let infoW = info.isEmpty ? 0 : textWidth(info, M.fCap) + 8
        c.draw("Keys follow your keyboard layout.", in: CGRect(x: p.info.minX + infoW, y: p.info.minY, width: p.info.width - infoW, height: p.info.height), fontSize: M.fCap, t.label3)
        drawSearch(&c, t, p)
        drawList(&c, t, p)
        drawFooter(&c, t, p)
        menu.draw(&c, theme: t)
    }

    private func control(_ c: inout Canvas, _ t: DrawTheme, _ r: CGRect, _ title: String, hit: Hit, enabled: Bool = true,
                         on: Bool = false, chevron: Bool = false) {
        // art.html `.pop` (well body) for the popups, `.btn` (raised) for the buttons, both with a 0.5 `hair2` ring.
        let fill = on ? t.accentFill : (chevron ? t.well : (pressed == hit ? t.pressed : (hover == hit && enabled ? t.raisedHover : t.raised)))
        c.fill(roundedRect: r, radius: M.ctlRadius, enabled || on ? fill : t.hover)
        if !on, enabled { c.stroke(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), radius: M.ctlRadius, width: 0.5, t.hair2) }
        let text = on ? DrawColor.white : (enabled ? t.label : t.label4)
        if chevron {
            c.draw(SQL10n.string(title), in: CGRect(x: r.minX + 10, y: r.minY, width: r.width - 32, height: r.height), fontSize: M.fBody, text)
            c.draw(icon: .chevronDown, at: CGPoint(x: r.maxX - 20, y: r.midY - 6), size: 12, t.label3)
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
            // Artifact: glyphs only on the panel color; the chosen one gets the `current` fill.
            if modifiers.contains(ch.mod) { c.fill(roundedRect: r, radius: M.ctlRadius, t.current) }
            else if hover == .modifier(i) { c.fill(roundedRect: r, radius: M.ctlRadius, t.hover) }
            c.draw(SQL10n.string(ch.label), in: r, fontSize: M.fBody, modifiers.contains(ch.mod) ? t.label : t.label2, align: .center)
        }
    }

    private func drawKeyboard(_ c: inout Canvas, _ t: DrawTheme, _ p: Parts) {
        c.fill(roundedRect: p.well, radius: M.wellRadius, t.content)
        let model = layoutModel
        for cap in caps where !cap.isGhost {
            let r = capRect(cap, p)
            let group = cap.key.flatMap { model.group(for: $0) }
            // art.html `.key`: raised cap with a `hair2` ring; a mapped key gets a 2 px bar of its group color under the label.
            // Unmapped keys are dim: well body, t3 label, no bar.
            let dim = group == nil || group == .other   // caps the map cannot bind (Tab, Caps, Shift, fn) are free keys too
            c.fill(roundedRect: r, radius: M.keyRadius, dim ? t.well : t.raised)
            c.stroke(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), radius: M.keyRadius, width: 0.5, t.hair2)
            if let g = group, g != .other, r.width > 12 {
                c.fill(roundedRect: CGRect(x: r.minX + 6, y: r.maxY - 5, width: r.width - 12, height: 2), radius: M.legendBar.height / 3, Self.color(g, t))
            }
            if let k = cap.key, k == selectedKey {
                c.stroke(roundedRect: r.insetBy(dx: -1, dy: -1), radius: M.keyRadius + 1, width: 2, t.yellow)
            }
            c.draw(cap.label, in: r.insetBy(dx: 2, dy: 0).offsetBy(dx: 0, dy: group == nil ? 0 : -1), fontSize: M.fBody, dim ? t.label3 : t.label, align: .center)
        }
    }

    private func drawLegend(_ c: inout Canvas, _ t: DrawTheme, _ p: Parts) {
        let groups = KeyGroup.allCases.filter { $0 != .other }
        let widths = groups.map { 10 + 6 + textWidth($0.title, M.fBody) + 1 }
        // art.html: the items flow in one wrapping row, 16 apart, 4 between the rows.
        var x = p.body.minX + M.pad, row = 0
        let maxX = p.body.maxX - M.pad
        for (i, g) in groups.enumerated() {
            if x > p.body.minX + M.pad, x + widths[i] > maxX { x = p.body.minX + M.pad; row += 1 }
            let y = p.legendTop + CGFloat(row) * (M.legendRow + 4)
            c.fill(roundedRect: CGRect(x: x, y: y + (M.legendRow - M.legendBar.height) / 2, width: M.legendBar.width, height: M.legendBar.height), radius: M.legendBar.height / 2, Self.color(g, t))
            c.draw(SQL10n.string(g.title), in: CGRect(x: x + 16, y: y, width: widths[i] - 16, height: M.legendRow), fontSize: M.fBody, t.label2)
            x += widths[i] + 16
        }
    }

    private func drawSearch(_ c: inout Canvas, _ t: DrawTheme, _ p: Parts) {
        let f = p.search
        c.fill(roundedRect: f, radius: M.ctlRadius, t.well)
        c.stroke(roundedRect: f.insetBy(dx: 0.25, dy: 0.25), radius: M.ctlRadius, width: 0.5, t.hair2)
        c.draw(icon: .search, at: CGPoint(x: f.minX + 8, y: f.midY - 6), size: 12, t.label3)
        let textRect = CGRect(x: f.minX + 26, y: f.minY, width: f.width - 26 - 28, height: f.height)
        search.draw(&c, in: textRect, theme: t, focused: search.isEditing)
        if query.isEmpty {
            c.draw("Search shortcuts", in: textRect, fontSize: M.fBody, t.label3)
        } else if !query.isEmpty {
            c.draw(icon: .closeCircleFilled, at: CGPoint(x: f.maxX - 22, y: f.midY - 8), size: 16, t.label3)
        }
        if search.isEditing {
            // art.html `.well.focus`: 1 px accent inset + 3 px glow (accent .25).
            c.stroke(roundedRect: f.insetBy(dx: -1.5, dy: -1.5), radius: M.ctlRadius + 1.5, width: 3, t.accent.alpha(0.25))
            c.stroke(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), radius: M.ctlRadius, width: 1, t.accent)
        }
        c.draw(countText, in: p.count, fontSize: M.fBody, t.label3, align: .right)
    }

    private func drawList(_ c: inout Canvas, _ t: DrawTheme, _ p: Parts) {
        let l = p.list
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
                if i == selectedIndex { c.fill(roundedRect: r, radius: M.keyRadius, t.current) }
                else if hover == .row(i) { c.fill(roundedRect: r, radius: M.keyRadius, t.hover) }
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
            // art.html `.btn`: raised + `hair2` ring; disabled = t4 text on `hover`; the primary (Done) is the accent fill.
            var fill = accent ? t.accentFill : (pressed == h ? t.pressed : (hover == h && enabled ? t.raisedHover : t.raised))
            if accent, pressed == h { fill = fill.lifted(-0.1) }
            if !enabled { fill = accent ? fill.alpha(fill.a * 0.3) : t.hover }
            c.fill(roundedRect: r, radius: ShellDialog.M.buttonRadius, fill)
            if !accent, enabled { c.stroke(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), radius: ShellDialog.M.buttonRadius, width: 0.5, t.hair2) }
            let text = accent ? DrawColor.white : (enabled ? t.label : t.label4)
            c.draw(SQL10n.string(title), in: r, fontSize: ShellDialog.M.buttonFont, accent && !enabled ? text.alpha(0.45) : text, align: .center, face: c.medium)
        }
        button(p.set, "Set Shortcut…", .set, enabled: selectedRow != nil && !capturing, accent: false)
        if let a = p.assign { button(a, assignTitle, .assign, enabled: selectedRow != nil, accent: false) }
        if let r = p.remove { button(r, "Remove", .remove, enabled: true, accent: false) }
        button(p.done, "Done", .done, enabled: true, accent: true)
    }
}
