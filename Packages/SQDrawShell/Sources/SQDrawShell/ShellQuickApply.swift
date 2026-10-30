import Foundation
import SQDrawKit
import SQEditorSession
import SQUIKit

/// The Quick Apply palette on the shared shell (the Mac `QuickApplyPanel`, Option+Space): a search field on top, the ranked
/// rows below (Recent first on an empty search). Up/Down move, Return applies, Escape or a press outside closes. For a
/// transition with selected clips Return swaps the content for a Start/End question (Left = start, Right = end, Down =
/// both, Return confirms, Escape goes back). The model (`QuickApplyModel`) is the Mac one; this only draws and reports.
/// shortcut: the palette sits at its default spot (no drag-to-move or remembered position like the Mac panel); add the
/// drag with `QuickApplyPlacement` when asked for.
@MainActor
public final class QuickApplyPopup {
    public static let width: CGFloat = 640
    static let headerHeight: CGFloat = 44
    static let rowHeight: CGFloat = 28
    static let maxRows = 8
    static let askHeight: CGFloat = 132
    static let emptyHeight: CGFloat = 72
    static let pad: CGFloat = 14
    static let buttonWidth: CGFloat = 100
    static let ends: [TransitionEnd] = [.start, .both, .end]

    public let model: QuickApplyModel
    /// Called after the palette closed, with the row the user confirmed.
    public var onChoose: ((QuickApplyItem, TransitionEnd?) -> Void)?
    /// Whether a transition can go to the start or end of selected clips (then Return asks which).
    public var canChooseTransitionEnd: () -> Bool = { false }
    public var onClose: (() -> Void)?
    public private(set) var frame: CGRect = .zero
    /// The index of the first visible row.
    public private(set) var scroll = 0
    var field = TextFieldControl()
    private var hoverRow: Int?
    private var hoverEnd: Int?
    private var window = CGRect.zero
    public var measure = TextMeasure(atlas: nil, scale: 1)

    public init(model: QuickApplyModel) {
        self.model = model
        field.alignment = .left
        field.dialogStyle = true
        field.fontSize = CGFloat(DrawTheme.TypeSize.display)
        field.placeholder = SQL10n.string("Apply effect, transition or preset")
        model.onChange = { [weak self] in self?.modelChanged() }
    }

    /// Opens with the last search selected (typing replaces it, Delete clears it), like the Mac panel.
    public func open(in window: CGRect) {
        model.reopen()
        field.text = model.query
        field.mouseDown()
        scroll = 0
        layout(in: window)
    }

    private var asking: QuickApplyItem? { model.pendingTransition }
    private var visibleRows: Int { min(model.results.count - scroll, Self.maxRows) }
    private var noResults: Bool {
        asking == nil && model.results.isEmpty && !model.query.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var height: CGFloat {
        if asking != nil { return Self.askHeight }
        let rows = min(model.results.count, Self.maxRows)
        return Self.headerHeight + (rows > 0 ? CGFloat(rows) * Self.rowHeight + 10 : noResults ? Self.emptyHeight : 0)
    }

    /// Centered, with the top edge 28 % below the window's top (the Mac default spot); the top stays put when it resizes.
    public func layout(in window: CGRect) {
        self.window = window
        let x = min(max(window.midX - Self.width / 2, window.minX + 8), max(window.maxX - Self.width - 8, window.minX + 8))
        frame = CGRect(x: x, y: window.minY + window.height * 0.28, width: Self.width, height: height)
    }

    private func modelChanged() {
        if let i = model.results.indices.contains(model.selectedIndex) ? model.selectedIndex : nil {
            if i < scroll { scroll = i } else if i >= scroll + Self.maxRows { scroll = i - Self.maxRows + 1 }
        } else { scroll = 0 }
        scroll = min(max(scroll, 0), max(model.results.count - Self.maxRows, 0))
        layout(in: window)
    }

    private var fieldRect: CGRect { CGRect(x: frame.minX + Self.pad, y: frame.minY + 6, width: frame.width - Self.pad * 2, height: 32) }
    private func rowRect(_ i: Int) -> CGRect {
        CGRect(x: frame.minX + 6, y: frame.minY + Self.headerHeight + CGFloat(i - scroll) * Self.rowHeight, width: frame.width - 12, height: Self.rowHeight)
    }
    private func endRect(_ i: Int) -> CGRect {
        CGRect(x: frame.midX - 160 + CGFloat(i) * 110, y: frame.minY + 52, width: Self.buttonWidth, height: 28)
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        guard frame.width > 0 else { return }
        let radius = CGFloat(DrawTheme.Radius.control)
        c.shadow(roundedRect: frame, radius: radius, blur: 24, dy: 8, DrawColor(0, 0, 0, 0.4), opaqueAbove: true)
        c.fill(roundedRect: frame, radius: radius, t.overlay)
        c.stroke(roundedRect: frame, radius: radius, width: 1, t.separator)
        if let item = asking {
            c.draw("\(item.title): " + SQL10n.string("add at the start, the end or both ends of the selected clips"),
                   in: CGRect(x: frame.minX + 16, y: frame.minY + 14, width: frame.width - 32, height: 20),
                   fontSize: CGFloat(DrawTheme.TypeSize.title), t.label, align: .center)
            for (i, end) in Self.ends.enumerated() {
                let title = end == .start ? "Start" : end == .end ? "End" : "Both"
                let on = model.transitionEnd == end
                let r = endRect(i)
                c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), on ? t.accentFill : (hoverEnd == i ? t.fillHover : t.fill))
                c.draw(SQL10n.string(title), in: r, fontSize: CGFloat(DrawTheme.TypeSize.body), on ? .white : t.label, align: .center)
            }
            c.draw(SQL10n.string("Left = start, Right = end, Down = both, Return confirms, Esc goes back"),
                   in: CGRect(x: frame.minX + 16, y: frame.maxY - 28, width: frame.width - 32, height: 16),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2, align: .center)
            return
        }
        field.draw(&c, in: fieldRect, theme: t, focused: true)
        let rows = min(model.results.count, Self.maxRows)
        if rows > 0 || noResults { c.fill(CGRect(x: frame.minX, y: frame.minY + Self.headerHeight - 1, width: frame.width, height: 1), t.separator) }
        if noResults {
            let r = CGRect(x: frame.minX, y: frame.minY + Self.headerHeight, width: frame.width, height: Self.emptyHeight)
            c.draw(SQL10n.string("No results"), in: CGRect(x: r.minX, y: r.minY + 12, width: r.width, height: 20),
                   fontSize: CGFloat(DrawTheme.TypeSize.title), t.label, align: .center)
            c.draw(SQL10n.string("Try another name, or press Esc to close."), in: CGRect(x: r.minX, y: r.minY + 34, width: r.width, height: 16),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2, align: .center)
        }
        for i in scroll..<(scroll + max(visibleRows, 0)) {
            let item = model.results[i]
            let r = rowRect(i)
            let active = i == model.selectedIndex
            if active { c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.small), t.accentFill) }
            else if hoverRow == i { c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.small), t.fillHover) }
            let kind = SQL10n.string(model.isRecentRow(item) ? "Recent" : item.category)
            let kindWidth = measure.width(kind, size: CGFloat(DrawTheme.TypeSize.body))
            c.draw(item.title, in: CGRect(x: r.minX + 10, y: r.minY, width: r.width - kindWidth - 40, height: r.height),
                   fontSize: CGFloat(DrawTheme.TypeSize.title), active ? .white : t.label)
            c.draw(kind, in: CGRect(x: r.maxX - kindWidth - 10, y: r.minY, width: kindWidth, height: r.height),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), active ? DrawColor.white.alpha(0.8) : t.label2, align: .right)
        }
    }

    // MARK: Events (window points; `scale` converts the event's pixels)

    /// True when the palette took the event (it is modal: a press outside closes it). Command/Option/Control keys go on to
    /// the shell, so Option+Space closes it again and the editing shortcuts keep working.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        let k = CGFloat(max(scale, 0.01))
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k) }
        switch e {
        case .mouseMoved(let x, let y):
            let p = pt(x, y)
            hoverRow = asking == nil && frame.contains(p) ? (scroll..<(scroll + max(visibleRows, 0))).first { rowRect($0).contains(p) } : nil
            hoverEnd = asking != nil ? Self.ends.indices.first { endRect($0).contains(p) } : nil
            return true
        case .mouseDown(let x, let y, _):
            let p = pt(x, y)
            guard frame.contains(p) else { onClose?(); return true }
            if asking != nil {
                if let i = Self.ends.indices.first(where: { endRect($0).contains(p) }) { model.chooseEnd(Self.ends[i]); confirm() }
            } else if let i = (scroll..<(scroll + max(visibleRows, 0))).first(where: { rowRect($0).contains(p) }) {
                model.select(i)
                confirm()
            }
            return true
        case .mouseDragged, .mouseUp:
            return true
        case .scroll(let x, let y, _, let dy, _):
            guard asking == nil, frame.contains(pt(x, y)) else { return true }
            let rowsPerPixel = 1 / Self.rowHeight / k
            scroll = min(max(scroll - Int((CGFloat(dy) * rowsPerPixel).rounded(.toNearestOrAwayFromZero)), 0), max(model.results.count - Self.maxRows, 0))
            return true
        case .keyDown(let key, let m):
            if !m.intersection([.command, .option, .secondary]).isEmpty { return false }
            return handleKey(key, modifiers: m)
        }
    }

    private func handleKey(_ key: InputKey, modifiers m: InputModifiers) -> Bool {
        let asking = self.asking != nil
        switch key {
        case .up where !asking: model.move(-1)
        case .down where !asking: model.move(1)
        case .left where asking: model.chooseEnd(.start)
        case .right where asking: model.chooseEnd(.end)
        case .down where asking: model.chooseEnd(.both)
        case .enter: confirm()
        case .escape: if asking { model.cancelEndChoice() } else { onClose?() }
        default:
            guard !asking else { return true }          // no typing while the question is up
            _ = field.key(key, modifiers: m)
            let q = field.editor?.string ?? field.text
            if !field.isEditing { field.text = q; field.mouseDown() }   // the field keeps the focus
            if q != model.query { model.query = q }
        }
        return true
    }

    private func confirm() {
        switch model.confirm(canChooseEnd: canChooseTransitionEnd()) {
        case .none: break
        case .askEnd: break
        case .apply(let item, let end):
            onClose?()
            onChoose?(item, end)
        }
    }
}
