import Foundation
import SQCore

/// The one place that says how a caption looks and where it sits. The Program monitor and the export burn-in both
/// use it, so the picture you cut on is the picture you export: the caption is area text in a box inside the safe area
/// (FB-Y: at the top, middle or bottom, text aligned left/center/right in it, plus a free offset), and the center of the
/// text lines is the pivot of its animation (the caption pop scales about the words, not about the box).
public enum CaptionLayout {
    /// Distance of the box from the canvas top or bottom edge (fraction of the height).
    public static let bottomMargin = 0.12
    /// Box width (fraction of the canvas width).
    public static let widthFraction = 0.86
    /// Box height (fraction of the canvas height); the text is aligned inside it by the position.
    public static let boxHeightFraction = 0.30

    public static func box(canvasWidth: Double, canvasHeight: Double, widthFraction: Double = widthFraction) -> TextBox {
        TextBox(width: canvasWidth * widthFraction, height: canvasHeight * boxHeightFraction)
    }

    /// Text alignment in the box for a position.
    public static func align(_ s: inout TextStyle, _ position: CaptionPosition) {
        switch position.horizontal {
        case .left: s.alignment = .left
        case .center: s.alignment = .center
        case .right: s.alignment = .right
        }
        switch position.vertical {
        case .top: s.verticalAlignment = .top
        case .middle: s.verticalAlignment = .middle
        case .bottom: s.verticalAlignment = .bottom
        }
    }

    public static func template(text: String, style: TextStyle, canvasWidth: Double, canvasHeight: Double,
                                widthFraction: Double = widthFraction, highlight: TextHighlight? = nil,
                                position: CaptionPosition = .default) -> TextTemplate {
        var s = style
        align(&s, position)
        s.footageFill = nil  // a caption is never stenciled: it keeps its own colors
        s.secondLine = nil   // captions are one style; the second-line look belongs to text clips
        let b = box(canvasWidth: canvasWidth, canvasHeight: canvasHeight, widthFraction: widthFraction)
        s.size = fittingSize(text: text, style: s, boxWidth: b.width)
        var t = TextTemplate(name: "Caption", text: text, style: s)
        t.highlight = highlight
        t.box = b
        return t
    }

    /// FB-M: words are never split across lines, so a caption whose widest word (with its stroke and pill padding) is wider
    /// than the box is drawn smaller until that word fits. Otherwise the style's size.
    public static func fittingSize(text: String, style: TextStyle, boxWidth: Double) -> Double {
        guard style.size > 0 else { return style.size }
        // Asked for every caption on every playback frame: one layout per word, remembered until the fonts change.
        if FontResolver.scopedCache != nil { return measureFittingSize(text: text, style: style, boxWidth: boxWidth) }
        return FontResolver.memo.fit(.init(text: text, style: style, boxWidth: boxWidth)) {
            measureFittingSize(text: text, style: style, boxWidth: boxWidth)
        }
    }

    private static func measureFittingSize(text: String, style: TextStyle, boxWidth: Double) -> Double {
        let words = WordSegmentation.words(text)
        guard !words.isEmpty, style.size > 0 else { return style.size }
        let widest = words.map { TextLayout.layout(text: String($0), style: style, maxWidth: nil).lines.first?.width ?? 0 }.max() ?? 0
        let extra = 2 * ((style.stroke?.reach ?? 0) + (style.background?.padding.horizontal ?? 0))
        let room = boxWidth - extra
        guard widest > room, room > 0 else { return style.size }
        // Width grows linearly with the size (tracking is in points and does not scale; the 1 % margin covers it and rounding).
        return max(1, (style.size * room / widest * 0.99 * 100).rounded(.down) / 100)
    }

    /// Box center relative to the canvas center (sequence px, y down). `bottomMargin` is the distance from the top or
    /// bottom edge (top and bottom positions).
    public static func boxCentre(canvasWidth: Double, canvasHeight: Double, position: CaptionPosition = .default,
                                 bottomMargin: Double = bottomMargin) -> (x: Double, y: Double) {
        let half = canvasHeight * (0.5 - bottomMargin) - canvasHeight * boxHeightFraction / 2
        let y: Double
        switch position.vertical {
        case .top: y = -half
        case .middle: y = 0
        case .bottom: y = half
        }
        return (canvasWidth * position.offsetX, y + canvasHeight * position.offsetY)
    }

    /// Center of the rendered raster in canvas pixels (origin top-left, y down). `originX/Y` is the raster's top-left
    /// relative to the box (`TextRaster.originX/Y`), `width/height` its size in sequence pixels.
    public static func rasterCentre(canvasWidth: Double, canvasHeight: Double, originX: Double, originY: Double,
                                    width: Double, height: Double, widthFraction: Double = widthFraction,
                                    position: CaptionPosition = .default,
                                    bottomMargin: Double = bottomMargin) -> (x: Double, y: Double) {
        let b = box(canvasWidth: canvasWidth, canvasHeight: canvasHeight, widthFraction: widthFraction)
        let c = boxCentre(canvasWidth: canvasWidth, canvasHeight: canvasHeight, position: position, bottomMargin: bottomMargin)
        let left = canvasWidth / 2 + c.x - b.width / 2, top = canvasHeight / 2 + c.y - b.height / 2
        return (left + originX + width / 2, top + originY + height / 2)
    }

    /// Center of the text lines (layout space); nil for empty text. A pill is symmetric around them, a shadow is not part
    /// of it, so this is the center of the words as the eye sees them.
    public static func textCentre(of layout: TextLayoutResult) -> (x: Double, y: Double)? {
        guard let r = layout.lines.map(\.rect).reduce(nil as TextRect?, { acc, r in acc.map { $0.union(r) } ?? r }) else { return nil }
        return (r.x + r.width / 2, r.y + r.height / 2)
    }

#if canImport(CoreText)
    /// The animation pivot of a caption raster: the text center relative to the raster center (sequence px, y down).
    public static func pivot(of raster: TextRaster) -> (x: Double, y: Double) {
        guard let c = textCentre(of: raster.layout) else { return (0, 0) }
        let w = Double(raster.pixelWidth) / raster.scale, h = Double(raster.pixelHeight) / raster.scale
        return (c.x - (raster.originX + w / 2), c.y - (raster.originY + h / 2))
    }

    /// The same pivot relative to the center of the whole raster a cropped one is a part of: the operations of `pivot`
    /// on the whole raster's numbers, so it is the pivot of the whole-box raster to the bit (equal to `pivot` for one).
    public static func wholePivot(of raster: TextRaster) -> (x: Double, y: Double) {
        guard let c = textCentre(of: raster.layout) else { return (0, 0) }
        let w = Double(raster.wholePixelWidth) / raster.scale, h = Double(raster.wholePixelHeight) / raster.scale
        return (c.x - (raster.wholeOriginX + w / 2), c.y - (raster.wholeOriginY + h / 2))
    }
#endif

    /// Where the raster center is drawn when the caption is scaled and rotated (degrees, clockwise on screen) about its
    /// pivot and moved by `offset`: what the compositor does with an anchored layer in the Program monitor.
    public static func drawCentre(rasterCentre c: (x: Double, y: Double), pivot p: (x: Double, y: Double), scale: Double,
                                  rotationDegrees: Double, offset: Vec2) -> (x: Double, y: Double) {
        let r = rotationDegrees * .pi / 180
        let dx = -p.x * scale, dy = -p.y * scale
        return (c.x + p.x + offset.x + cos(r) * dx - sin(r) * dy,
                c.y + p.y + offset.y + sin(r) * dx + cos(r) * dy)
    }
}
