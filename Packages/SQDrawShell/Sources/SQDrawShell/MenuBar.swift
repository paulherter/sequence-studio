import Foundation
import SQCore
import SQUIKit
import SQDrawKit

/// The in-window menu bar of the Windows app: the Mac main menu (`ShellMenuBar.build`) as a row of titles, each opening its
/// SQMenu below it (the Mac shows the same trees in the system bar). Usual menu bar behavior: a click opens or closes a menu,
/// moving over another title while one is open switches to it, Left/Right at the root switch menus, Alt alone focuses the bar
/// (the host sends `altTapped()`), Esc closes.
@MainActor
public final class MenuBar {
    public static let defaultHeight: CGFloat = 28
    /// Bar height in points: 28 alone, or the host's title bar height when the titles sit in it (Windows: the 44 pt top bar).
    public var height: CGFloat = MenuBar.defaultHeight { didSet { layoutTitles() } }
    /// False when the bar sits on a title bar the host already painted: no fill, no bottom edge.
    public var drawsBackground = true
    /// False on the Mac: the shared menus live in the system menu bar (`SharedUIMainMenu`), the window shows no titles.
    /// The controller still opens the bar's popups (the Workspace popup).
    public var showsTitles = true { didSet { layoutTitles() } }
    static let titlePad: CGFloat = 10
    static let fontSize: CGFloat = 12

    public var menus: [ShellMenu] = [] { didSet { layoutTitles() } }
    public let controller = MenuController()
    public private(set) var titleFrames: [CGRect] = []
    public private(set) var open: Int?
    public var origin: CGPoint = .zero { didSet { layoutTitles() } }
    /// Room for the titles from `origin.x` (points); nil = unlimited. Titles that do not fit fold into the overflow
    /// title ("»"), whose menu lists them as submenus (a narrow Windows window).
    public var maxWidth: CGFloat? { didSet { if maxWidth != oldValue { layoutTitles() } } }
    /// The overflow title while some titles are folded; its index for `openMenu` is `titleFrames.count`.
    public private(set) var overflowFrame: CGRect?
    static let overflowTitle = "»"
    public var measure: TextMeasure { get { controller.measure } set { controller.measure = newValue; layoutTitles() } }
    /// Rebuilds the menus right before one opens (state such as Undo names and recents changes all the time).
    public var refresh: (@MainActor () -> [ShellMenu])?

    public init() {
        controller.onDismiss = { [weak self] in self?.open = nil }
        controller.onSideKey = { [weak self] right in self?.step(right ? 1 : -1) }
    }

    private func layoutTitles() {
        overflowFrame = nil
        guard showsTitles else { titleFrames = []; return }
        var x = origin.x + 4
        let all = menus.map { m -> CGRect in
            let w = measure.width(m.title, size: Self.fontSize) + 2 * Self.titlePad
            defer { x += w }
            return CGRect(x: x, y: origin.y, width: w, height: height)
        }
        guard let maxWidth, let last = all.last, last.maxX > origin.x + maxWidth else { titleFrames = all; return }
        let moreW = measure.width(Self.overflowTitle, size: Self.fontSize) + 2 * Self.titlePad
        let limit = origin.x + maxWidth - moreW
        titleFrames = Array(all.prefix { $0.maxX <= limit })
        overflowFrame = CGRect(x: titleFrames.last?.maxX ?? origin.x + 4, y: origin.y, width: moreW, height: height)
    }

    /// The menus folded into the overflow title.
    var foldedMenus: ArraySlice<ShellMenu> { overflowFrame == nil ? [] : menus.dropFirst(titleFrames.count) }

    /// The title under `p`: an index into `menus`, or `titleFrames.count` for the overflow title.
    public func title(at p: CGPoint) -> Int? {
        if let i = titleFrames.firstIndex(where: { $0.contains(p) }) { return i }
        return overflowFrame?.contains(p) == true ? titleFrames.count : nil
    }

    /// The number of titles a click or Left/Right can open (the overflow title counts as one).
    var openableCount: Int { titleFrames.count + (overflowFrame == nil ? 0 : 1) }

    public func openMenu(_ i: Int, pointer: CGPoint? = nil, highlightFirst: Bool = false) {
        if let refresh { menus = refresh() }
        if let more = overflowFrame, i == titleFrames.count {
            open = i
            controller.popUp(items: foldedMenus.map { SQMenuItem(title: $0.title, submenu: $0.items) }, below: more, pointer: pointer)
            open = i
            if highlightFirst { _ = controller.handle(.keyDown(.down, modifiers: []), scale: 1) }
            return
        }
        guard menus.indices.contains(i), titleFrames.indices.contains(i) || !showsTitles else { return }
        open = i
        controller.popUp(items: menus[i].items, below: titleFrames.indices.contains(i) ? titleFrames[i] : .zero, pointer: pointer)
        open = i   // `present` dismisses the previous menu first, which cleared `open`
        if highlightFirst { _ = controller.handle(.keyDown(.down, modifiers: []), scale: 1) }
    }

    /// Alt pressed and released alone: opens the first menu with its first row highlighted (keyboard menu access).
    public func altTapped() {
        if open != nil { controller.dismiss() } else { openMenu(0, highlightFirst: true) }
    }

    private func step(_ d: Int) {
        let n = showsTitles ? openableCount : menus.count
        guard let o = open, n > 0 else { return }
        openMenu((o + d + n) % n, highlightFirst: true)
    }

    /// True when the bar or its open menu took the event.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)) }
        switch e {
        case .mouseDown(let x, let y, _):
            let p = pt(x, y)
            if let i = title(at: p) {
                if open == i { controller.dismiss() } else { openMenu(i, pointer: p) }
                return true
            }
        case .mouseMoved(let x, let y), .mouseDragged(let x, let y):
            if let o = open, let i = title(at: pt(x, y)), i != o { openMenu(i, pointer: pt(x, y)); return true }
        default: break
        }
        return controller.handle(e, scale: scale)
    }

    public func draw(_ c: inout Canvas, theme t: DrawTheme, width: CGFloat) {
        if drawsBackground {
            c.fill(CGRect(x: origin.x, y: origin.y, width: width, height: height), t.titlebar)
            c.fill(CGRect(x: origin.x, y: origin.y + height - 1, width: width, height: 1), t.separator)
        }
        for (i, m) in menus.enumerated() where titleFrames.indices.contains(i) {
            let r = titleFrames[i]
            if open == i { c.fill(roundedRect: r.insetBy(dx: 0, dy: max(3, (r.height - 22) / 2)), radius: SQMenuLayout.rowRadius, t.fillHover) }
            c.draw(m.title, in: r, fontSize: Self.fontSize, t.label, align: .center)
        }
        if let r = overflowFrame {
            if open == titleFrames.count { c.fill(roundedRect: r.insetBy(dx: 0, dy: max(3, (r.height - 22) / 2)), radius: SQMenuLayout.rowRadius, t.fillHover) }
            c.draw(Self.overflowTitle, in: r, fontSize: Self.fontSize, t.label, align: .center)
        }
    }

    /// The open menu on top of everything (call last).
    public func drawMenus(_ c: inout Canvas, theme t: DrawTheme) { controller.draw(&c, theme: t) }
}
