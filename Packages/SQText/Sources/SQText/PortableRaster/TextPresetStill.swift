import Foundation
import SQCore

/// Thumbnails and hover loops of the text Looks, Animations and text templates without Core Graphics: the Mac
/// `TextPresetPreview` (SQMonitorUI) on `PortableTextRenderer`, so Windows and the shared UI show the same pictures. The
/// text is drawn by the real renderer (same fonts, stroke, shadow, box as on the timeline) over a background, the motion
/// by the real `AnimationSet.sample`. Buffers are RGBA8 sRGB, top row first, `width * height * 4` bytes.
public enum TextPresetStill {
    public static let sampleText = "Text"
    /// In-animation, a hold, then the out-animation (when the motion has one), then a short rest.
    static let hold = 0.45, tail = 0.3

    /// Neutral look used to show a motion.
    static let motionStyle = TextStyle(fontName: "Montserrat", size: 80, weight: .black, stroke: TextStroke(color: .black, width: 8),
                                       shadow: TextShadow(color: .init(red: 0, green: 0, blue: 0, alpha: 0.5), angle: 135, distance: 3, blur: 6))

    private static func ms(_ s: Double) -> Time { Time(Int64((s * 1000).rounded()), 1000) }
    private static func secs(_ t: Time?) -> Double { t.map { Double($0.value) / Double($0.timescale) } ?? 0 }

    /// Seconds of one hover loop of a motion.
    public static func loopDuration(_ m: TextMotion) -> Double {
        secs(m.animationIn?.duration) + hold + secs(m.animationOut?.duration) + tail
    }

    /// The layer's pose at second `s` of the loop.
    public static func pose(of m: TextMotion, at s: Double) -> AnimationSample {
        let total = loopDuration(m)
        // The clip is exactly the loop, so the out-animation (end-anchored) finishes before the tail.
        let set = AnimationSet(in: m.animationIn, out: m.animationOut)
        return set.sample(clipTime: ms(min(s, total - tail)), clipDuration: ms(total - tail))
    }

    /// The still of a Look (at rest on the background) or of an Animation (after its in-animation); nil for other ids.
    public static func still(_ id: String, background: [UInt8], width w: Int, height h: Int) -> [UInt8]? {
        if let look = TextPresetCatalog.look(id: id) {
            return still(style: look.style, background: background, width: w, height: h)
        }
        if let m = TextPresetCatalog.motion(id: id) {
            guard let pic = raster(motionStyle, width: w, height: h) else { return background }
            return compose(pic, pose: pose(of: m, at: secs(m.animationIn?.duration)), over: background, width: w, height: h)
        }
        return nil
    }

    /// Frames of the hover loop (motions, and generated looks with their suggested motion; other looks are static: nil).
    public static func loop(_ id: String, fps: Double, background: [UInt8], width w: Int, height h: Int) -> [[UInt8]]? {
        let style: TextStyle, motion: TextMotion
        if let look = TextPresetCatalog.look(id: id), let mid = look.suggestedMotionID,
           let m = TextPresetCatalog.motions.first(where: { $0.id == mid }) {
            style = look.style; motion = m          // a generated look hovers in its own style with the motion it suggests
        } else if let m = TextPresetCatalog.motion(id: id) {
            style = motionStyle; motion = m
        } else {
            return nil
        }
        guard let pic = raster(style, width: w, height: h) else { return nil }
        let n = max(1, Int((loopDuration(motion) * fps).rounded()))
        return (0..<n).map { compose(pic, pose: pose(of: motion, at: Double($0) / fps), over: background, width: w, height: h) }
    }

    /// The thumbnail of any text style (a template, a saved text preset, a Look) at rest over `background`.
    public static func still(style: TextStyle, text: String = sampleText, background: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        guard let pic = raster(style, width: w, height: h, text: text) else { return background }
        return compose(pic, pose: .rest, over: background, width: w, height: h)
    }

    /// An opaque background buffer of one sRGB color (0...255 channels).
    public static func background(red: UInt8, green: UInt8, blue: UInt8, width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: max(0, w * h * 4))
        for i in stride(from: 0, to: out.count, by: 4) { out[i] = red; out[i + 1] = green; out[i + 2] = blue }
        return out
    }

    /// Sized so the text fills about 42 % of the thumbnail height at its own proportions; a long one shrinks to 92 % of
    /// the width (the Mac `raster`).
    static func raster(_ style: TextStyle, width w: Int, height h: Int, text: String = sampleText) -> PortableTextRenderer.Picture? {
        guard style.size > 0, w > 0, h > 0 else { return nil }
        var scale = min(1, Double(h) * 0.42 / style.size)
        let first = PortableTextRenderer.render(text: text, style: style, maxWidth: nil, scale: scale)
        if let f = first, Double(f.picture.width) > Double(w) * 0.92 {
            scale *= Double(w) * 0.92 / Double(f.picture.width)
            return PortableTextRenderer.render(text: text, style: style, maxWidth: nil, scale: scale)?.picture
        }
        return first?.picture
    }

    /// `pic` (premultiplied linear light) centered on the background, moved, turned and scaled by `pose` (offsets are
    /// sequence pixels of a 1080p canvas, y down; rotation in degrees clockwise), faded by its opacity. Bilinear.
    static func compose(_ pic: PortableTextRenderer.Picture, pose: AnimationSample, over bg: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        guard bg.count == w * h * 4, pic.width > 0, pic.height > 0, pose.scale > 0 else { return bg }
        let op = Float(min(1, max(0, pose.opacity)))
        guard op > 0 else { return bg }
        var out = bg
        let k = Double(h) / 1080
        let cx = Double(w) / 2 + pose.offset.x * k, cy = Double(h) / 2 + pose.offset.y * k
        let a = pose.rotation * .pi / 180, cosA = cos(a), sinA = sin(a), inv = 1 / pose.scale
        let pw = pic.width, ph = pic.height, hw = Double(pw) / 2, hh = Double(ph) / 2
        // The destination box the turned, scaled picture covers.
        let ex = (abs(cosA) * hw + abs(sinA) * hh) * pose.scale, ey = (abs(sinA) * hw + abs(cosA) * hh) * pose.scale
        let x0 = max(0, Int((cx - ex).rounded(.down)) - 1), x1 = min(w - 1, Int((cx + ex).rounded(.up)) + 1)
        let y0 = max(0, Int((cy - ey).rounded(.down)) - 1), y1 = min(h - 1, Int((cy + ey).rounded(.up)) + 1)
        guard x0 <= x1, y0 <= y1 else { return bg }
        let px = pic.pixels
        func texel(_ x: Int, _ y: Int, _ ch: Int) -> Float {
            guard x >= 0, y >= 0, x < pw, y < ph else { return 0 }
            return px[(y * pw + x) * 4 + ch]
        }
        for y in y0...y1 {
            for x in x0...x1 {
                // Inverse pose: destination pixel center into picture pixels.
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let sx = (dx * cosA + dy * sinA) * inv + hw - 0.5, sy = (-dx * sinA + dy * cosA) * inv + hh - 0.5
                guard sx > -1, sy > -1, sx < Double(pw), sy < Double(ph) else { continue }
                let ix = Int(sx.rounded(.down)), iy = Int(sy.rounded(.down))
                let fx = Float(sx - Double(ix)), fy = Float(sy - Double(iy))
                var s = [Float](repeating: 0, count: 4)
                for ch in 0..<4 {
                    let top = texel(ix, iy, ch) * (1 - fx) + texel(ix + 1, iy, ch) * fx
                    let bottom = texel(ix, iy + 1, ch) * (1 - fx) + texel(ix + 1, iy + 1, ch) * fx
                    s[ch] = (top * (1 - fy) + bottom * fy) * op
                }
                guard s[3] > 0.0005 else { continue }
                let i = (y * w + x) * 4
                let ba = Float(bg[i + 3]) / 255, sa = min(1, s[3])
                let oa = sa + ba * (1 - sa)
                guard oa > 0 else { continue }
                for ch in 0..<3 {
                    let lin = (s[ch] + Self.decode[Int(bg[i + ch])] * ba * (1 - sa)) / oa
                    out[i + ch] = Self.encode(lin)
                }
                out[i + 3] = UInt8(max(0, min(255, (oa * 255).rounded())))
            }
        }
        return out
    }

    /// sRGB byte to linear light.
    static let decode: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// Linear light to an sRGB byte.
    static func encode(_ l: Float) -> UInt8 {
        let c = min(1, max(0, l))
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
        return UInt8((s * 255).rounded())
    }
}
