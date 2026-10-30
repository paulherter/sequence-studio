import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// Floating panels of the shared app (the Mac `AppController+FloatingPanels`, `FloatingPanelState` and `FloatingPanelWindow`
/// translated): a dock panel popped out into a window of its own. The layout tree is not touched, a floating panel only
/// counts as hidden in the copy the dock lays out, so docking it back restores its exact slot. State is per workspace and
/// persisted next to `workspaces.json` (`floating-panels.json`, the same file the Mac app writes).
///
/// The panels draw into one shared canvas. A floating panel gets a rectangle on that canvas to the right of the main window
/// (`Window.rect`, points); the host opens an OS window per `windows` entry, shows `DrawList.region` of the frame at the
/// rectangle and sends the window's mouse events moved by the rectangle's origin. Everything else (title bar, Dock and
/// Close buttons, the panel hosts) is the one set of code the main window runs.
@MainActor
public final class ShellFloating {
    /// Height of the title row the shell draws (`SQFloatingPanel.titleBarHeight`).
    public static let titleBar: CGFloat = 28
    static let gap: CGFloat = 24
    static let button: CGFloat = 24
    /// The invisible resize handle in the bottom-right corner (a borderless window has no system resize edges).
    public static let grip: CGFloat = 16
    /// A tab released this far outside the window pops out (the Mac rule).
    static let tearOffMargin: CGFloat = 16
    static let saveDelay: TimeInterval = 0.5

    // shortcut: Program and Source share one monitor card (one picture), so only one of them shows its picture at a time:
    // the floating one wins (`ShellDock.monitorCard`), the other docked group shows a placeholder; upgrade with a card and
    // a picture per monitor.
    public static func canFloat(_ p: PanelID) -> Bool { PanelID.dockable.contains(p) }

    // MARK: Mixed DPI

    /// The scale the one frame is drawn at: the largest of the main window and the floating windows. A window on a display
    /// with a smaller scale shows the frame reduced (crisp); none shows it enlarged. One scale = no second frame pass, the
    /// panels keep one set of pixel positions.
    public static func drawScale(main: Float, floating: [Float]) -> Float { max(floating.max() ?? main, main) }

    /// Window scale over draw scale (1 when they agree or the draw scale is unknown).
    public static func ratio(window: Float, draw: Float) -> Float { draw > 0 ? window / draw : 1 }

    /// Size in the frame's pixels of a window extent given in the window's own pixels.
    public static func drawSize(_ own: Int, window: Float, draw: Float) -> Int {
        let r = ratio(window: window, draw: draw)
        return r > 0 ? Int((Float(own) / r).rounded()) : own
    }

    /// A coordinate in the window's own pixels, in the frame's pixels.
    public static func drawn(_ own: Float, window: Float, draw: Float) -> Float {
        let r = ratio(window: window, draw: draw)
        return r > 0 ? own / r : own
    }

    /// One floating window.
    public struct Window: Equatable {
        public var panel: PanelID
        public var title: String
        /// The OS window (screen points, y up, title row included).
        public var frame: CGRect
        /// Where it sits on the shared canvas (points, y down, title row included).
        public var rect: CGRect
    }

    public enum Hit: Equatable { case title(PanelID), dock(PanelID), close(PanelID), grip(PanelID), content(PanelID) }

    public private(set) var state: FloatingPanelState
    /// The floating windows of the workspace on screen, in panel order.
    public private(set) var windows: [Window] = []
    /// Counts every change of the window set or of a frame the shell chose (the host opens, closes and moves OS windows).
    public private(set) var revision = 0
    weak var dock: ShellDock?
    /// Frames from before Maximize Panel (the Mac `unzoomedFrame`): a second call puts the window back.
    private var unzoomed: [PanelID: CGRect] = [:]
    private var key = ""
    private var dirtyAt: TimeInterval?

    /// Visible frames of the displays (screen points, y up, the main display first).
    public var screens: () -> [CGRect] = { [] }
    /// The main window's frame (screen points, y up), nil when the host does not know it.
    public var mainScreenFrame: () -> CGRect? = { nil }
    /// Writes the state (`floating-panels.json`); nil = not saved (tests).
    public var save: (@MainActor (FloatingPanelState) -> Void)?
    public var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The host raises a panel's window (a shortcut or the Window menu asked for a floating panel).
    public var raise: (@MainActor (PanelID) -> Void)?

    public init(state: FloatingPanelState = FloatingPanelState()) { self.state = state }

    public func load(_ s: FloatingPanelState) { state = s; dock?.layout(); dock?.onChange?() }

    public var panels: Set<PanelID> { Set(windows.map(\.panel)) }
    public func isFloating(_ p: PanelID) -> Bool { windows.contains { $0.panel == p } }
    public func window(of p: PanelID) -> Window? { windows.first { $0.panel == p } }

    /// Canvas size the floating rectangles need, points (zero without windows).
    public var canvasExtent: CGSize {
        CGSize(width: windows.map(\.rect.maxX).max() ?? 0, height: windows.map(\.rect.maxY).max() ?? 0)
    }

    /// The dock's layout pass: picks the workspace's windows and places their rectangles right of `mainWidth` (points).
    func refresh(key: String, mainWidth: CGFloat) {
        self.key = key
        let clamp = screens()
        var next: [Window] = []
        var x = mainWidth + Self.gap
        for p in PanelID.allCases where Self.canFloat(p) {
            guard var f = state.frame(of: p, key: key)?.rect else { continue }
            let m = p.minSize
            f.size.width = max(f.width, CGFloat(m.width)); f.size.height = max(f.height, CGFloat(m.height) + Self.titleBar)
            if !clamp.isEmpty, old(p) == nil { f = FloatingPanelState.clamp(f, screens: clamp, titleBar: Self.titleBar) }
            let rect = CGRect(x: x, y: 0, width: f.width, height: f.height)
            x += f.width + Self.gap
            next.append(Window(panel: p, title: EditorCommand.localizedPanelTitle(p), frame: f, rect: rect))
        }
        if next.map(\.panel) != windows.map(\.panel) { revision += 1 }
        unzoomed = unzoomed.filter { k, _ in next.contains { $0.panel == k } }
        windows = next
    }

    private func old(_ p: PanelID) -> Window? { window(of: p) }

    // MARK: Actions

    /// Pops `p` out. Without a drop point the window opens at the dock size, offset from the dock position (the Mac
    /// `floatPanel`); with one (a tab dragged out of the window, screen points) its title row sits under the pointer.
    @discardableResult
    public func float(_ p: PanelID, at dropPoint: CGPoint? = nil) -> Bool {
        guard Self.canFloat(p), !isFloating(p), let dock else { return false }
        let bar = Self.titleBar
        var frame: CGRect
        if let dropPoint {
            frame = FloatingPanelState.tearOffFrame(for: p, at: dropPoint, titleBar: Double(bar)).rect
        } else {
            var current = CGRect(x: 0, y: 0, width: 520, height: 360)
            if let c = dock.contentFrame(p), let main = mainScreenFrame() {
                current = CGRect(x: main.minX + c.minX, y: main.maxY - c.maxY, width: c.width, height: c.height)
            }
            frame = FloatingPanelState.defaultFrame(for: p, current: current).rect
            frame.size.height += bar
            frame.origin.y -= bar
        }
        frame = FloatingPanelState.clamp(frame, screens: screens(), titleBar: bar)
        state.float(p, key: key, frame: FloatingPanelFrame(frame))
        if dock.maximized == p { dock.toggleMaximize(p) }
        markDirty()
        dock.focused = p
        changed()
        return true
    }

    /// Back into the layout, at the position it left.
    public func dockBack(_ p: PanelID) {
        guard isFloating(p) else { return }
        unzoomed[p] = nil
        state.dock(p, key: key)
        markDirty()
        dock?.focused = p
        changed()
    }

    /// Close Panel of a floating panel: not floating any more and hidden in the layout, like a docked one.
    public func close(_ p: PanelID) {
        guard isFloating(p) else { return }
        unzoomed[p] = nil
        state.dock(p, key: key)
        markDirty()
        dock?.close(p)
    }

    /// The user moved or resized the OS window (screen points, y up).
    public func setFrame(_ f: CGRect, of p: PanelID) {
        guard let i = windows.firstIndex(where: { $0.panel == p }), windows[i].frame != f else { return }
        let resized = windows[i].frame.size != f.size
        state.setFrame(FloatingPanelFrame(f), of: p, key: key)
        windows[i].frame = f
        markDirty()
        if resized { dock?.layout(); dock?.onChange?() }
    }

    public func isZoomed(_ p: PanelID) -> Bool { unzoomed[p] != nil }

    /// Maximize Panel on a floating panel (the Mac `toggleFloatingZoom`): the window fills the visible area of the display it
    /// is mostly on; a second call restores the frame from before. The host follows through `revision`.
    public func toggleZoom(_ p: PanelID) {
        guard let w = window(of: p) else { return }
        let target: CGRect
        if let back = unzoomed[p] {
            unzoomed[p] = nil
            target = back
        } else {
            let all = screens()
            let best = all.max { overlap($0, w.frame) < overlap($1, w.frame) }
            guard let visible = best else { return }
            unzoomed[p] = w.frame
            target = visible
        }
        setFrame(target, of: p)
        revision += 1
        dock?.focused = p
        raise?(p)
        dock?.onChange?()
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// A tab dragged out of the window floats (the pointer is `windowPoint`, window points, `window` the window size).
    func tearOff(_ p: PanelID, at windowPoint: CGPoint, window size: CGSize) -> Bool {
        guard Self.canFloat(p), !isFloating(p), let main = mainScreenFrame() else { return false }
        let m = Self.tearOffMargin
        guard !CGRect(origin: .zero, size: size).insetBy(dx: -m, dy: -m).contains(windowPoint) else { return false }
        return float(p, at: CGPoint(x: main.minX + windowPoint.x, y: main.maxY - windowPoint.y))
    }

    private func changed() {
        revision += 1
        dock?.layout()
        dock?.onChange?()
    }

    // MARK: Persistence

    private func markDirty() { dirtyAt = clock() }

    /// Writes the state once it has been quiet for half a second (a drag moves the window many times); `force` at quit.
    public func flush(force: Bool = false) {
        guard let at = dirtyAt, force || clock() - at >= Self.saveDelay else { return }
        dirtyAt = nil
        save?(state)
    }

    // MARK: Geometry and events

    func titleRect(_ w: Window) -> CGRect { CGRect(x: w.rect.minX, y: w.rect.minY, width: w.rect.width, height: Self.titleBar) }
    func closeRect(_ w: Window) -> CGRect {
        let s = Self.button
        return CGRect(x: w.rect.maxX - 6 - s, y: w.rect.minY + (Self.titleBar - s) / 2, width: s, height: s)
    }
    func dockRect(_ w: Window) -> CGRect { closeRect(w).offsetBy(dx: -Self.button, dy: 0) }
    func gripRect(_ w: Window) -> CGRect {
        CGRect(x: w.rect.maxX - Self.grip, y: w.rect.maxY - Self.grip, width: Self.grip, height: Self.grip)
    }

    /// What lies under a canvas point (points), nil outside every floating rectangle.
    public func hit(at p: CGPoint) -> Hit? {
        guard let w = windows.first(where: { $0.rect.contains(p) }) else { return nil }
        if closeRect(w).contains(p) { return .close(w.panel) }
        if dockRect(w).contains(p) { return .dock(w.panel) }
        if gripRect(w).contains(p) { return .grip(w.panel) }
        if titleRect(w).contains(p) { return .title(w.panel) }
        return .content(w.panel)
    }

    /// The press on a title row button; true when the press belonged to the title row (the OS drags the window by it).
    func press(at p: CGPoint) -> Bool {
        switch hit(at: p) {
        case .dock(let panel)?: dockBack(panel); return true
        case .close(let panel)?: close(panel); return true
        case .title?: return true
        default: return false
        }
    }

    /// The title row of one window: the Mac `FloatingPanelTitleBar`.
    func drawTitle(_ c: inout Canvas, _ w: Window, theme t: DrawTheme, focused: Bool) {
        let bar = titleRect(w)
        c.fill(bar, t.titlebar)
        c.fill(CGRect(x: bar.minX, y: bar.maxY - 1, width: bar.width, height: 1), t.divider)
        let pad = CGFloat(DrawTheme.Spacing.md)
        let text = CGRect(x: bar.minX + pad, y: bar.minY, width: max(dockRect(w).minX - bar.minX - pad - CGFloat(DrawTheme.Spacing.sm), 0), height: bar.height)
        c.draw(w.title, in: text, fontSize: 11, focused ? t.label : t.label2, face: c.semibold)
        for (r, icon) in [(dockRect(w), SQIcon.minimize), (closeRect(w), SQIcon.close)] {
            let s: CGFloat = 14
            c.draw(icon: icon, at: CGPoint(x: r.midX - s / 2, y: r.midY - s / 2), size: s, t.label2)
        }
    }
}
