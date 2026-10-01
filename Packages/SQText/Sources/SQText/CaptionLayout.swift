import Foundation

/// The one place that says how a caption looks and where it sits. The Program monitor and the export burn-in both
/// use it, so the picture you cut on is the picture you export: the caption is area text in a box at the bottom
/// safe area, centred, bottom-aligned inside the box, and the raster's centre is the pivot of its animation.
public enum CaptionLayout {
    /// Distance of the box bottom from the canvas bottom (fraction of the height).
    public static let bottomMargin = 0.12
    /// Box width (fraction of the canvas width).
    public static let widthFraction = 0.86
    /// Box height (fraction of the canvas height); the text is bottom-aligned inside it.
    public static let boxHeightFraction = 0.30

    public static func box(canvasWidth: Double, canvasHeight: Double, widthFraction: Double = widthFraction) -> TextBox {
        TextBox(width: canvasWidth * widthFraction, height: canvasHeight * boxHeightFraction)
    }

    public static func template(text: String, style: TextStyle, canvasWidth: Double, canvasHeight: Double,
                                widthFraction: Double = widthFraction, highlight: TextHighlight? = nil) -> TextTemplate {
        var s = style
        s.alignment = .center
        s.verticalAlignment = .bottom
        var t = TextTemplate(name: "Caption", text: text, style: s)
        t.highlight = highlight
        t.box = box(canvasWidth: canvasWidth, canvasHeight: canvasHeight, widthFraction: widthFraction)
        return t
    }

    /// Box centre relative to the canvas centre (sequence px, y down).
    public static func boxCentre(canvasWidth: Double, canvasHeight: Double, bottomMargin: Double = bottomMargin) -> (x: Double, y: Double) {
        (0, canvasHeight * (0.5 - bottomMargin) - canvasHeight * boxHeightFraction / 2)
    }

    /// Centre of the rendered raster in canvas pixels (origin top-left, y down). `originX/Y` is the raster's top-left
    /// relative to the box (`TextRaster.originX/Y`), `width/height` its size in sequence pixels.
    public static func rasterCentre(canvasWidth: Double, canvasHeight: Double, originX: Double, originY: Double,
                                    width: Double, height: Double, widthFraction: Double = widthFraction,
                                    bottomMargin: Double = bottomMargin) -> (x: Double, y: Double) {
        let b = box(canvasWidth: canvasWidth, canvasHeight: canvasHeight, widthFraction: widthFraction)
        let c = boxCentre(canvasWidth: canvasWidth, canvasHeight: canvasHeight, bottomMargin: bottomMargin)
        let left = canvasWidth / 2 + c.x - b.width / 2, top = canvasHeight / 2 + c.y - b.height / 2
        return (left + originX + width / 2, top + originY + height / 2)
    }
}
