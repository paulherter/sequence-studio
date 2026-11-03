import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The one look of every segmented control (form rows, Export, card browser, Start layout, Color page switch):
/// a `well` track with a 0.5 `hair` ring, the chosen segment `raised` on a small 0 1 2 shadow with a `hair2` ring.
public enum SegmentDraw {
    public static func track(_ c: inout Canvas, _ r: CGRect, _ t: DrawTheme, radius: CGFloat = CGFloat(DrawTheme.Radius.control)) {
        c.fill(roundedRect: r, radius: radius, t.well)
        c.stroke(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), radius: radius, width: 0.5, t.hair)
    }

    /// `opaqueAbove`: the shadow is only a ring outside the segment, never a dark smear under it.
    public static func selected(_ c: inout Canvas, _ r: CGRect, _ t: DrawTheme, radius: CGFloat = CGFloat(DrawTheme.Radius.small)) {
        c.shadow(roundedRect: r, radius: radius, blur: 2, dy: 1, DrawColor(0, 0, 0, 0.3), opaqueAbove: true)
        c.fill(roundedRect: r, radius: radius, t.raised)
        c.stroke(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), radius: radius, width: 0.5, t.hair2)
    }
}
