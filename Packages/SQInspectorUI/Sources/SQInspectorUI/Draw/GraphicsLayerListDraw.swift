import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The layer list of the Graphics panel on the shared toolkit (the Mac `LayerListView` + `LayerListRowView`): front layer
/// first; [chevron | indent] kind icon, name, eye, lock; label strip at the left edge; key ticks and the item's range
/// under the name. Click selects (Shift range, Command toggle), a press on a selected row keeps the selection for a drag,
/// a drag moves the layers or a group (Option copies) with an insertion line or a group drop target, double-click or
/// Return renames, the secondary button opens the context menu. All selection and drop rules are `LayerListLogic`'s.
/// Coordinates: points, y down, (0, 0) = the list's top-left; the footer is the bottom `footerHeight`.
@MainActor final class GraphicsLayerListDraw {
    let editor: GraphicsEditor
    var theme = DrawTheme()
    var size = CGSize(width: 300, height: 200)
    var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// Selection or layers changed from here: the panel rebuilds its rows.
    var onSelectionChange: (() -> Void)?

    /// `Theme.Row.list` at UI scale 1 (Theme is AppKit). shortcut: literal, upgrade when Theme.Row moves to a portable file.
    static let rowHeight: CGFloat = 24
    static let footerHeight: CGFloat = 32
    static let iconWidth: CGFloat = 22
    static let iconSlot: CGFloat = 18
    static let tickHeight: CGFloat = 4
    static var trailingWidth: CGFloat { iconSlot * 2 + CGFloat(DrawTheme.Spacing.sm + DrawTheme.Spacing.md) }

    private(set) var rows: [LayerListRow] = []
    private(set) var collapsed: Set<UUID> = []
    private(set) var scrollY: CGFloat = 0
    private var anchor: Int?

    init(editor: GraphicsEditor) { self.editor = editor }

    func reload() {
        rows = editor.document.map { LayerListLogic.rows($0, collapsed: collapsed) } ?? []
        scrollY = min(scrollY, maxScroll)
    }

    // MARK: Layout

    var listHeight: CGFloat { max(size.height - Self.footerHeight, 0) }
    var maxScroll: CGFloat { max(CGFloat(rows.count) * Self.rowHeight - listHeight, 0) }

    static func nameX(for r: LayerListRow) -> CGFloat {
        let base = CGFloat(DrawTheme.Spacing.md)
        if r.groupID != nil { return base + iconWidth }
        return (r.isIndented ? base + iconWidth : base) + iconWidth
    }

    func rowIndex(atY y: CGFloat) -> Int? {
        guard y >= 0, y < listHeight else { return nil }
        let i = Int(floor((y + scrollY) / Self.rowHeight))
        return rows.indices.contains(i) ? i : nil
    }

    func rowFrame(_ i: Int) -> CGRect { CGRect(x: 0, y: CGFloat(i) * Self.rowHeight - scrollY, width: size.width, height: Self.rowHeight) }

    private func lockFrame(_ i: Int) -> CGRect {
        let f = rowFrame(i)
        return CGRect(x: f.width - CGFloat(DrawTheme.Spacing.md) - Self.iconSlot, y: f.minY, width: Self.iconSlot, height: f.height)
    }

    private func eyeFrame(_ i: Int) -> CGRect { lockFrame(i).offsetBy(dx: -(CGFloat(DrawTheme.Spacing.sm) + Self.iconSlot), dy: 0) }

    func stripFrame(_ i: Int) -> CGRect {
        let f = rowFrame(i), x = Self.nameX(for: rows[i])
        return CGRect(x: x, y: f.maxY - Self.tickHeight - 1, width: max(f.width - x - Self.trailingWidth, 0), height: Self.tickHeight)
    }

    /// Key times and range of a layer row; nil when the row shows no strip.
    private func strip(_ i: Int) -> (times: [Time], range: TimeRange?)? {
        guard let id = rows[i].layerID, let l = editor.document?.layer(id) else { return nil }
        let times = LayerListLogic.keyTimes(l)
        return times.isEmpty && l.range == nil ? nil : (times, l.range)
    }

    // MARK: Footer

    enum FooterButton: Int, CaseIterable { case text, shape, draw, group, duplicate, delete }

    func footerFrame(_ b: FooterButton) -> CGRect {
        let y = listHeight + ((Self.footerHeight - ControlsGrid.controlHeight) / 2).rounded()
        let sm = CGFloat(DrawTheme.Spacing.sm), xs = CGFloat(DrawTheme.Spacing.xs), slot: CGFloat = 22
        switch b {
        case .text: return CGRect(x: sm, y: y, width: 60, height: ControlsGrid.controlHeight)
        case .shape: return CGRect(x: sm + 60 + xs, y: y, width: 70, height: ControlsGrid.controlHeight)
        case .draw: return CGRect(x: sm + 130 + xs * 2, y: y, width: slot, height: ControlsGrid.controlHeight)
        case .group, .duplicate, .delete:
            let k = CGFloat(FooterButton.delete.rawValue - b.rawValue)
            return CGRect(x: size.width - sm - slot - k * (slot + xs), y: y, width: slot, height: ControlsGrid.controlHeight)
        }
    }

    func isEnabled(_ b: FooterButton) -> Bool {
        switch b {
        case .text, .shape, .draw: editor.clip != nil
        case .group: editor.selectedLayers.count >= 2
        case .duplicate, .delete: !editor.selectedLayers.isEmpty
        }
    }

    private static func title(_ b: FooterButton) -> String {
        switch b {
        case .text: "+ Text"
        case .shape: "+ Shape"
        case .draw: "Draw"
        case .group: "Group"
        case .duplicate: "Duplicate"
        case .delete: "Delete Layers"
        }
    }

    static func shapeIcon(_ k: ShapeKind) -> SQIcon {
        switch k {
        case .rectangle: .shapeRectangle
        case .ellipse: .shapeEllipse
        case .line: .shapeLine
        case .arrow: .arrowUpRight
        }
    }

    private func press(_ b: FooterButton) {
        guard isEnabled(b) else { return }
        switch b {
        case .text: editor.addText()
        case .shape:
            let items = ShapeKind.allCases.map { k in
                SQMenuItem(title: k.title, icon: .symbol(Self.shapeIcon(k))) { [weak self] in
                    self?.editor.addShape(k); self?.changed()
                }
            }
            onMenu?(items, footerFrame(.shape))
            return
        case .draw: editor.isDrawing.toggle()
        case .group: editor.groupSelected()
        case .duplicate: editor.duplicateSelected()
        case .delete: editor.deleteSelected()
        }
        changed()
    }

    private func changed() { reload(); onSelectionChange?() }

    // MARK: Drawing

    enum Hover: Equatable { case row(Int), eye(Int), lock(Int), footer(FooterButton) }
    private(set) var hover: Hover?
    private var pressedFooter: FooterButton?

    func draw(_ c: inout Canvas, focused: Bool) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        c.saveGState()
        c.clip(to: CGRect(x: 0, y: 0, width: size.width, height: listHeight))
        let d = editor.document ?? GraphicsDocument()
        let sel = editor.selectedLayers
        let inside = editor.playheadInClip
        let local: Time? = inside ? editor.localTime : nil
        for (i, r) in rows.enumerated() {
            let f = rowFrame(i)
            guard f.maxY > 0, f.minY < listHeight else { continue }
            if dropOnto == i || effectTarget == i { c.fill(f, t.accentTint) }
            else if LayerListLogic.isSelected(r, document: d, selection: sel) { c.fill(f, focused ? t.accentTint : t.selection) }
            else if hover == .row(i) || hover == .eye(i) || hover == .lock(i) { c.fill(f, t.fill) }
            if let label = r.label { c.fill(CGRect(x: 0, y: f.minY, width: CGFloat(DrawTheme.Spacing.xs), height: f.height), t.clip(label)) }
            let outside = r.layerID.flatMap { d.layer($0) }.map { LayerListLogic.isOutsideRange($0, local: local) } ?? false
            let nx = Self.nameX(for: r)
            if let g = r.groupID {
                let open = !collapsed.contains(g)
                InspectorDraw.chevron(&c, in: CGRect(x: CGFloat(DrawTheme.Spacing.md), y: f.minY, width: Self.iconWidth, height: f.height),
                                      direction: open ? .down : .right, t.label2)
            } else if let s = r.symbol {
                let tint = outside ? t.label2.alpha(t.label2.a * InspectorTokens.disabledAlpha) : t.label2
                c.draw(icon: s, at: CGPoint(x: nx - Self.iconWidth + 3, y: (f.midY - 6).rounded()), size: 12, tint)
            }
            let eye = eyeFrame(i), lock = lockFrame(i)
            let nameColor = outside || !r.isVisible ? t.label3 : t.label
            if renaming == r.kind, let field = renameField {
                field.draw(&c, in: CGRect(x: nx - 4, y: f.minY + 1, width: max(eye.minX - nx, 60), height: f.height - 2), theme: t, focused: true)
            } else {
                let nameRect = CGRect(x: nx, y: f.minY, width: max(eye.minX - CGFloat(DrawTheme.Spacing.xs) - nx, 0), height: f.height)
                c.draw(r.name, in: nameRect, fontSize: fs, nameColor)
            }
            c.draw(icon: r.isVisible ? .eye : .eyeOff, at: CGPoint(x: eye.midX - 5.5, y: (eye.midY - 5.5).rounded()), size: 11,
                   hover == .eye(i) ? t.label : (r.isVisible ? t.label2 : t.label3))
            c.draw(icon: r.isLocked ? .trackLock : .trackUnlock, at: CGPoint(x: lock.midX - 5.5, y: (lock.midY - 5.5).rounded()), size: 11,
                   hover == .lock(i) ? t.label : (r.isLocked ? t.label : t.label3))
            if let s = strip(i), let clip = editor.clip { drawStrip(&c, stripFrame(i), s.times, s.range, clip.duration, local) }
        }
        if rows.isEmpty, editor.document != nil {
            // The Mac list's empty state: "No layers yet" and its hint.
            c.drawEmptyState(title: SQL10n.string("No layers yet"), hint: SQL10n.string("Add text or a shape below."),
                             in: CGRect(x: 0, y: 0, width: size.width, height: listHeight), theme: t)
        }
        if let gap = dropGap, dropOnto == nil {
            let y = CGFloat(gap) * Self.rowHeight - scrollY
            let sm = CGFloat(DrawTheme.Spacing.sm)
            c.fill(CGRect(x: sm, y: max(y - 1, 0), width: max(size.width - sm * 2, 0), height: 2), t.accent)
        }
        c.restoreGState()
        drawFooter(&c)
    }

    private func drawStrip(_ c: inout Canvas, _ f: CGRect, _ times: [Time], _ range: TimeRange?, _ duration: Time, _ playhead: Time?) {
        let t = theme, w = f.width
        guard w > 0 else { return }
        if let range, duration.value > 0 {
            let span = KeyTickMath.rangeSpan(range, duration: duration, width: w)
            // shortcut: the range bar uses the pressed fill, not `ItemLanes.barFill` (AppKit); upgrade when that token is portable.
            c.fill(CGRect(x: f.minX + span.x, y: f.minY + 1, width: span.width, height: max(f.height - 2, 1)), t.fillPressed)
        }
        for x in KeyTickMath.positions(times: times, duration: duration, width: w) {
            c.fill(CGRect(x: f.minX + min(max(x - 1, 0), max(w - 2, 0)), y: f.minY + 1, width: 2, height: max(f.height - 2, 1)), t.accent)
        }
        if let p = playhead, duration.value > 0 {
            let x = CGFloat(KeyTickMath.fraction(p, in: duration)) * w
            c.fill(CGRect(x: f.minX + min(max(x, 1), max(w - 1, 1)) - 0.5, y: f.minY, width: 1, height: f.height), t.playhead)
        }
    }

    private func drawFooter(_ c: inout Canvas) {
        let t = theme
        c.fill(CGRect(x: 0, y: listHeight, width: size.width, height: 1), t.separator)
        for b in FooterButton.allCases {
            let f = footerFrame(b), en = isEnabled(b), hov = hover == .footer(b)
            switch b {
            case .text, .shape:
                InspectorDraw.button(&c, title: SQL10n.string(Self.title(b)), in: f, hovering: hov, pressed: pressedFooter == b, enabled: en, t)
            default:
                let icon: SQIcon = switch b { case .draw: .draw; case .group: .bundle; case .duplicate: .duplicate; default: .trash }
                let on = b == .draw && editor.isDrawing
                if hov && en { c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.small), t.fillHover) }
                let base = on ? t.accent : (hov ? t.label : t.label2)
                c.draw(icon: icon, at: CGPoint(x: f.midX - 6, y: (f.midY - 6).rounded()), size: 12,
                       en ? base : base.alpha(base.a * InspectorTokens.disabledAlpha))
            }
        }
    }

    // MARK: Pointer

    private var pressRow: Int?
    private var pressPoint: CGPoint?
    private var pressWasSelected = false
    private var drag: LayerDrag?
    private(set) var dropGap: Int?
    private(set) var dropOnto: Int?
    private var counter = ClickCounter()

    func mouseMoved(to p: CGPoint?) {
        guard pressRow == nil, let p else { hover = nil; return }
        if p.y >= listHeight {
            hover = FooterButton.allCases.first { footerFrame($0).contains(p) }.map { .footer($0) }
            return
        }
        guard let i = rowIndex(atY: p.y) else { hover = nil; return }
        hover = eyeFrame(i).contains(p) ? .eye(i) : lockFrame(i).contains(p) ? .lock(i) : .row(i)
    }

    func mouseDown(at p: CGPoint, modifiers: InputModifiers, clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        if renameField != nil { commitRename() }
        if p.y >= listHeight {
            pressedFooter = FooterButton.allCases.first { footerFrame($0).contains(p) }
            return
        }
        if modifiers.contains(.secondary) { contextMenu(at: p); return }
        guard let i = rowIndex(atY: p.y), let d = editor.document else {
            pressRow = nil
            editor.select([]); anchor = nil; onSelectionChange?()
            return
        }
        let r = rows[i]
        if eyeFrame(i).contains(p) { toggleVisible(i); return }
        if lockFrame(i).contains(p) { toggleLocked(i); return }
        // A click on a layer's key strip moves the playhead there (no selection change).
        if strip(i) != nil, let clip = editor.clip {
            let f = stripFrame(i)
            if p.x >= f.minX, p.x <= f.maxX, p.y >= f.minY - 3 {
                editor.seekLocal(KeyTickMath.time(atX: p.x - f.minX, width: f.width, duration: clip.duration))
                return
            }
        }
        // The chevron of a group row opens / closes it.
        if let g = r.groupID, p.x < Self.nameX(for: r) {
            if collapsed.contains(g) { collapsed.remove(g) } else { collapsed.insert(g) }
            reload()
            return
        }
        if n == 2 { beginRename(i); return }
        pressRow = i
        pressPoint = p
        pressWasSelected = LayerListLogic.isSelected(r, document: d, selection: editor.selectedLayers)
        // A press on a selected row keeps the selection until mouse up (so a drag carries all of it).
        if pressWasSelected && !modifiers.contains(.shift) && !modifiers.contains(.command) { return }
        applyClick(i, modifiers: modifiers)
    }

    private func applyClick(_ i: Int, modifiers: InputModifiers) {
        guard let d = editor.document else { return }
        let range = modifiers.contains(.shift), toggle = modifiers.contains(.command)
        let s = LayerListLogic.select(rows: rows, document: d, current: editor.selectedLayers, index: i, anchor: anchor,
                                      toggle: toggle, range: range)
        if !range { anchor = i }
        editor.select(s)
        onSelectionChange?()
    }

    private(set) var isCopying = false

    func mouseDragged(to p: CGPoint, modifiers: InputModifiers = []) {
        guard let i = pressRow, let start = pressPoint, let d = editor.document else { return }
        if drag == nil {
            guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
            if let g = rows[i].groupID, !LayerListLogic.isSelected(rows[i], document: d, selection: editor.selectedLayers)
                || editor.selectedLayers == editor.members(of: g) {
                drag = .group(g)
            } else {
                drag = .layers(Array(editor.selectedLayers))
            }
        }
        isCopying = modifiers.contains(.option)
        // Autoscroll at the edges (one step per drag event).
        if p.y < 0 { scrollY = max(scrollY - Self.rowHeight / 2, 0) }
        if p.y > listHeight { scrollY = min(scrollY + Self.rowHeight / 2, maxScroll) }
        updateDropTarget(at: p)
    }

    private func updateDropTarget(at p: CGPoint) {
        let h = Self.rowHeight
        let y = min(max(p.y + scrollY, 0), CGFloat(rows.count) * h)
        var gap = Int((y / h).rounded())
        var onto: Int?
        if let i = rowIndex(atY: p.y), rows[i].groupID != nil {
            let f = (p.y + scrollY - CGFloat(i) * h) / h
            if f > 0.25 && f < 0.75 { onto = i } else { gap = f <= 0.25 ? i : i + 1 }
        }
        dropGap = gap
        dropOnto = onto
    }

    func mouseUp(at p: CGPoint, modifiers: InputModifiers = []) {
        if let b = pressedFooter {
            pressedFooter = nil
            if footerFrame(b).contains(p) { press(b) }
            return
        }
        defer { pressRow = nil; pressPoint = nil; drag = nil; dropGap = nil; dropOnto = nil; isCopying = false; mouseMoved(to: p) }
        if let drag, let d = editor.document {
            let copy = modifiers.contains(.option) || isCopying
            if let drop = LayerListLogic.drop(drag, rows: rows, document: d, gap: dropGap ?? rows.count, onto: dropOnto, forCopy: copy) {
                if copy { editor.applyCopy(drop) } else { editor.apply(drop) }
                changed()
            }
            return
        }
        // Plain click on an already selected row: now it becomes the only selection.
        if let i = pressRow, pressWasSelected, !modifiers.contains(.shift), !modifiers.contains(.command) {
            applyClick(i, modifiers: [])
        }
    }

    func scroll(dy: CGFloat) {
        scrollY = min(max(scrollY - dy, 0), maxScroll)
    }

    private func members(_ r: LayerListRow) -> Set<UUID> {
        if let id = r.layerID { return [id] }
        if let g = r.groupID { return editor.members(of: g) }
        return []
    }

    private func toggleVisible(_ i: Int) {
        let r = rows[i]
        if let id = r.layerID { editor.setVisible(id, !r.isVisible) } else { editor.setVisible(members(r), !r.isVisible) }
        changed()
    }

    private func toggleLocked(_ i: Int) {
        let r = rows[i]
        if let id = r.layerID { editor.setLocked(id, !r.isLocked) } else { editor.setLocked(members(r), !r.isLocked) }
        changed()
    }

    private func contextMenu(at p: CGPoint) {
        let row = rowIndex(atY: p.y)
        if let i = row, let d = editor.document, !LayerListLogic.isSelected(rows[i], document: d, selection: editor.selectedLayers) {
            applyClick(i, modifiers: [])
        }
        onMenu?(contextItems(row: row), CGRect(origin: p, size: .zero))
    }

    /// Rename, Duplicate, Group, Ungroup | Bring to Front, Bring Forward, Send Backward, Send to Back | Hide Others, Lock Others,
    /// Show All Layers | Label | Delete (the Mac list's menu).
    func contextItems(row: Int?) -> [SQMenuItem] {
        let e = editor
        let sel = !e.selectedLayers.isEmpty
        let grouped = e.selectedLayers.contains { e.document?.layer($0)?.group != nil }
        func act(_ body: @escaping @MainActor (GraphicsEditor) -> Void) -> @MainActor () -> Void {
            { [weak self] in guard let self else { return }; body(self.editor); self.changed() }
        }
        return [
            SQMenuItem(title: "Rename", isEnabled: row != nil) { [weak self] in if let row { self?.beginRename(row) } },
            SQMenuItem(title: "Duplicate", isEnabled: sel, action: act { $0.duplicateSelected() }),
            SQMenuItem(title: "Group", isEnabled: e.selectedLayers.count >= 2, action: act { $0.groupSelected() }),
            SQMenuItem(title: "Ungroup", isEnabled: grouped, action: act { $0.ungroupSelected() }),
            .separator,
            SQMenuItem(title: "Bring to Front", isEnabled: sel, action: act { $0.reorder(.front) }),
            SQMenuItem(title: "Bring Forward", isEnabled: sel, action: act { $0.reorder(.forward) }),
            SQMenuItem(title: "Send Backward", isEnabled: sel, action: act { $0.reorder(.backward) }),
            SQMenuItem(title: "Send to Back", isEnabled: sel, action: act { $0.reorder(.back) }),
            .separator,
            SQMenuItem(title: "Hide Others", isEnabled: sel, action: act { $0.isolateSelection(lock: false) }),
            SQMenuItem(title: "Lock Others", isEnabled: sel, action: act { $0.isolateSelection(lock: true) }),
            SQMenuItem(title: "Show All Layers", action: act { $0.showAllLayers() }),
            .separator,
            SQMenuItem(title: "Label", isEnabled: sel, submenu: labelItems()),
            .separator,
            SQMenuItem(title: "Delete", isEnabled: sel, action: act { $0.deleteSelected() }),
        ]
    }

    /// "No Label" and the 16 colors; the check marks the label every selected layer shares.
    private func labelItems() -> [SQMenuItem] {
        let e = editor
        let shared = Set(e.selectedLayers.map { e.document?.layer($0)?.label })
        var items = [SQMenuItem(title: "No Label", isChecked: shared == [nil]) { [weak e] in e?.setLabel(e?.selectedLayers ?? [], nil) },
                     .separator]
        for l in LabelColor.allCases {
            items.append(SQMenuItem(title: l.displayName, icon: .swatch(l.rgb), isChecked: shared == [l]) { [weak e] in
                e?.setLabel(e?.selectedLayers ?? [], l)
            })
        }
        return items
    }

    // MARK: Effects dropped from the Effects panel (the Mac `effectDragUpdated` / `effectDrop`)

    /// The layer row an Effects drag is over (accent tint); nil elsewhere. Group rows take no effect.
    private(set) var effectTarget: Int?

    /// `p` in list coordinates, nil when the drag left.
    func effectDragOver(at p: CGPoint?) {
        effectTarget = p.flatMap { rowIndex(atY: $0.y) }.flatMap { rows[$0].layerID != nil ? $0 : nil }
    }

    /// Effects released on a layer row: the layer is selected, then takes them. Nil when `p` is not on a layer row.
    func dropEffects(_ kinds: [String], at p: CGPoint) -> GraphicsEditor.EffectDrop? {
        defer { effectTarget = nil }
        guard let i = rowIndex(atY: p.y), let id = rows[i].layerID else { return nil }
        if !editor.selectedLayers.contains(id) { editor.select([id]); changed() }
        return editor.addEffects(kinds, to: id)
    }

    // MARK: Rename (a TextFieldControl over the name)

    private(set) var renameField: TextFieldControl?
    private var renaming: LayerListRow.Kind?

    /// Starts the rename of the single selected layer's row; false when it has no row (inside a collapsed group).
    @discardableResult
    func beginRenameSelected() -> Bool {
        guard editor.selectedLayers.count == 1, let id = editor.selectedLayers.first,
              let i = rows.firstIndex(where: { $0.layerID == id }) else { return false }
        beginRename(i)
        return renameField != nil
    }

    private func beginRename(_ i: Int) {
        guard rows.indices.contains(i), renameField == nil else { return }
        var f = TextFieldControl(text: rows[i].name)
        f.alignment = .left
        f.fontSize = CGFloat(DrawTheme.TypeSize.body)
        f.mouseDown()
        renameField = f
        renaming = rows[i].kind
    }

    /// Keys while renaming: Return commits, Esc cancels. False when no rename is open.
    func key(_ k: InputKey, modifiers: InputModifiers) -> Bool {
        guard var f = renameField else { return false }
        if k == .escape { renameField = nil; renaming = nil; return true }
        let committed = f.key(k, modifiers: modifiers)
        renameField = f
        if let committed { finishRename(committed) }
        return true
    }

    /// Click away commits.
    func commitRename() {
        guard var f = renameField else { return }
        let name = f.commit() ?? f.text
        finishRename(name)
    }

    private func finishRename(_ name: String) {
        let kind = renaming
        renameField = nil
        renaming = nil
        switch kind {
        case .layer(let id): editor.rename(id, name)
        case .group(let g): editor.renameGroup(g, name)
        case nil: break
        }
        reload()
    }

    func help(at p: CGPoint) -> String? {
        if p.y >= listHeight {
            return FooterButton.allCases.first { footerFrame($0).contains(p) }.map { SQL10n.string(Self.title($0)) }
        }
        guard let i = rowIndex(atY: p.y) else { return nil }
        if eyeFrame(i).contains(p) { return SQL10n.string(rows[i].isVisible ? "Hide" : "Show") }
        if lockFrame(i).contains(p) { return SQL10n.string(rows[i].isLocked ? "Unlock" : "Lock") }
        return nil
    }
}
