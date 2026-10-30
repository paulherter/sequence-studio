import Foundation
import SQDrawKit

/// The loupe next to the pointer while the eyedropper samples (the Mac `MagnifierView` / `MagnifierGrid` on the draw
/// list): the pixels around the pointer enlarged, the center cell outlined and its 8-bit RGB under it. The host fills
/// `pixels` (display 8-bit RGB, row by row, y down) from its screen or picture readback.
public struct ColorLoupe: Sendable, Equatable {
    public static let cell: CGFloat = 10
    public static let padding = CGFloat(DrawTheme.Spacing.sm)
    public static let readoutHeight: CGFloat = 16
    /// Offset of the loupe from the pointer, so it never covers the pixel being picked.
    public static let pointerGap: CGFloat = 18
    /// Pixels per side of the grid the host reads (odd, so one pixel sits in the middle).
    public static let side = 11

    public var width: Int, height: Int
    public var pixels: [SIMD3<UInt8>]
    public var centerX: Int, centerY: Int

    public init(width: Int, height: Int, pixels: [SIMD3<UInt8>], centerX: Int? = nil, centerY: Int? = nil) {
        self.width = width; self.height = height; self.pixels = pixels
        self.centerX = centerX ?? width / 2; self.centerY = centerY ?? height / 2
    }

    /// The cell under the pointer.
    public var center: SIMD3<UInt8> {
        let i = centerY * width + centerX
        return pixels.indices.contains(i) ? pixels[i] : .zero
    }

    /// "R 12  G 200  B 7".
    public var readout: String { "R \(center.x)  G \(center.y)  B \(center.z)" }

    public var size: CGSize {
        CGSize(width: CGFloat(width) * Self.cell + 2 * Self.padding,
               height: CGFloat(height) * Self.cell + 2 * Self.padding + Self.readoutHeight)
    }

    /// Below and right of the pointer, flipped to the other side near an edge of `bounds`.
    public static func frame(size: CGSize, pointer: CGPoint, in bounds: CGRect) -> CGRect {
        var x = pointer.x + pointerGap, y = pointer.y + pointerGap
        if x + size.width > bounds.maxX { x = pointer.x - pointerGap - size.width }
        if y + size.height > bounds.maxY { y = pointer.y - pointerGap - size.height }
        x = min(max(x, bounds.minX), max(bounds.maxX - size.width, bounds.minX))
        y = min(max(y, bounds.minY), max(bounds.maxY - size.height, bounds.minY))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Draws the loupe beside `pointer` (window points), kept inside `bounds`.
    public func draw(_ c: inout Canvas, pointer: CGPoint, in bounds: CGRect, theme t: DrawTheme) {
        guard width > 0, height > 0, pixels.count >= width * height else { return }
        let f = Self.frame(size: size, pointer: pointer, in: bounds)
        let radius = CGFloat(DrawTheme.Radius.small)
        c.fill(roundedRect: f, radius: radius, t.panel)
        c.stroke(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), radius: radius, width: 1, t.fieldEdge)
        let o = CGPoint(x: f.minX + Self.padding, y: f.minY + Self.padding)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixels[y * width + x]
                // Picture data, not a UI color.
                c.fill(CGRect(x: o.x + CGFloat(x) * Self.cell, y: o.y + CGFloat(y) * Self.cell, width: Self.cell, height: Self.cell),
                       DrawColor(Float(p.x) / 255, Float(p.y) / 255, Float(p.z) / 255))
            }
        }
        let mid = CGRect(x: o.x + CGFloat(centerX) * Self.cell, y: o.y + CGFloat(centerY) * Self.cell, width: Self.cell, height: Self.cell)
        c.stroke(roundedRect: mid.insetBy(dx: -0.5, dy: -0.5), radius: 0, width: 1, t.fieldEdge)
        c.stroke(roundedRect: mid.insetBy(dx: 0.5, dy: 0.5), radius: 0, width: 1, t.label)
        c.draw(readout, in: CGRect(x: f.minX, y: o.y + CGFloat(height) * Self.cell, width: f.width, height: Self.readoutHeight),
               fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label, align: .center)
    }
}
