import Foundation
import SQCore

/// One text frame on the portable raster (`PortableTextRenderer`), the counterpart of `TextFrame` for Windows: the
/// picture (premultiplied linear-light RGBA floats, top row first) and its placement in sequence pixels (y down) for the
/// untransformed block centered on the canvas, plus the animation factors of the clip's `AnimationSet`.
public struct PortableTextFrame: Sendable {
    public let picture: PortableTextRenderer.Picture
    public let x: Double, y: Double
    public let width: Double, height: Double
    public let opacity: Double, scale: Double
    public let offsetX: Double, offsetY: Double
    public let rotation: Double
    /// Center of the text lines relative to the raster center (sequence px, y down): the caption pivot (`TextFrame.pivotX`).
    public let pivotX: Double, pivotY: Double
    /// The style's footage fill (nil = filled with its color): the compositor layer carries it.
    public let footageFill: TextFootageFill?
    /// The text animators' per-character states the picture was drawn with; nil for the resting picture.
    public let characterStates: [TextCharacterState]?
    /// The animatable units of the layout (empty without a text animator).
    let units: TextUnits?

    /// True when `other` carries the same picture (a caller keeps one upload per picture).
    public func sharesPicture(with other: PortableTextFrame) -> Bool {
        characterStates == other.characterStates && picture.width == other.picture.width && picture.height == other.picture.height
    }

    /// `TextFrame.layerTransform` for a whole raster: the block's center relative to the canvas center, the animation
    /// factors folded into `base`; with `pivotAtText` scale and rotation happen about the center of the text lines
    /// (captions).
    public func layerTransform(base: ClipTransform, canvas: SequenceFormat, pivotAtText: Bool = false) -> ClipTransform {
        var tr = base
        let px = pivotAtText ? pivotX : 0, py = pivotAtText ? pivotY : 0
        tr.position = Vec2(base.position.x + x + width / 2 - Double(canvas.displayWidth) / 2 + offsetX + px,
                           base.position.y + y + height / 2 - Double(canvas.height) / 2 + offsetY + py)
        tr.anchor = Vec2(base.anchor.x + px, base.anchor.y + py)
        tr.scale = Vec2(base.scale.x * scale, base.scale.y * scale)
        tr.rotation += rotation
        tr.opacity *= opacity
        return tr
    }
}

extension TextGenerator {
    /// `frame(ref:…)` on the portable raster: nil for empty text. Date Stamp refs go through `DateStampText.textRef` first.
    /// Text animators draw their per-character states (`PortableTextRenderer.render(… characterStates:)`).
    /// `raster`: a frame this ref gave before (same canvas and scale): when the character states are the same its picture
    /// and placement are kept and only the animation is sampled again (the caller keeps the uploaded picture,
    /// `sharesPicture(with:)`).
    /// shortcut: in-between frames of a text animator are drawn on the caller's thread every frame, no look-ahead lane
    /// or cache (the Mac's `animatedCache`); add one when animated captions drop frames on Windows.
    public static func portableFrame(ref: GeneratorRef, localTime: Time, clipDuration: Time, canvas: SequenceFormat,
                                     scale: Double = 1, raster previous: PortableTextFrame? = nil) throws -> PortableTextFrame? {
        let (template, set) = try decode(ref)
        let anims = set ?? AnimationSet(single: template.animation)
        let a = anims?.sample(clipTime: localTime, clipDuration: clipDuration) ?? .rest
        var units = previous?.units
        var states: [TextCharacterState]?
        if let anims, anims.hasTextAnimator {
            if units == nil {
                let layout = TextLayout.layout(text: template.text, style: template.style.drawn, maxWidth: template.box?.width,
                                               boxHeight: template.box?.height)
                units = TextUnits.segment(layout)
            }
            if let u = units, let st = anims.characterStates(units: u, clipTime: localTime, clipDuration: clipDuration),
               !st.allSatisfy(\.isRest) {
                states = st
            }
        }
        if let p = previous, p.characterStates == states {
            return PortableTextFrame(picture: p.picture, x: p.x, y: p.y, width: p.width, height: p.height, opacity: a.opacity,
                                     scale: a.scale, offsetX: a.offset.x, offsetY: a.offset.y, rotation: a.rotation,
                                     pivotX: p.pivotX, pivotY: p.pivotY, footageFill: p.footageFill, characterStates: states,
                                     units: units)
        }
        let raster: PortableTextRenderer.Raster?
        if let states {
            raster = PortableTextRenderer.render(text: template.text, style: template.style, maxWidth: template.box?.width,
                                                 boxHeight: template.box?.height, scale: scale, highlight: template.highlight,
                                                 characterStates: states)
        } else {
            raster = PortableTextRenderer.render(text: template.text, style: template.style, maxWidth: template.box?.width,
                                                 boxHeight: template.box?.height, scale: scale, highlight: template.highlight)
        }
        guard let raster else { return nil }
        let s = raster.scale
        let b = raster.layout.bounds
        let w = Double(raster.picture.width) / s, h = Double(raster.picture.height) / s
        let c = CaptionLayout.textCentre(of: raster.layout)
        return PortableTextFrame(picture: raster.picture,
                                 x: (Double(canvas.displayWidth) - b.width) / 2 + (raster.originX - b.x),
                                 y: (Double(canvas.height) - b.height) / 2 + (raster.originY - b.y),
                                 width: w, height: h,
                                 opacity: a.opacity, scale: a.scale, offsetX: a.offset.x, offsetY: a.offset.y,
                                 rotation: a.rotation,
                                 pivotX: c.map { $0.x - (raster.originX + w / 2) } ?? 0,
                                 pivotY: c.map { $0.y - (raster.originY + h / 2) } ?? 0,
                                 footageFill: template.style.footageFill, characterStates: states, units: units)
    }

    /// The animatable units of a ref's text (`units(ref:)` without the Core Text raster cache): the caption hand-over
    /// asks for them; nil when the ref does not decode.
    public static func portableUnits(ref: GeneratorRef) -> TextUnits? {
        guard let (template, _) = try? decode(ref) else { return nil }
        return TextUnits.segment(TextLayout.layout(text: template.text, style: template.style.drawn, maxWidth: template.box?.width,
                                                   boxHeight: template.box?.height))
    }
}
