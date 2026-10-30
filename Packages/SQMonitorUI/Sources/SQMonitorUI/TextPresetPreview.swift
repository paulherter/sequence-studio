import CoreGraphics
import SQCore
import SQText

/// Thumbnails and hover loops of the text Looks and Animations in the Effects grid. The text is rasterized by the real
/// text renderer (same fonts, stroke, shadow, box as on the timeline) over the grid's sample image, the motion by the
/// real `AnimationSet.sample`, so the preview is what the layer will do. RGBA8 buffers like `EffectPreviewPlan`.
public enum TextPresetPreview {
    public static let sampleText = "Text"
    /// In-animation, a hold, then the out-animation (when the motion has one), then a short rest.
    static let hold = 0.45, tail = 0.3

    /// Neutral look used to show a motion.
    static let motionStyle = TextStyle(fontName: "Montserrat", size: 80, weight: .black, stroke: TextStroke(color: .black, width: 8),
                                       shadow: TextShadow(color: .init(red: 0, green: 0, blue: 0, alpha: 0.5), angle: 135, distance: 3, blur: 6))

    private static func ms(_ s: Double) -> Time { Time(Int64((s * 1000).rounded()), 1000) }

    static func isPreviewable(_ id: String) -> Bool { TextPresetCatalog.isTextPresetID(id) }

    /// Seconds of one hover loop of a motion.
    static func loopDuration(_ m: TextMotion) -> Double {
        (m.animationIn?.duration.secs ?? 0) + hold + (m.animationOut?.duration.secs ?? 0) + tail
    }

    /// The layer's pose at second `s` of the loop.
    static func pose(of m: TextMotion, at s: Double) -> AnimationSample {
        let total = loopDuration(m)
        // The clip is exactly the loop, so the out-animation (end-anchored) finishes before the tail.
        let set = AnimationSet(in: m.animationIn, out: m.animationOut)
        let clip = ms(total - tail)
        return set.sample(clipTime: ms(min(s, total - tail)), clipDuration: clip)
    }

    /// The still of a look (at rest on the sample) or of a motion (at rest, after its in-animation).
    public static func still(_ id: String, background: [UInt8], width w: Int, height h: Int) -> [UInt8]? {
        if let look = TextPresetCatalog.look(id: id) {
            return compose(look.style, pose: .rest, over: background, width: w, height: h)
        }
        if let m = TextPresetCatalog.motion(id: id) {
            return compose(motionStyle, pose: pose(of: m, at: m.animationIn?.duration.secs ?? 0), over: background, width: w, height: h)
        }
        return nil
    }

    /// Frames of the hover loop (motions, and generated looks with their suggested motion; other looks are static).
    public static func loop(_ id: String, fps: Double, background: [UInt8], width w: Int, height h: Int) -> [[UInt8]]? {
        // A generated look hovers in its own style with the motion it suggests (applying it still changes the style only).
        if let look = TextPresetCatalog.look(id: id), let mid = look.suggestedMotionID,
           let m = TextPresetCatalog.motions.first(where: { $0.id == mid }), let raster = raster(look.style, width: w, height: h) {
            let n = max(1, Int((loopDuration(m) * fps).rounded()))
            return (0..<n).map { compose(raster, pose: pose(of: m, at: Double($0) / fps), over: background, width: w, height: h) }
        }
        guard let m = TextPresetCatalog.motion(id: id), let raster = raster(motionStyle, width: w, height: h) else { return nil }
        let n = max(1, Int((loopDuration(m) * fps).rounded()))
        return (0..<n).map { compose(raster, pose: pose(of: m, at: Double($0) / fps), over: background, width: w, height: h) }
    }

    /// The thumbnail of any text style (a template, a saved text preset, a Look) at rest: the real renderer over `background`.
    public static func still(style: TextStyle, text: String = sampleText, background: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        guard let img = raster(style, width: w, height: h, text: text) else { return background }
        return compose(img, pose: .rest, over: background, width: w, height: h)
    }

    private static func raster(_ style: TextStyle, width w: Int, height h: Int, text: String = sampleText) -> CGImage? {
        // Sized so the text fills about a third of the thumbnail height at its own proportions; a long one shrinks to fit.
        var scale = min(1, Double(h) * 0.42 / style.size)
        let first = try? TextRenderer.render(text: text, style: style, maxWidth: nil, scale: scale)
        if let f = first, Double(f.image.width) > Double(w) * 0.92 {
            scale *= Double(w) * 0.92 / Double(f.image.width)
            return (try? TextRenderer.render(text: text, style: style, maxWidth: nil, scale: scale))?.image
        }
        return first?.image
    }

    private static func compose(_ style: TextStyle, pose: AnimationSample, over bg: [UInt8], width w: Int, height h: Int) -> [UInt8]? {
        guard let img = raster(style, width: w, height: h) else { return bg }
        return compose(img, pose: pose, over: bg, width: w, height: h)
    }

    private static func compose(_ img: CGImage, pose: AnimationSample, over bg: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var out = bg
        out.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let k = Double(h) / 1080            // pose offsets are sequence pixels of a 1080p canvas
            ctx.setAlpha(min(1, max(0, pose.opacity)))
            ctx.translateBy(x: Double(w) / 2 + pose.offset.x * k, y: Double(h) / 2 - pose.offset.y * k)
            ctx.rotate(by: -pose.rotation * .pi / 180)
            ctx.scaleBy(x: max(0, pose.scale), y: max(0, pose.scale))
            ctx.draw(img, in: CGRect(x: -Double(img.width) / 2, y: -Double(img.height) / 2, width: Double(img.width), height: Double(img.height)))
        }
        return out
    }
}

private extension Time {
    var secs: Double { Double(value) / Double(timescale) }
}
