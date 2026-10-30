// +Rotation / Perspective mask tracking: frame-to-frame motion of grid points inside the mask (pyramidal Lucas-Kanade,
// `LucasKanade`), fitted per mode (SQCore `MaskMotionFit`, robust against background inside the outline) and chained
// from the start frame. Picked over Vision's dense optical flow and homographic registration by measured accuracy on a
// synthetic turning patch (MaskPointTrackerTests; numbers in DECISIONS "Mask tracking: rotation and perspective").

import CoreVideo
import Foundation
import SQCore

/// Follows one region through frames handed in tracking order. Not Sendable state: one per track run.
struct MaskPointTracker {
    let mode: MaskTrackMode
    /// The region at the first frame (frame fractions).
    let region: [Vec2]
    /// Pixel motion from the first frame to the latest one.
    private(set) var total = MaskMotion.identity
    /// Luma pyramid of the previous frame (each frame is converted once).
    private var previous: [LucasKanade.Gray]?
    private(set) var lost = false
    /// How well the last frame matched the template (0...1, normalized correlation of the region against the
    /// template it was aligned to). Meaningless before the first `step`.
    private(set) var confidence = 1.0
    /// The last `step` held the previous motion because the object could not be seen (occlusion, blur, cut).
    private(set) var held = false
    private var heldFrames = 0
    /// Template of the latest re-anchoring and the one of the first frame (the drift guard).
    private var anchor: Anchor?
    private var original: Anchor?
    /// A template could not be cut (region too small or outside the frame) at the last attempt: the chain runs without
    /// template alignment (more drift) until a later frame gives one.
    private(set) var degraded = false
    /// Below this correlation the template is refreshed from the current frame.
    static let refreshConfidence = 0.9
    /// Below this the frame is not trusted: the motion holds (and the chain does not advance).
    static let holdConfidence = 0.4
    /// Held for more than this many frames in a row: lost.
    static let maxHeldFrames = 90
    /// With a refreshed template, the original one still correlating at least this much pulls the result back.
    static let guardConfidence = 0.6
    /// Share of the way from the refreshed-template result to the original-template result.
    static let guardBlend = 0.3
    /// Template crop margin around the region (px).
    static let margin = 16.0
    /// Grid points aimed at per frame.
    static let samples = 300.0
    /// Fewer kept points than this share of the samples (or than 8): the object is lost.
    static let minInlierShare = 0.25
    /// Less of the region than this inside the frame: lost (it left the picture).
    static let minVisibleShare = 0.4

    init(region: [Vec2], mode: MaskTrackMode) {
        self.region = region; self.mode = mode
    }

    /// Motion (frame fractions) from the first frame to `frame`; the first call gives the identity. nil once lost.
    mutating func step(_ frame: CVPixelBuffer) -> MaskMotion? {
        guard !lost else { return nil }
        let w = Double(CVPixelBufferGetWidth(frame)), h = Double(CVPixelBufferGetHeight(frame))
        guard let gray = LucasKanade.gray(frame) else { lost = true; return nil }
        let pyramid = LucasKanade.pyramid(gray)
        guard let prev = previous else {
            anchor = Anchor(gray: gray, motion: .identity, region: region, w: w, h: h)
            original = anchor; previous = pyramid
            degraded = anchor == nil
            return .identity
        }
        let now = region.map { total.apply(Vec2($0.x * w, $0.y * h)) }
        let area = abs(Self.area(now))
        let spacing = max(2, (area / Self.samples).squareRoot())
        // Only points whose window lies in the frame. A region mostly out of the picture counts as lost: what is left
        // of it would latch onto the still background.
        let r = Double(LucasKanade.radius) + 1
        let all = MaskMotionFit.samplePoints(in: now, spacing: spacing, limit: Int(Self.samples * 1.5))
        var pts = all.filter { $0.x >= r && $0.y >= r && $0.x <= w - 1 - r && $0.y <= h - 1 - r }
        guard Double(pts.count) >= Self.minVisibleShare * Double(all.count) else { lost = true; return nil }
        // Windows that straddle the outline see background too: keep points a window away from it when enough remain.
        let inset = pts.filter { Self.edgeDistance(now, $0) > r }
        if inset.count >= 24 { pts = inset }
        // Frame-to-frame chaining; when it fails the template alignment below still gets a try from the old motion.
        var candidate = total
        if pts.count >= 8, let pairs = LucasKanade.pairs(prev, pyramid, pts),
           let fit = MaskMotionFit.fit(from: pairs.0, to: pairs.1, mode: mode),
           Double(fit.inliers) >= max(8, Self.minInlierShare * Double(pts.count)) {
            candidate = total.then(fit.motion)
        }
        // Re-anchor against the template: removes the drift the chain collects.
        var conf = 1.0
        if let anchor {
            let r1 = anchor.align(candidate, to: gray, mode: mode)
            candidate = r1.motion; conf = r1.confidence
            if anchor !== original, let original, conf >= Self.holdConfidence {
                let r0 = original.align(candidate, to: gray, mode: mode)
                if r0.confidence >= Self.guardConfidence {
                    candidate = Self.blend(candidate, r0.motion, Self.guardBlend)
                }
            }
        }
        confidence = conf
        guard conf >= Self.holdConfidence else {
            held = true; heldFrames += 1
            if heldFrames > Self.maxHeldFrames { lost = true; return nil }
            return total.inFractions(width: w, height: h)
        }
        held = false; heldFrames = 0
        total = candidate
        previous = pyramid
        // A failed template keeps the old one (never drops alignment); with none at all it is retried every frame.
        if anchor == nil || conf < Self.refreshConfidence {
            if let a = Anchor(gray: gray, motion: total, region: region, w: w, h: h) {
                anchor = a
                if original == nil { original = a }
                degraded = false
            } else {
                degraded = true
            }
        }
        return total.inFractions(width: w, height: h)
    }

    /// Entry-wise blend of two motions (homographies normalized to m[8] = 1), `t` of the way from `a` to `b`.
    static func blend(_ a: MaskMotion, _ b: MaskMotion, _ t: Double) -> MaskMotion {
        let na = a.m[8] != 0 ? a.m[8] : 1, nb = b.m[8] != 0 ? b.m[8] : 1
        return MaskMotion(m: (0..<9).map { a.m[$0] / na * (1 - t) + b.m[$0] / nb * t })
    }

    /// A template: the luma of a frame around the region (as it stood at `motion`) and the points to correlate.
    final class Anchor {
        let pyramid: [LucasKanade.Gray]
        /// Crop origin in frame pixels.
        let ox: Int, oy: Int
        let motion: MaskMotion
        /// Sample points in crop pixels.
        let points: [Vec2]

        init?(gray: LucasKanade.Gray, motion: MaskMotion, region: [Vec2], w: Double, h: Double) {
            let poly = region.map { motion.apply(Vec2($0.x * w, $0.y * h)) }
            guard let minX = poly.map(\.x).min(), let maxX = poly.map(\.x).max(),
                  let minY = poly.map(\.y).min(), let maxY = poly.map(\.y).max() else { return nil }
            let x0 = max(0, Int((minX - MaskPointTracker.margin).rounded(.down)))
            let y0 = max(0, Int((minY - MaskPointTracker.margin).rounded(.down)))
            let x1 = min(gray.w, Int((maxX + MaskPointTracker.margin).rounded(.up)))
            let y1 = min(gray.h, Int((maxY + MaskPointTracker.margin).rounded(.up)))
            guard x1 - x0 >= 16, y1 - y0 >= 16 else { return nil }
            let cw = x1 - x0, ch = y1 - y0
            var px = [Float](repeating: 0, count: cw * ch)
            for y in 0..<ch { for x in 0..<cw { px[y * cw + x] = gray.px[(y0 + y) * gray.w + x0 + x] } }
            pyramid = LucasKanade.pyramid(LucasKanade.Gray(w: cw, h: ch, px: px))
            ox = x0; oy = y0; self.motion = motion
            let r = Double(LucasKanade.radius) + 1
            let spacing = max(2, (abs(MaskPointTracker.area(poly)) / 200).squareRoot())
            var pts = MaskMotionFit.samplePoints(in: poly, spacing: spacing, limit: 300)
                .filter { $0.x - Double(x0) >= r && $0.y - Double(y0) >= r
                    && $0.x - Double(x0) <= Double(cw - 1) - r && $0.y - Double(y0) <= Double(ch - 1) - r }
            let inset = pts.filter { MaskPointTracker.edgeDistance(poly, $0) > r }
            if inset.count >= 24 { pts = inset }
            points = pts.map { Vec2($0.x - Double(x0), $0.y - Double(y0)) }
        }

        /// Refines `estimate` (this template's pose -> `gray`'s pose, from the first frame) so the template matches
        /// `gray`, and reports the correlation of the result. Without usable points the estimate stands.
        func align(_ estimate: MaskMotion, to gray: LucasKanade.Gray, mode: MaskTrackMode)
            -> (motion: MaskMotion, confidence: Double) {
            guard points.count >= 8, let back = motion.inverse else { return (estimate, 1) }
            // Template frame -> current frame.
            let rel = back.then(estimate)
            let base = pyramid[0]
            var warped = LucasKanade.Gray(w: base.w, h: base.h, px: [Float](repeating: 0, count: base.w * base.h))
            for y in 0..<base.h {
                for x in 0..<base.w {
                    let q = rel.apply(Vec2(Double(ox + x), Double(oy + y)))
                    warped.px[y * base.w + x] = gray.at(Float(q.x), Float(q.y))
                }
            }
            var result = estimate
            if let pairs = LucasKanade.pairs(pyramid, LucasKanade.pyramid(warped), points),
               let fit = MaskMotionFit.fit(from: pairs.0, to: pairs.1, mode: mode),
               fit.inliers >= max(8, points.count / 5) {
                // `fit` maps template crop pixels to warped crop pixels; back to frame pixels, applied before `rel`.
                let e = MaskMotion(translation: Vec2(Double(-ox), Double(-oy))).then(fit.motion)
                    .then(MaskMotion(translation: Vec2(Double(ox), Double(oy))))
                result = motion.then(e).then(rel)
            }
            return (result, correlation(result.then(.identity), motionBack: back, gray))
        }

        /// Pearson correlation of the template and the frame at the sample points under `estimate`.
        private func correlation(_ estimate: MaskMotion, motionBack back: MaskMotion, _ gray: LucasKanade.Gray) -> Double {
            let rel = back.then(estimate)
            var a: [Double] = [], b: [Double] = []
            for p in points {
                let q = rel.apply(Vec2(Double(ox) + p.x, Double(oy) + p.y))
                a.append(Double(pyramid[0].at(Float(p.x), Float(p.y)))); b.append(Double(gray.at(Float(q.x), Float(q.y))))
            }
            let n = Double(a.count)
            let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
            var saa = 0.0, sbb = 0.0, sab = 0.0
            for i in a.indices { let x = a[i] - ma, y = b[i] - mb; saa += x * x; sbb += y * y; sab += x * y }
            guard saa > 1e-9, sbb > 1e-9 else { return 0 }
            return max(0, sab / (saa * sbb).squareRoot())
        }
    }

    /// Distance from `p` to the nearest edge of the closed polygon.
    static func edgeDistance(_ poly: [Vec2], _ p: Vec2) -> Double {
        var best = Double.infinity
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count], ab = b - a
            let l2 = ab.x * ab.x + ab.y * ab.y
            let t = l2 > 0 ? min(max(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / l2, 0), 1) : 0
            best = min(best, (a + ab * t - p).length)
        }
        return best
    }

    static func area(_ p: [Vec2]) -> Double {
        var s = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; s += a.x * b.y - b.x * a.y }
        return s / 2
    }
}
