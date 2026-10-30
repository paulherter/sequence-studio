import Foundation
import SQCore

/// Bridge from a Date Stamp layer (`GeneratorRef.dateStamp`, SQCore) to the one text renderer: the stamp is an ordinary text
/// generator (area text covering the canvas inside the margin, aligned to the chosen corner), so it rasterizes, caches and
/// composites exactly like a title, in playback and in export.
public enum DateStampText {
    public static let fontName = "Menlo-Bold"

    public static func template(for spec: DateStampSpec) -> TextTemplate {
        let margin = (Double(spec.canvasHeight) * DateStamp.marginShare).rounded()
        let right = spec.corner == .bottomRight || spec.corner == .topRight
        let bottom = spec.corner == .bottomRight || spec.corner == .bottomLeft
        let style = TextStyle(fontName: fontName, size: spec.fontSize, weight: .bold,
                              color: RGBAColor(red: spec.red, green: spec.green, blue: spec.blue),
                              shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6),
                                                 offsetX: spec.fontSize * 0.05, offsetY: spec.fontSize * 0.05, blur: spec.fontSize * 0.04),
                              alignment: right ? .right : .left, verticalAlignment: bottom ? .bottom : .top)
        return TextTemplate(name: "Date Stamp", text: spec.text, style: style,
                            box: TextBox(width: Double(spec.canvasWidth) - 2 * margin, height: Double(spec.canvasHeight) - 2 * margin))
    }

    /// The text generator reference for a Date Stamp layer, nil when `ref` is not one (or cannot be encoded).
    public static func textRef(for ref: GeneratorRef) -> GeneratorRef? {
        guard let spec = DateStampSpec.decode(ref) else { return nil }
        return try? TextGenerator.makeRef(template: template(for: spec), animations: nil)
    }
}
