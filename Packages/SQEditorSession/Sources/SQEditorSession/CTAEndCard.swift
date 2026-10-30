import Foundation
import SQCore
import SQText

/// H1: the built-in follow / share end card of short videos. A pill, a bell icon and a label that pop in, get pressed
/// (the pill dips to 90 % and back) and switch to the second state ("FOLGEN" -> "GEFOLGT", red -> gray). Built from
/// existing generator types only: one Graphics clip with a rounded rectangle, a text layer for the icon and two text
/// layers for the states, so no alpha video is needed and every part stays editable in the Graphics panel.
public enum CTAEndCard {
    public static let id = "cta-end-card"
    public static let name = "CTA End Card"
    public static let label = "FOLGEN", doneLabel = "GEFOLGT", icon = "\u{1F514}"
    /// Length of the clip a new card gets.
    public static let duration = Time(4, 1)

    // Key times, clip-local. Pop-in, then the press: down, state swap, back up.
    public static let popUp = Time(1, 4), popSettle = Time(7, 20)
    static let pressStart = Time(8, 5), pressDown = Time(17, 10), pressUp = Time(37, 20)
    static let swapStart = Time(33, 20), swapEnd = Time(9, 5)
    static let pressScale = 0.9, popOvershoot = 1.1

    public static let red = EffectColor(red: 1, green: 0.19, blue: 0.19)
    static let grey = EffectColor(red: 0.23, green: 0.23, blue: 0.25)

    /// Scale of the whole card at clip-local `t` (what every layer follows about the card's center).
    public static func cardScale(atLocal t: Time) -> Double {
        let keys: [(Time, Double)] = [(.zero, 0), (popUp, popOvershoot), (popSettle, 1), (pressStart, 1), (pressDown, pressScale), (pressUp, 1)]
        guard t > keys[0].0 else { return keys[0].1 }
        for i in 1..<keys.count where t <= keys[i].0 {
            let a = keys[i - 1], b = keys[i]
            let f = sec(t - a.0) / sec(b.0 - a.0)
            return a.1 + (b.1 - a.1) * f
        }
        return 1
    }

    private static func sec(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

    /// The layers, bottom first, for a `canvasWidth` x `canvasHeight` graphic.
    public static func layers(canvasWidth: Int, canvasHeight: Int) throws -> [GraphicsLayer] {
        let w = Double(canvasWidth), h = Double(canvasHeight)
        let pillW = min(w * 0.62, h * 0.4), pillH = pillW * 0.235
        let centre = Vec2(0, h * 0.18)
        let iconX = -pillW / 2 + pillH * 0.85, textX = pillH * 0.35

        func pill(_ name: String, color: EffectColor, opacity: AnimatedProperty<Double>) -> GraphicsLayer {
            var l = GraphicsLayer.shape(.rectangle, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            l.name = name
            l.setShapeSize(width: pillW, height: pillH)
            l.effects[0].parameters[ClipEffect.shapeCornerRadiusKey] = AnimatedProperty(pillH / 2)
            l.effects[0].parameters[ClipEffect.shapeFillKey] = AnimatedProperty(1)
            l.effects[0].colors[ClipEffect.shapeFillColorKey] = AnimatedProperty(color)
            l.animation = motion(at: centre, about: centre, opacity: opacity)
            return l
        }
        func text(_ name: String, _ string: String, size: Double, dx: Double, opacity: AnimatedProperty<Double>) throws -> GraphicsLayer {
            let style = TextStyle(fontName: TextStyle.defaultFontName, size: size, weight: .heavy, color: .white, alignment: .center, allCaps: true)
            let ref = try TextGenerator.makeRef(template: TextTemplate(name: name, text: string, style: style), animations: nil)
            var l = GraphicsLayer.text(ref, name: name)
            l.animation = motion(at: Vec2(centre.x + dx, centre.y), about: centre, opacity: opacity)
            return l
        }

        var greyFade = AnimatedProperty(0.0), labelOut = AnimatedProperty(1.0), doneIn = AnimatedProperty(0.0)
        greyFade.track.insert(Keyframe(time: swapStart, value: 0)); greyFade.track.insert(Keyframe(time: swapEnd, value: 1))
        labelOut.track.insert(Keyframe(time: swapStart, value: 1)); labelOut.track.insert(Keyframe(time: swapEnd, value: 0))
        doneIn.track.insert(Keyframe(time: swapStart, value: 0)); doneIn.track.insert(Keyframe(time: swapEnd, value: 1))

        var result = [
            pill("Pill", color: red, opacity: AnimatedProperty(1.0)),
            pill("Pill Done", color: grey, opacity: greyFade),
        ]
        result.append(try text("Icon", icon, size: pillH * 0.5, dx: iconX - centre.x, opacity: AnimatedProperty(1.0)))
        result.append(try text("Label", label, size: pillH * 0.36, dx: textX, opacity: labelOut))
        result.append(try text("Label Done", doneLabel, size: pillH * 0.36, dx: textX, opacity: doneIn))
        return result
    }

    /// Pop-in and press as Scale keys; the position keys move with the scale (about the card center `c`) so the layers keep their places inside the card.
    private static func motion(at p: Vec2, about c: Vec2, opacity: AnimatedProperty<Double>) -> ClipAnimation {
        var a = ClipAnimation()
        var s = AnimatedProperty(Vec2(1, 1)), pos = AnimatedProperty(p)
        for t in [Time.zero, popUp, popSettle, pressStart, pressDown, pressUp] {
            let k = cardScale(atLocal: t)
            s.track.insert(Keyframe(time: t, value: Vec2(k, k)))
            pos.track.insert(Keyframe(time: t, value: Vec2(c.x + (p.x - c.x) * k, c.y + (p.y - c.y) * k)))
        }
        a.scale = s; a.position = pos; a.opacity = opacity
        return a
    }
}
