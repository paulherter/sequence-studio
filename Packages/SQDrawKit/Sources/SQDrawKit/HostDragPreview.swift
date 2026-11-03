import Foundation
import SQUIKit

/// The chip that follows the pointer while something is dragged out of a panel (a clip or file from the Project panel, an
/// effect, a preset, a library file): a small icon and the name. Every panel drag publishes here from its first move, and the
/// host draws it once after all the panels, so each drag source gets the preview without drawing its own.
public final class HostDragPreview: @unchecked Sendable {
    public struct Item: Equatable, Sendable {
        public var title: String
        public var icon: SQIcon
        /// The pointer in window points.
        public var point: CGPoint
    }

    public static let shared = HostDragPreview()
    @TaskLocal public static var current: HostDragPreview = shared

    public private(set) var item: Item?

    public init() {}

    /// A drag moved: show the chip at `point` (window points). An empty title shows nothing.
    public func show(title: String, icon: SQIcon, at point: CGPoint) {
        item = title.isEmpty ? nil : Item(title: title, icon: icon, point: point)
    }

    /// The drag ended or was canceled.
    public func clear() { item = nil }

    static let height: CGFloat = 24, maxWidth: CGFloat = 240, iconSize: CGFloat = 14

    /// The chip's frame for a pointer at `p` and a title `textWidth` wide: down and right of the pointer, so it never hides the target.
    static func frame(pointer p: CGPoint, textWidth: CGFloat) -> CGRect {
        let w = min(textWidth + iconSize + 8 + 8 + 6, maxWidth)
        return CGRect(x: p.x + 12, y: p.y + 8, width: w, height: height)
    }

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        guard let d = item else { return }
        let fs = CGFloat(DrawTheme.TypeSize.body)
        let r = Self.frame(pointer: d.point, textWidth: c.size(of: d.title, fontSize: fs).width)
        c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.small), t.panel)
        c.stroke(roundedRect: r, radius: CGFloat(DrawTheme.Radius.small), width: 1, t.accent)
        c.draw(icon: d.icon, at: CGPoint(x: r.minX + 8, y: r.midY - Self.iconSize / 2), size: Self.iconSize, t.label2)
        let text = CGRect(x: r.minX + 8 + Self.iconSize + 6, y: r.minY, width: r.width - (8 + Self.iconSize + 6), height: r.height)
        c.draw(d.title, in: text, fontSize: fs, t.label, inset: 0)
    }
}
