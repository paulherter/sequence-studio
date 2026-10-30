import Foundation
import SQCore
import SQUIKit
import SQDrawKit

/// Shows one SQMenu inside the window: one `MenuListView` per open level, driven by `SQMenuNavigator`. `SQMenuController`
/// translated: the navigator, placement (`SQMenuLayout.placement`, `submenuTop`, `origin`) and the release rule
/// (`SQMenuReleaseRule`) are the Mac ones; floating panels become levels drawn on top of the window, event monitors become
/// `handle(_:)`. Window points, y down; the Mac math is y up, so `flip` converts at the boundary.
@MainActor
public final class MenuController {
    private var nav = SQMenuNavigator(items: [])
    public private(set) var views: [MenuListView] = []
    /// The control the menu dropped from (window points): a press on it closes the menu and goes no further.
    private var anchorRect: CGRect?
    private var anchorTop: CGFloat?
    private var anchor: CGPoint = .zero
    private var openedAt: TimeInterval = 0
    private var openPoint: CGPoint = .zero
    private var pressedInList = false
    private var keyboardMove = false
    /// Window size in points (the "screen" the menu must stay inside).
    public var bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
    /// Other areas of the canvas a menu may open in (the floating windows' rectangles): a menu opened at a point inside one
    /// stays inside it, so the window that was clicked shows it.
    public var regions: [CGRect] = []
    private var region: CGRect?
    public var measure = TextMeasure(atlas: nil, scale: 1)
    /// Seconds clock for the release rule (tests set it).
    public var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Runs a chosen row's action after the menu closed (the host may defer it past the current event).
    public var run: (@MainActor (@escaping @MainActor () -> Void) -> Void) = { $0() }
    /// Called when the menu closes (the menu bar clears its open title).
    public var onDismiss: (@MainActor () -> Void)?
    /// Left/Right at the root level with no submenu to open or close: the menu bar moves to the neighbor menu.
    public var onSideKey: (@MainActor (_ right: Bool) -> Void)?

    public init() {}

    public var isOpen: Bool { !views.isEmpty }
    public var depth: Int { nav.depth }
    /// The rows of the open root level (empty when closed): what a right-click showed, for tests and the parity shots.
    public var rootItems: [SQMenuItem] { isOpen ? nav.items(level: 0) : [] }

    /// Shows `items` with the top-left corner at `point`. `anchorTop` (the control's top edge) lets the menu flip above it.
    public func present(items: [SQMenuItem], at point: CGPoint, anchor rect: CGRect? = nil, anchorTop: CGFloat? = nil, pointer: CGPoint? = nil) {
        dismiss(notify: false)
        guard !items.isEmpty else { return }
        anchorRect = rect
        region = regions.first { $0.contains(pointer ?? point) }
        nav = SQMenuNavigator(items: items)
        openedAt = clock()
        pressedInList = false
        openPoint = pointer ?? point
        self.anchorTop = anchorTop
        anchor = point
        sync()
    }

    /// SQ rows below a control (a pull-down), top-left at its lower-left corner (`SQContextMenu.popUp(items:below:)`).
    public func popUp(items: [SQMenuItem], below control: CGRect, pointer: CGPoint? = nil) {
        present(items: items, at: CGPoint(x: control.minX, y: control.maxY), anchor: control, anchorTop: control.minY, pointer: pointer)
    }

    public func dismiss() { dismiss(notify: true) }

    private func dismiss(notify: Bool) {
        let was = isOpen
        anchorRect = nil
        region = nil
        views = []
        if was, notify { onDismiss?() }
    }

    // MARK: Levels follow the navigator

    private func flip(_ y: CGFloat) -> CGFloat { screen.maxY - y + screen.minY }
    private var screen: CGRect { region ?? bounds }

    private func sync() {
        while views.count > nav.depth { views.removeLast() }
        for level in 0..<nav.depth {
            let items = nav.items(level: level)
            if level >= views.count { addLevel(level, items: items) }
            else if views[level].items != items || views[level].filter != nav.filter(level: level) {
                views[level].filter = nav.filter(level: level)
                views[level].items = items
                views[level].relayout(measure)
            }
            views[level].highlighted = nav.highlighted(level: level)
            if let h = views[level].highlighted, keyboardMove { views[level].reveal(row: h) }
        }
        keyboardMove = false
    }

    private func addLevel(_ level: Int, items: [SQMenuItem]) {
        var view = MenuListView(items: items)
        view.maxHeight = SQMenuLayout.maxHeight(screen: screen)
        if level == 0, anchorRect != nil, !items.contains(where: { $0.submenu != nil }) {
            view.maxHeight = min(view.maxHeight ?? .greatestFiniteMagnitude, SQMenuLayout.listCapHeight)
        }
        view.relayout(measure)
        if level == 0 {
            let content = CGSize(width: view.contentSize.width, height: min(view.contentSize.height, view.maxHeight ?? .greatestFiniteMagnitude))
            let r = SQMenuLayout.placement(content: content, anchor: CGPoint(x: anchor.x, y: flip(anchor.y)),
                                           anchorTop: anchorTop.map(flip), screen: screen)
            view.maxHeight = min(r.height, view.maxHeight ?? r.height)
            view.relayout(measure)
            view.origin = CGPoint(x: r.minX, y: flip(r.maxY))
        } else {
            // Submenu: right of the parent at the parent row, flipped to the left when it does not fit.
            let parent = views[level - 1]
            let row = parent.rowFrames[nav.highlighted(level: level - 1) ?? 0]
            let size = view.visibleSize
            let topY = SQMenuLayout.submenuTop(parentMaxY: flip(parent.frame.minY), rowMinY: row.minY, parentScroll: parent.scrollOffset)
            var o = SQMenuLayout.origin(size: size, anchor: CGPoint(x: parent.frame.maxX - 3, y: topY), screen: screen)
            if parent.frame.maxX - 3 + size.width > screen.maxX { o.x = max(screen.minX, parent.frame.minX - size.width + 3) }
            view.origin = CGPoint(x: o.x, y: flip(o.y + size.height))
        }
        views.append(view)
    }

    // MARK: Events

    private func levelAndRow(_ p: CGPoint) -> (level: Int, row: Int?)? {
        for level in views.indices.reversed() where views[level].frame.contains(p) {
            return (level, views[level].index(at: p))
        }
        return nil
    }

    private func onAnchor(_ p: CGPoint) -> Bool { anchorRect?.contains(p) ?? false }

    /// Feeds one window event (points). True when the menu took it; a press outside closes the menu and returns false so the
    /// press still reaches its target, except on the control the menu came from.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        guard isOpen else { return false }
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)) }
        switch e {
        case .keyDown(let k, let m):
            handleKey(k, m); return true
        case .mouseMoved(let x, let y), .mouseDragged(let x, let y):
            if let hit = levelAndRow(pt(x, y)) {
                // Same row whose submenu is already open: leave it alone.
                if nav.depth > hit.level + 1, nav.highlighted(level: hit.level) == hit.row { return true }
                nav.hover(hit.row, level: hit.level)
                if let r = hit.row, nav.items(level: hit.level)[r].submenu != nil { _ = nav.activate() }
                sync()
            }
            return true
        case .mouseDown(let x, let y, _):
            let p = pt(x, y)
            if levelAndRow(p) != nil { pressedInList = true; return true }
            let anchored = onAnchor(p)
            dismiss()
            return anchored
        case .mouseUp(let x, let y):
            let p = pt(x, y)
            let hit = levelAndRow(p)
            let outcome = SQMenuReleaseRule.outcome(pressedInList: pressedInList, overRow: hit?.row != nil, overAnchor: onAnchor(p),
                                                   moved: hypot(p.x - openPoint.x, p.y - openPoint.y), held: clock() - openedAt)
            pressedInList = false
            switch outcome {
            case .activate: if let hit, let r = hit.row { nav.hover(r, level: hit.level); activate() }
            case .dismiss: dismiss()
            case .ignore: break
            }
            return true
        case .scroll(let x, let y, _, let dy, _):
            let p = pt(x, y)
            if let level = views.indices.reversed().first(where: { views[$0].frame.contains(p) }) ?? views.indices.last {
                views[level].scroll(by: -CGFloat(dy / scale))
            }
            return true
        }
    }

    private func handleKey(_ k: InputKey, _ m: InputModifiers) {
        keyboardMove = true
        switch k {
        case .down: nav.move(.down)
        case .up: nav.move(.up)
        case .home: nav.move(.first)
        case .end: nav.move(.last)
        case .pageUp: nav.move(.first)
        case .pageDown: nav.move(.last)
        case .right: if nav.rightKey() == .none, nav.depth == 1 { onSideKey?(true); return }
        case .left:
            if !nav.leftKey() {
                if let side = onSideKey { side(false) } else { dismiss() }
                return
            }
        case .enter, .space: activate(); return
        case .escape: if nav.clearFilter() { break }; dismiss(); return
        case .backspace: nav.deleteFilterCharacter()
        case .character(let c):
            if !m.contains(.command), c.isLetter || c.isNumber { nav.typeFilter(c) }
        case .plus, .minus, .delete, .function: break
        }
        sync()
    }

    private func activate() {
        switch nav.activate() {
        case .none: break
        case .openedSubmenu: sync()
        case .run(let path):
            let action = nav.item(at: path)?.action
            dismiss()
            if let action { run(action) }
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        for v in views { v.draw(&c, theme: theme) }
    }
}
