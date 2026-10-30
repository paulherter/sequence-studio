import Foundation
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// A menu the tool strip asks the host to open (built with `ToolStrip.items`).
public enum ToolStripMenu: Equatable, Sendable {
    /// The hold / right-click variants of a slot (Slip, Create, Mask).
    case variants(TimelineTool)
    /// Every tool with its key and the dock choices (grip click, right-click on the bar).
    case allTools
}

public enum ToolStripAction: Equatable, Sendable {
    /// The picked tool state: the host hands it to the timeline panel.
    case setTool(ToolState)
    /// Open `menu` at `at` (window points).
    case menu(ToolStripMenu, at: CGPoint)
}

/// The tool bar on the shared toolkit, translated from the Mac `ToolStripView` and `ToolStripDockView`: the same
/// `ToolStripLayout` geometry and `ToolStripTools` list and menus. It docks left, right, above or below the timeline area
/// or floats over it; a grip drag moves it (dock zones light up), a click on the grip opens every tool, double-click puts
/// it back on the left. Holding a slot with variants (or a right press on it) opens its variants.
public struct ToolStrip: Sendable {
    public var theme: DrawTheme
    public var edge: ToolStripEdge
    public var visible: Bool
    /// Origin of the floating bar relative to the dock area.
    public var floatOrigin: CGPoint
    /// Read `ToolStripPrefs` on every layout (off while a grip drag runs, and in tests).
    public var followsPrefs = true
    public var clock: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }

    /// Dock area and bar in window points.
    public private(set) var area = CGRect.zero
    public private(set) var strip = CGRect.zero
    public private(set) var scale: Float = 1
    public private(set) var hovered: Int?

    enum Press: Equatable {
        case tool(Int, started: Double)
        case grip(start: CGPoint, moved: Bool)
        /// The hold menu opened: the release is ignored.
        case done
    }
    private(set) var press: Press?
    private var lastGripClick: Double?
    /// Edge the grip drag would dock to (the lit zone).
    public private(set) var dragTarget: ToolStripEdge?

    public static let holdDelay: Double = 0.45       // design v9: hold 450 ms
    static let doubleClickTime: Double = 0.5
    static let glyphSize: CGFloat = 16

    public init(theme: DrawTheme = DrawTheme()) {
        self.theme = theme
        edge = ToolStripPrefs.edge
        visible = ToolStripPrefs.visible
        floatOrigin = ToolStripPrefs.floatOrigin
    }

    var toolCount: Int { ToolStripTools.order.count }
    public var isDragging: Bool { press != nil }

    // MARK: Layout

    /// Lays the bar out in `rect` (device pixels) and returns the rect left for the timeline (device pixels).
    public mutating func layout(_ rect: DrawRect, scale s: Float) -> DrawRect {
        scale = s
        if followsPrefs, press == nil {
            edge = ToolStripPrefs.edge; visible = ToolStripPrefs.visible; floatOrigin = ToolStripPrefs.floatOrigin
        }
        let k = CGFloat(s)
        area = CGRect(x: CGFloat(rect.x) / k, y: CGFloat(rect.y) / k, width: CGFloat(rect.w) / k, height: CGFloat(rect.h) / k)
        let f = ToolStripLayout.frames(edge: edge, bounds: area, toolCount: toolCount,
                                       floatOrigin: CGPoint(x: area.minX + floatOrigin.x, y: area.minY + floatOrigin.y),
                                       visible: visible)
        strip = visible ? f.strip : .zero
        // Device-pixel edges: round the shared edge once so the bar and the timeline meet without a gap.
        let c = f.content
        let x0 = (Float(c.minX) * s).rounded(), x1 = (Float(c.maxX) * s).rounded()
        let y0 = (Float(c.minY) * s).rounded(), y1 = (Float(c.maxY) * s).rounded()
        return DrawRect(x: x0, y: y0, w: max(x1 - x0, 0), h: max(y1 - y0, 0))
    }

    /// Grip and tool rects in window points.
    public var slots: (grip: CGRect, tools: [CGRect]) {
        let s = ToolStripLayout.slots(edge: edge, toolCount: toolCount, size: strip.size)
        let o = strip.origin
        return (s.grip.offsetBy(dx: o.x, dy: o.y), s.tools.map { $0.offsetBy(dx: o.x, dy: o.y) })
    }

    public func contains(x: Float, y: Float) -> Bool {
        visible && strip.contains(CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)))
    }

    // MARK: Drawing

    /// Draws the bar (and the lit dock zone during a grip drag) in window points.
    public func draw(_ cv: inout Canvas, state: ToolState) {
        guard visible, strip.width > 0 else { return }
        let skin = TimelineSkin(theme: theme)
        if let t = dragTarget, let zone = ToolStripLayout.zone(t, in: area) {
            let box = zone.insetBy(dx: 2, dy: 2)
            cv.fill(roundedRect: box, radius: CGFloat(DrawTheme.Radius.small), skin.accentTint)
            cv.stroke(roundedRect: box, radius: CGFloat(DrawTheme.Radius.small), width: 1, theme.accent)
        }
        let b = strip
        if edge == .floating {
            // v9 `.tbar.floating`: raised fill, 1 pt strong line, small radius.
            let box = b.insetBy(dx: 0.5, dy: 0.5)
            cv.fill(roundedRect: box, radius: CGFloat(DrawTheme.Radius.small), theme.overlay)
            cv.stroke(roundedRect: box, radius: CGFloat(DrawTheme.Radius.small), width: 1, theme.trackHeaderLine)
        } else {
            cv.fill(b, theme.panel)
            switch edge {
            case .left: cv.fill(CGRect(x: b.maxX - 1, y: b.minY, width: 1, height: b.height), theme.separator)
            case .right: cv.fill(CGRect(x: b.minX, y: b.minY, width: 1, height: b.height), theme.separator)
            case .top: cv.fill(CGRect(x: b.minX, y: b.maxY - 1, width: b.width, height: 1), theme.separator)
            default: cv.fill(CGRect(x: b.minX, y: b.minY, width: b.width, height: 1), theme.separator)
            }
        }
        let s = slots
        // Grip: three dots in a row (v9 `i-gripx`); turned a quarter when the bar is a row.
        for i in -1...1 {
            let d = CGFloat(i) * 4.2
            let c = edge.isVertical ? CGPoint(x: s.grip.midX + d, y: s.grip.midY) : CGPoint(x: s.grip.midX, y: s.grip.midY + d)
            cv.fill(ellipseIn: CGRect(x: c.x - 1, y: c.y - 1, width: 2, height: 2), theme.label3)
        }
        for (i, tool) in ToolStripTools.order.enumerated() {
            let r = s.tools[i]
            let on = tool == state.tool
            // v9 `.tbar .ibtn`: 28 x 28, radius 6, picked = `fillPressed`, hover = `fillHover`.
            if on { cv.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), theme.fillPressed) }
            else if hovered == i { cv.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), theme.fillHover) }
            let g = Self.glyphSize
            cv.draw(icon: ToolStripTools.icon(tool, state: state), at: CGPoint(x: r.midX - g / 2, y: r.midY - g / 2), size: g,
                    on ? theme.label : theme.label2)
            guard ToolStripTools.hasVariants(tool) else { continue }
            // v9 `.grp::after`: 4 pt triangle, 4 pt in from the right and bottom, t3 (t1 on the picked tool).
            let m = r.insetBy(dx: 4, dy: 4), k: CGFloat = 4
            cv.fill(polygon: [CGPoint(x: m.maxX, y: m.maxY), CGPoint(x: m.maxX - k, y: m.maxY), CGPoint(x: m.maxX, y: m.maxY - k)],
                    on ? theme.label : theme.label3)
        }
    }

    // MARK: Input

    /// Handles one host event (device pixels); nil = not the strip's (the host passes it on).
    public mutating func handle(_ e: InputEvent, state: ToolState) -> [ToolStripAction]? {
        let k = CGFloat(scale)
        switch e {
        case .mouseDown(let x, let y, let mods):
            guard contains(x: x, y: y) else { return nil }
            return mouseDown(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k), secondary: mods.contains(.secondary), state: state)
        case .mouseDragged(let x, let y):
            guard press != nil else { return nil }
            return mouseDragged(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k))
        case .mouseUp(let x, let y):
            guard press != nil else { return nil }
            return mouseUp(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k), state: state)
        case .mouseMoved(let x, let y):
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            hovered = visible ? slots.tools.firstIndex { $0.contains(p) } : nil
            guard contains(x: x, y: y) else { return nil }
            HostHover.current.offerTip(tip(at: p, state: state))
            return []
        case .scroll(let x, let y, _, _, _):
            return contains(x: x, y: y) ? [] : nil
        case .keyDown:
            return nil
        }
    }

    /// The hold menu of a slot with variants once the press lasted `holdDelay`.
    public mutating func tick() -> [ToolStripAction] {
        guard case .tool(let i, let started)? = press, clock() - started >= Self.holdDelay else { return [] }
        press = .done
        return [variantsMenu(i)]
    }

    private func variantsMenu(_ i: Int) -> ToolStripAction {
        let r = slots.tools[i]
        return .menu(.variants(ToolStripTools.order[i]), at: CGPoint(x: r.minX, y: r.maxY))   // v9: below the tool
    }

    private mutating func mouseDown(_ p: CGPoint, secondary: Bool, state: ToolState) -> [ToolStripAction] {
        let s = slots
        if let i = s.tools.firstIndex(where: { $0.contains(p) }) {
            let tool = ToolStripTools.order[i]
            if secondary { return ToolStripTools.hasVariants(tool) ? [variantsMenu(i)] : [.menu(.allTools, at: p)] }
            press = .tool(i, started: clock())
            return []
        }
        if secondary { return [.menu(.allTools, at: p)] }
        guard s.grip.contains(p) else { return [] }
        let now = clock()
        if let l = lastGripClick, now - l <= Self.doubleClickTime {
            // v9: double-click puts it back on the left.
            lastGripClick = nil
            edge = .left
            if followsPrefs { ToolStripPrefs.edge = .left }
            return []
        }
        lastGripClick = now
        press = .grip(start: p, moved: false)
        return []
    }

    private mutating func mouseDragged(_ p: CGPoint) -> [ToolStripAction] {
        guard case .grip(let start, let moved)? = press else { return [] }
        if !moved, hypot(p.x - start.x, p.y - start.y) < 3 { return [] }
        press = .grip(start: start, moved: true)
        gripDrag(p, done: false)
        return []
    }

    private mutating func mouseUp(_ p: CGPoint, state: ToolState) -> [ToolStripAction] {
        defer { press = nil }
        switch press {
        case .tool(let i, _)?:
            guard slots.tools[i].contains(p) else { return [] }
            var s = state
            s.tool = ToolStripTools.order[i]
            return [.setTool(s)]
        case .grip(_, let moved)?:
            if moved { gripDrag(p, done: true); return [] }
            // A plain click on the dots: every tool, under the dots.
            let g = slots.grip
            return [.menu(.allTools, at: CGPoint(x: edge.isVertical ? g.maxX : g.minX, y: edge.isVertical ? g.minY : g.maxY))]
        default:
            return []
        }
    }

    /// `ToolStripDockView.gripDrag`: the bar follows the edge under the pointer; floating keeps the pointer on the grip.
    private mutating func gripDrag(_ p: CGPoint, done: Bool) {
        let target = ToolStripLayout.edge(for: p, in: area)
        if target == .floating {
            floatOrigin = CGPoint(x: p.x - area.minX - ToolStripLayout.floatPadding - ToolStripLayout.rowGripLength / 2,
                                  y: p.y - area.minY - ToolStripLayout.rowThickness / 2)
        }
        edge = target
        dragTarget = done ? nil : (ToolStripLayout.zone(target, in: area) == nil ? nil : target)
        if done, followsPrefs {
            ToolStripPrefs.floatOrigin = floatOrigin
            ToolStripPrefs.edge = target
        }
    }

    /// The items of `menu`; picking a tool calls `commit` with the new state.
    @MainActor
    public func items(_ menu: ToolStripMenu, state: ToolState, map: CommandMap = .current,
                      commit: @escaping @MainActor (ToolState) -> Void) -> [SQMenuItem] {
        switch menu {
        case .variants(let t): ToolStripTools.variantItems(t, state: state, commit: commit)
        case .allTools: ToolStripTools.allToolItems(state: state, edge: edge, map: map, commit: commit)
        }
    }
}
