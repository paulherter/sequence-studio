import Foundation

/// The second look at a tracked subject: the tracking model answers on the whole frame stretched onto its square, which
/// leaves a person of 5 % of the frame a few dozen mask texels wide. A crop around the first answer, stretched onto the
/// same square, gives the model several times the detail; its answer replaces the first one inside the crop when the two
/// agree. Also the search band that keeps a new mask near where the subject was.
///
/// Principles from the research notes (docs/research/mask-tracking/E2-premiere-resolve-mask-deep.md sections 4, 6, 10):
/// crop around the last mask with a margin, never track a different object far away. No third-party code.
public enum SubjectCropPass {
    /// The crop's width / height in pixels stays inside `minAspect ... 1 / minAspect`: a strip stretched to a square
    /// would distort the person more than the whole frame does.
    public static let minAspect = 0.6
    /// Share of the box's longer side added on each side.
    public static let margin = 0.1
    /// A crop of more than this share of the frame is no gain over the frame itself.
    public static let largestCrop = 0.65
    /// The crop's answer must overlap the frame's answer by this much to be used.
    public static let agreement = 0.6

    /// The crop (frame fractions) for a subject in `box`; nil when the subject is too large for it to help.
    /// `aspect`: the frame's width / height.
    public static func crop(around box: SubjectTrackBox, aspect: Double) -> SubjectTrackBox? {
        guard box.width > 0, box.height > 0, aspect > 0 else { return nil }
        let pad = max(margin * max(box.width, box.height), 0.02)
        var w = box.width + 2 * pad, h = box.height + 2 * pad
        // Pixel aspect = w * aspect / h, kept in range by widening the shorter side.
        let pixel = w * aspect / h
        if pixel < minAspect { w = minAspect * h / aspect } else if pixel > 1 / minAspect { h = w * aspect * minAspect }
        // Clamped to the frame, the other side comes down so the aspect bound still holds.
        if h > 1 { h = 1; w = min(w, 1 / (aspect * minAspect)) }
        if w > 1 { w = 1; h = min(h, aspect / minAspect) }
        guard w >= box.width - 1e-9, h >= box.height - 1e-9 else { return nil }
        guard w * h <= largestCrop else { return nil }
        let cx = (box.x0 + box.x1) / 2, cy = (box.y0 + box.y1) / 2
        let x0 = min(max(cx - w / 2, 0), 1 - w), y0 = min(max(cy - h / 2, 0), 1 - h)
        return SubjectTrackBox(x0: x0, y0: y0, x1: x0 + w, y1: y0 + h)
    }

    /// Whether the crop's answer (on the frame's logit grid) is the same subject as the frame's answer.
    public static func accepts(crop: [Float], frame: [Float]) -> Bool {
        guard crop.contains(where: { $0 > 0 }) else { return false }
        return SubjectTrackRules.iou(crop, frame) >= agreement
    }

    /// `size` x `size` logits of the crop laid onto the frame's grid (`side` x `side`): inside the crop the crop's
    /// answer, outside the frame's own.
    public static func merged(frame: [Float], side: Int, cropLogits: [Float], size: Int, crop: SubjectTrackBox) -> [Float] {
        var out = frame
        place(cropLogits, size: size, crop: crop, width: side, height: side) { x, y, v in out[y * side + x] = v }
        return out
    }

    /// The matte of the frame with the crop's answer (bilinear, then sigmoid) inside the crop.
    // shortcut: still the sigmoid, not `SubjectTrackRules.edgeAlpha` (the crop pass is off unless `SQ_SUBJECT_MASK_CROP=1`);
    // upgrade to the edge-distance alpha when the crop pass is switched on by default.
    public static func compose(base: SubjectMatte, cropLogits: [Float], size: Int, crop: SubjectTrackBox) -> SubjectMatte {
        var values = base.values
        let w = base.width
        place(cropLogits, size: size, crop: crop, width: base.width, height: base.height) { x, y, v in
            values[y * w + x] = v <= -9 ? 0 : v >= 9 ? 1 : 1 / (1 + Float(exp(Double(-v))))
        }
        return SubjectMatte(width: base.width, height: base.height, values: values)
    }

    /// Calls `write` for every cell of a `width` x `height` grid that lies inside `crop`, with the crop logits sampled there.
    private static func place(_ logits: [Float], size: Int, crop: SubjectTrackBox, width: Int, height: Int, write: (Int, Int, Float) -> Void) {
        precondition(logits.count == size * size && size > 1, "crop logits size mismatch")
        let xa = max(Int((crop.x0 * Double(width)).rounded(.up)), 0), xb = min(Int((crop.x1 * Double(width)).rounded(.down)), width)
        let ya = max(Int((crop.y0 * Double(height)).rounded(.up)), 0), yb = min(Int((crop.y1 * Double(height)).rounded(.down)), height)
        guard xa < xb, ya < yb, crop.width > 0, crop.height > 0 else { return }
        for y in ya..<yb {
            let fy = min(max(((Double(y) + 0.5) / Double(height) - crop.y0) / crop.height * Double(size) - 0.5, 0), Double(size - 1))
            let r0 = Int(fy) * size, r1 = min(Int(fy) + 1, size - 1) * size, ty = Float(fy - Double(Int(fy)))
            for x in xa..<xb {
                let fx = min(max(((Double(x) + 0.5) / Double(width) - crop.x0) / crop.width * Double(size) - 0.5, 0), Double(size - 1))
                let c0 = Int(fx), c1 = min(c0 + 1, size - 1), tx = Float(fx - Double(c0))
                let top = logits[r0 + c0] + (logits[r0 + c1] - logits[r0 + c0]) * tx
                let bottom = logits[r1 + c0] + (logits[r1 + c1] - logits[r1 + c0]) * tx
                write(x, y, top + (bottom - top) * ty)
            }
        }
    }

    /// Where the subject may be on the next frame: the previous box grown by a quarter of its diagonal plus a fixed margin.
    /// Every frame the subject was lost widens the band by `lostGrowth` of the frame on each side, so one that comes
    /// back far from where it left is found again (the whole frame after about 8 lost frames).
    public static let lostGrowth = 0.1

    public static func band(around box: SubjectTrackBox, lostFrames: Int = 0) -> SubjectTrackBox {
        let diagonal = (box.width * box.width + box.height * box.height).squareRoot()
        let grow = 0.25 * diagonal + 0.05 + lostGrowth * Double(max(lostFrames, 0))
        return box.grown(grow, grow)
    }

    /// `logits` (size x size) with everything outside `band` set to background.
    public static func constrain(_ logits: [Float], size: Int, to band: SubjectTrackBox) -> [Float] {
        var out = logits
        for y in 0..<size {
            let v = (Double(y) + 0.5) / Double(size)
            for x in 0..<size {
                let u = (Double(x) + 0.5) / Double(size)
                if !(u >= band.x0 && u <= band.x1 && v >= band.y0 && v <= band.y1) { out[y * size + x] = -SubjectTrackRules.matteLogit }
            }
        }
        return out
    }
}
