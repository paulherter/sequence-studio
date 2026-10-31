import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import SQUIKit

/// What the Keystones card asks of its host.
public enum KeystonePaletteEvent: Equatable, Sendable {
    /// A row is being dragged; the pointer is at window pixels `x`, `y` (the host calls `TimelinePanel.keystoneHover`).
    case drag(Keystone, x: Float, y: Float)
    /// Released at window pixels `x`, `y` (`TimelinePanel.keystoneDrop` when over the panel, else `keystoneExit`).
    case drop(Keystone, x: Float, y: Float)
    /// Esc during the drag (`keystoneExit`).
    case cancel
    /// Double-click: the Mac panel's "Apply to Selected Clip".
    case apply(Keystone)
    /// Right press on the card at window points `at`: the row's keystone (nil off the rows). The host shows
    /// `KeystonePalette.contextItems`.
    case menu(Keystone?, at: CGPoint)
    /// The header "..." at window points `at`: the host shows `KeystonePalette.optionItems`.
    case options(at: CGPoint)
    /// Delete key on the selected keystone (the host deletes it when `KeystonesPanelModel.canDelete`).
    case delete(Keystone)
}

/// Window > Keystones on the shared toolkit, translated from the Mac `KeystonesPanelView` list: the same rows
/// (`KeystonesPanelModel`: built-ins plus saved ones, diamond, name, `subtitle`) on a floating card over the timeline
/// area. Press a row and drag it onto a clip, or double-click to apply it to the selected clip; the header "..." and the
/// right-click menu save, apply, edit the curve and delete (`contextItems`, the Mac `contextItems(row:)`).
public struct KeystonePalette: Sendable {
    public var theme: DrawTheme
    public var isVisible = false
    public var keystones: [Keystone] = []
    public var selectedID: UUID?
    /// Built-in keystones the user edited: their row carries the "changed" chip (the Mac `KeystoneChip`).
    public var changed: Set<UUID> = []
    /// Docked in a dock card (the Mac `KeystonesPanelView` as a Window > Keystones panel): the list fills the card, the
    /// card's tab strip carries the title and the "..." (`layout(docked:)`); no own header, shadow or close button.
    public private(set) var isDocked = false
    public var clock: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }

    /// The card in window points.
    public private(set) var frame = CGRect.zero
    public private(set) var scale: Float = 1
    public private(set) var hovered: Int?
    let scrollBody = ScrollBody()
    /// The scroll offset; the body adds momentum and the rubber band.
    public private(set) var scroll: CGFloat {
        get { scrollBody.position }
        set { scrollBody.position = newValue }
    }
    private var press: (index: Int, start: CGPoint)?
    public private(set) var dragging: Keystone?
    /// Where the pointer is (window points) while a row is dragged; nil otherwise. The host tints the drop target under it.
    public private(set) var dragPoint: CGPoint?
    private var lastClick: (index: Int, time: Double)?
    private var hoverPoint: CGPoint?

    // Mac metrics: `Theme.Row.panelList` 26, panel header 30, `Theme.Spacing.sm` padding.
    public static let rowHeight: CGFloat = 26
    public static let headerHeight = CGFloat(DrawTheme.Metrics.panelHeader)
    public static let width: CGFloat = 280
    static let dragSlop: CGFloat = 3
    static let doubleClick: Double = 0.4

    public init(theme: DrawTheme = DrawTheme()) { self.theme = theme }

    public var isDragging: Bool { press != nil }

    /// Anchors the card to the top right of `area` (window points), as tall as its rows allow.
    public mutating func layout(in area: CGRect, scale s: Float) {
        scale = s
        let inset = CGFloat(DrawTheme.Spacing.sm)
        let rows = CGFloat(keystones.count) * Self.rowHeight + Self.headerHeight + CGFloat(DrawTheme.Spacing.xs)
        let h = max(min(rows, area.height - 2 * inset), Self.headerHeight)
        let w = min(Self.width, max(area.width - 2 * inset, 0))
        frame = CGRect(x: area.maxX - inset - w, y: area.minY + inset, width: w, height: h)
        isDocked = false
        scroll = min(scroll, maxScroll)
    }

    /// Fills `card` (window points) as a docked panel; nil hides it (its tab is not the shown one).
    public mutating func layout(docked card: CGRect?, scale s: Float) {
        scale = s
        isDocked = true
        isVisible = card != nil
        frame = card ?? .zero
        scroll = min(scroll, maxScroll)
    }

    var headerHeightNow: CGFloat { isDocked ? CGFloat(DrawTheme.Spacing.xs) : Self.headerHeight }

    var listRect: CGRect {
        CGRect(x: frame.minX, y: frame.minY + headerHeightNow, width: frame.width, height: max(frame.height - headerHeightNow, 0))
    }
    var closeRect: CGRect {
        let s: CGFloat = 20
        return CGRect(x: frame.maxX - CGFloat(DrawTheme.Spacing.sm) - s, y: frame.minY + (Self.headerHeight - s) / 2, width: s, height: s)
    }
    /// The header "..." (the Mac panel header's options button), left of the close button.
    var optionsRect: CGRect { closeRect.offsetBy(dx: -closeRect.width - CGFloat(DrawTheme.Spacing.xs), dy: 0) }
    var maxScroll: CGFloat { max(CGFloat(keystones.count) * Self.rowHeight - listRect.height, 0) }

    func rowRect(_ i: Int) -> CGRect {
        CGRect(x: frame.minX, y: listRect.minY + CGFloat(i) * Self.rowHeight - scroll, width: frame.width, height: Self.rowHeight)
    }

    public func row(at p: CGPoint) -> Int? {
        guard listRect.contains(p) else { return nil }
        let i = Int(((p.y - listRect.minY + scroll) / Self.rowHeight).rounded(.down))
        return keystones.indices.contains(i) ? i : nil
    }

    /// The hover tip of the row at window point `p`: what the keystone animates (the Mac row tooltip).
    public func help(at p: CGPoint) -> String? {
        row(at: p).map { KeystonesPanelModel.subtitle(keystones[$0]) }
    }

    public func contains(x: Float, y: Float) -> Bool {
        isVisible && frame.contains(CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)))
    }

    // MARK: Events

    /// Events on the card and the drags that start on it; nil = not the card's (pointer moves always go on).
    public mutating func handle(_ e: InputEvent) -> [KeystonePaletteEvent]? {
        guard isVisible else { return nil }
        let k = CGFloat(max(scale, 0.01))
        switch e {
        case .mouseDown(let x, let y, let m):
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            guard frame.contains(p) else { return nil }
            if !isDocked, closeRect.contains(p) { isVisible = false; return [] }
            if !isDocked, optionsRect.contains(p) { return [.options(at: CGPoint(x: optionsRect.minX, y: optionsRect.maxY))] }
            guard let i = row(at: p) else { return m.contains(.secondary) ? [.menu(nil, at: p)] : [] }
            selectedID = keystones[i].id
            if m.contains(.secondary) { return [.menu(keystones[i], at: p)] }
            let t = clock()
            if let last = lastClick, last.index == i, t - last.time < Self.doubleClick {
                lastClick = nil
                return [.apply(keystones[i])]
            }
            lastClick = (i, t)
            press = (i, p)
            return []
        case .mouseDragged(let x, let y):
            guard let pr = press else { return nil }
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            if dragging == nil, hypot(p.x - pr.start.x, p.y - pr.start.y) < Self.dragSlop { return [] }
            let ks = keystones[pr.index]
            dragging = ks
            dragPoint = p
            lastClick = nil
            return [.drag(ks, x: x, y: y)]
        case .mouseUp(let x, let y):
            guard press != nil else { return nil }
            defer { press = nil; dragging = nil; dragPoint = nil }
            guard let ks = dragging else { return [] }
            return [.drop(ks, x: x, y: y)]
        case .mouseMoved(let x, let y):
            hoverPoint = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            hovered = row(at: hoverPoint!)
            return nil
        case .scroll(let x, let y, _, let dy, _):
            guard frame.contains(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)) else { return nil }
            scrollBody.wheel(dy: dy, scale: k, maxOffset: maxScroll, extent: listRect.height)
            return []
        case .keyDown(let key, let m):
            // Delete on the selected row while the pointer is over the card (the card has no keyboard focus of its own).
            // shortcut: Delete needs the pointer over the card; give the card focus when the shell tracks panel focus.
            if key == .delete || key == .backspace, m.isEmpty, press == nil, let hp = hoverPoint, frame.contains(hp),
               let k = keystones.first(where: { $0.id == selectedID }) { return [.delete(k)] }
            guard key == .escape, press != nil else { return nil }
            let was = dragging != nil
            press = nil; dragging = nil; dragPoint = nil
            return was ? [.cancel] : []
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        guard isVisible, frame.width > 0 else { return }
        let g: CGFloat = 12
        if !isDocked { drawCard(&c) }
        drawRows(&c, g: g)
    }

    private func drawCard(_ c: inout Canvas) {
        let r = CGFloat(DrawTheme.Radius.panel)
        c.shadow(roundedRect: frame, radius: r, blur: 10, dy: 4, DrawColor(0, 0, 0, 0.25))
        c.fill(roundedRect: frame, radius: r, theme.panel)
        c.stroke(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), radius: r, width: 1, theme.separator)
        let header = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Self.headerHeight)
        c.draw(SQL10n.string("Keystones"), in: header.insetBy(dx: CGFloat(DrawTheme.Spacing.md), dy: 0),
               fontSize: CGFloat(DrawTheme.TypeSize.title), theme.label)
        let g: CGFloat = 12
        c.draw(icon: .close, at: CGPoint(x: closeRect.midX - g / 2, y: closeRect.midY - g / 2), size: g, theme.label2)
        c.draw(icon: .ellipsis, at: CGPoint(x: optionsRect.midX - g / 2, y: optionsRect.midY - g / 2), size: g, theme.label2)
        c.fill(CGRect(x: frame.minX, y: header.maxY - 1, width: frame.width, height: 1), theme.separator)
    }

    private func drawRows(_ c: inout Canvas, g: CGFloat) {
        let pad = CGFloat(DrawTheme.Spacing.sm)
        if keystones.isEmpty, isDocked {
            // The Mac panel's empty state.
            c.drawEmptyState(title: SQL10n.string("No keystones yet"),
                             hint: SQL10n.string("Save the keyframes of a clip as a keystone to reuse them."), in: frame, theme: theme)
            return
        }
        c.saveGState()
        c.clip(to: listRect)
        let font = CGFloat(DrawTheme.TypeSize.body)
        for (i, k) in keystones.enumerated() {
            let rr = rowRect(i)
            guard rr.maxY >= listRect.minY, rr.minY <= listRect.maxY else { continue }
            let pill = rr.insetBy(dx: CGFloat(DrawTheme.Spacing.xs), dy: 1)
            if k.id == selectedID { c.fill(roundedRect: pill, radius: CGFloat(DrawTheme.Radius.small), theme.accentFill) }
            else if hovered == i { c.fill(roundedRect: pill, radius: CGFloat(DrawTheme.Radius.small), theme.fillHover) }
            c.draw(icon: .diamond, at: CGPoint(x: rr.minX + 2 * pad, y: rr.midY - g / 2), size: g, theme.label3)
            let nameX = rr.minX + 2 * pad + 14 + CGFloat(DrawTheme.Spacing.xs)
            let meta = KeystonesPanelModel.subtitle(k)
            let mw = min(c.size(of: meta, fontSize: font).width, rr.width * 0.5)
            let metaX = rr.maxX - 2 * pad - mw
            let chipText = SQL10n.string("changed")
            let chipW = changed.contains(k.id) ? ceil(c.size(of: chipText, fontSize: font).width) + 2 * pad - CGFloat(DrawTheme.Spacing.sm) : 0
            let nameW = min(c.size(of: k.name, fontSize: font).width,
                            max(metaX - nameX - pad - (chipW > 0 ? chipW + CGFloat(DrawTheme.Spacing.xs) : 0), 0))
            c.draw(k.name, in: CGRect(x: nameX, y: rr.minY, width: nameW, height: rr.height), fontSize: font, theme.label2)
            if chipW > 0 {
                let chip = CGRect(x: nameX + nameW + CGFloat(DrawTheme.Spacing.xs), y: rr.midY - 10, width: chipW, height: 20)
                c.fill(roundedRect: chip, radius: 10, theme.fill)
                c.draw(chipText, in: chip, fontSize: font, theme.label2, align: .center)
            }
            c.draw(meta, in: CGRect(x: metaX, y: rr.minY, width: mw, height: rr.height), fontSize: font, theme.label3)
        }
        c.restoreGState()
    }
}

// MARK: Menus

/// What the card's menu items do; the host fills these in (the Mac panel's `onApply`, `onSaveFromClip`, `editCurve`,
/// the model's `setEasing` and `onDelete`).
public struct KeystonePaletteActions: Sendable {
    public var apply: @MainActor @Sendable (Keystone) -> Void
    public var saveFromClip: @MainActor @Sendable () -> Void
    public var editCurve: @MainActor @Sendable (Keystone) -> Void
    public var useKeyframeEasing: @MainActor @Sendable (Keystone) -> Void
    public var delete: @MainActor @Sendable (Keystone) -> Void

    public typealias Run = @MainActor @Sendable (Keystone) -> Void
    public init(apply: @escaping Run, saveFromClip: @escaping @MainActor @Sendable () -> Void, editCurve: @escaping Run,
                useKeyframeEasing: @escaping Run, delete: @escaping Run) {
        self.apply = apply; self.saveFromClip = saveFromClip; self.editCurve = editCurve
        self.useKeyframeEasing = useKeyframeEasing; self.delete = delete
    }
}

extension KeystonePalette {
    /// The header "...": Save Keystone from Selected Clip, and Apply for the selected keystone (`showOptions`).
    @MainActor public static func optionItems(selected: Keystone?, _ a: KeystonePaletteActions) -> [SQMenuItem] {
        var items = [SQMenuItem(title: "Save Keystone from Selected Clip\u{2026}", action: a.saveFromClip)]
        if let k = selected { items.append(SQMenuItem(title: "Apply to Selected Clip", action: { a.apply(k) })) }
        return items
    }

    /// The row menu (`contextItems(row:)`): Apply, Edit Curve, Use Keyframe Easing, Save, and Delete Keystone / Reset to
    /// Built-in last for a keystone the user saved or changed (`canDelete`).
    @MainActor public static func contextItems(for k: Keystone?, canDelete: Bool, _ a: KeystonePaletteActions) -> [SQMenuItem] {
        let save = SQMenuItem(title: "Save Keystone from Selected Clip\u{2026}", action: a.saveFromClip)
        guard let k else { return [save] }
        var items: [SQMenuItem] = [
            SQMenuItem(title: "Apply to Selected Clip", action: { a.apply(k) }),
            .separator,
            SQMenuItem(title: "Edit Curve\u{2026}", action: { a.editCurve(k) }),
            SQMenuItem(title: "Use Keyframe Easing", isEnabled: k.easing != nil, action: { a.useKeyframeEasing(k) }),
            .separator,
            save,
        ]
        if canDelete {
            items.append(.separator)    // destructive entry last
            items.append(SQMenuItem(title: k.isBuiltIn ? "Reset to Built-in" : "Delete Keystone", action: { a.delete(k) }))
        }
        return items
    }
}
