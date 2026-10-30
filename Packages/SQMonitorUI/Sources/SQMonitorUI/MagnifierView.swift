import AppKit
import SQUIKit

/// The loupe next to the pointer while a color pick is active: the pixels around it enlarged, the center cell
/// outlined, and its 8-bit RGB under it. Never takes clicks; sits above the picture in the Program monitor.
@MainActor
public final class MagnifierView: NSView {
    static let cell: CGFloat = 10
    static let padding: CGFloat = Theme.Spacing.sm
    static let readoutHeight: CGFloat = 16
    /// Offset of the loupe from the pointer, so it never covers the pixel being picked.
    static let pointerGap: CGFloat = 18

    private static let pixelSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public var grid:MagnifierGrid? { didSet { needsDisplay = true } }
    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Size of the loupe for a grid.
    public static func size(for grid: MagnifierGrid) -> CGSize {
        CGSize(width: CGFloat(grid.width) * cell + 2 * padding,
               height: CGFloat(grid.height) * cell + 2 * padding + readoutHeight)
    }

    /// Frame of the loupe for a pointer position: below and right of it, flipped to the other side near an edge of `bounds`.
    public static func frame(size: CGSize, pointer: CGPoint, in bounds: CGRect) -> CGRect {
        var x = pointer.x + pointerGap, y = pointer.y + pointerGap
        if x + size.width > bounds.maxX { x = pointer.x - pointerGap - size.width }
        if y + size.height > bounds.maxY { y = pointer.y - pointerGap - size.height }
        x = min(max(x, bounds.minX), max(bounds.maxX - size.width, bounds.minX))
        y = min(max(y, bounds.minY), max(bounds.maxY - size.height, bounds.minY))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let grid, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        Theme.Colors.panel.setFill(); body.fill()
        Theme.Colors.fieldEdge.setStroke(); body.stroke()
        for y in 0..<grid.height {
            for x in 0..<grid.width {
                let b = FrameSampler.display8(grid.linear[y * grid.width + x])
                // Picture data, not a UI color.
                let rgb = [CGFloat(b.x) / 255, CGFloat(b.y) / 255, CGFloat(b.z) / 255, 1]
                if let c = CGColor(colorSpace: Self.pixelSpace, components: rgb) { ctx.setFillColor(c) }
                ctx.fill(CGRect(x: Self.padding + CGFloat(x) * Self.cell, y: Self.padding + CGFloat(y) * Self.cell,
                                width: Self.cell, height: Self.cell))
            }
        }
        let mid = NSRect(x: Self.padding + CGFloat(grid.centerX) * Self.cell, y: Self.padding + CGFloat(grid.centerY) * Self.cell,
                         width: Self.cell, height: Self.cell)
        Theme.Colors.fieldEdge.setStroke(); NSBezierPath(rect: mid.insetBy(dx: -0.5, dy: -0.5)).stroke()
        Theme.Colors.label.setStroke(); NSBezierPath(rect: mid.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let text = NSAttributedString(string: grid.readout, attributes: [.font: Theme.Typography.ns(10, .regular),
                                                                         .foregroundColor: Theme.Colors.label])
        let size = text.size()
        text.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(),
                              y: Self.padding + CGFloat(grid.height) * Self.cell + (Self.readoutHeight - size.height) / 2))
    }
}
