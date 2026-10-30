import Foundation
import SQDrawKit
import SQUIKit

/// What a window point is to the system (Windows `WM_NCHITTEST`): our own drawn chrome tells the window manager where
/// the drag area, the resize edges and the caption buttons are.
public enum WindowHit: Equatable, Sendable {
    case client, caption, minimize, maximize, close
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
}

/// The window buttons of a window without a system caption (Windows): Minimize, Maximize/Restore and Close at the
/// right end of the menu row, plus the hit test that makes the rest of the top rows a drag area and the window's
/// edges resize handles. Portable: the Win32 code only maps `WindowHit` to its HT codes.
@MainActor
public final class CaptionRowHost {
    public enum Button: CaseIterable, Sendable { case minimize, maximize, close }
    /// The menu row's height (points); the window buttons are as tall.
    public static let height: CGFloat = 32
    /// Windows 11 caption buttons are 46 points wide.
    public static let buttonWidth: CGFloat = 46
    /// The invisible resize band inside the window's edges (points); none while maximized.
    public static let resizeBand: CGFloat = 6
    /// Room kept free for dragging between the menu titles and the buttons (points).
    public static let dragRoom: CGFloat = 48

    public private(set) var frames: [Button: CGRect] = [:]
    /// Maximized: Restore shows instead of Maximize and the edges do not resize.
    public var isMaximized = false
    public var onButton: (@MainActor (Button) -> Void)?
    public private(set) var hovered: Button?
    public private(set) var pressed: Button?

    public init() {}

    /// The buttons' left end: the menu titles stop `dragRoom` before it.
    public var buttonsMinX: CGFloat { frames[.minimize]?.minX ?? 0 }

    /// The menu titles' room from `x` (points) in a window `width` points wide.
    public static func menuRoom(from x: CGFloat, width: CGFloat) -> CGFloat {
        max(width - 3 * buttonWidth - dragRoom - x, 0)
    }

    public func layout(width: CGFloat, top: CGFloat = 0, height: CGFloat = CaptionRowHost.height) {
        var x = width
        for b in Button.allCases.reversed() {
            x -= Self.buttonWidth
            frames[b] = CGRect(x: x, y: top, width: Self.buttonWidth, height: height)
        }
    }

    /// What `p` (points) is in a window of `size`: the edges resize (unless maximized), the buttons are buttons, the
    /// top `captionHeight` drags except over `controls` (menu titles, the title row's popups and the page switch).
    public func hit(_ p: CGPoint, size: CGSize, captionHeight: CGFloat, controls: [CGRect]) -> WindowHit {
        if !isMaximized {
            let b = Self.resizeBand, corner = 2 * Self.resizeBand
            let l = p.x < b, r = p.x >= size.width - b, t = p.y < b, bt = p.y >= size.height - b
            let lc = p.x < corner, rc = p.x >= size.width - corner, tc = p.y < corner, bc = p.y >= size.height - corner
            if (t && lc) || (l && tc) { return .topLeft }
            if (t && rc) || (r && tc) { return .topRight }
            if (bt && lc) || (l && bc) { return .bottomLeft }
            if (bt && rc) || (r && bc) { return .bottomRight }
            if l { return .left }
            if r { return .right }
            if t { return .top }
            if bt { return .bottom }
        }
        if let b = button(at: p) {
            switch b {
            case .minimize: return .minimize
            case .maximize: return .maximize
            case .close: return .close
            }
        }
        guard p.y < captionHeight, p.y >= 0 else { return .client }
        return controls.contains { $0.contains(p) } ? .client : .caption
    }

    public func button(at p: CGPoint) -> Button? { Button.allCases.first { frames[$0]?.contains(p) == true } }

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        for b in Button.allCases {
            guard let r = frames[b] else { continue }
            let active = pressed == b || (pressed == nil && hovered == b)
            var ink = t.label2
            if active {
                if b == .close {
                    c.fill(r, pressed == b ? t.red.lifted(-0.1) : t.red)
                    ink = .white
                } else {
                    c.fill(r, pressed == b ? t.fillPressed : t.fillHover)
                }
            }
            let icon: SQIcon = switch b {
            case .minimize: .minus
            case .maximize: isMaximized ? .copy : .roundedSquare
            case .close: .close
            }
            let size: CGFloat = b == .close ? 16 : 14
            c.draw(icon: icon, at: CGPoint(x: (r.midX - size / 2).rounded(), y: (r.midY - size / 2).rounded()), size: size, ink)
        }
    }

    /// Hover, press and release on the buttons (events in pixels); a release over the pressed button fires it.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        let k = CGFloat(max(scale, 0.01))
        func at(_ x: Float, _ y: Float) -> Button? { button(at: CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)) }
        switch e {
        case .mouseMoved(let x, let y):
            hovered = at(x, y)
            return false
        case .mouseDown(let x, let y, let m):
            guard !m.contains(.secondary), let b = at(x, y) else { return false }
            pressed = b
            return true
        case .mouseDragged(let x, let y):
            guard pressed != nil else { return false }
            hovered = at(x, y)
            return true
        case .mouseUp(let x, let y):
            guard let b = pressed else { return false }
            pressed = nil
            if at(x, y) == b { onButton?(b) }
            return true
        default:
            return false
        }
    }
}
