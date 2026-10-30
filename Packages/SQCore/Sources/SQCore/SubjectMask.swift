import Foundation

// W9.8 SubjectMask: a person matte (from Vision, made in SQAnalysis) as a mask source, plus the pure maths around it:
// sampling (CPU reference of the shader), resampling, motion-compensated temporal smoothing and an edge-flicker measure.

/// Where a clip mask's shape comes from.
public enum MaskSource: String, Sendable, Hashable, Codable, CaseIterable {
    /// The keyframed bezier/rectangle/ellipse path.
    case path
    /// The person matte of the clip's frame (Vision person segmentation, temporally smoothed).
    case subject
    /// Magic: the picked objects (`ClipMask.magic` points), followed frame by frame by Track; the per-frame mattes live in
    /// the matte cache outside the project (`MagicSelection.cacheKey`), so a missing cache only asks for Track again.
    case magic
    /// C6 Picture: another video track's picture at the same sequence time (`ClipMask.pictureTrack`, read through
    /// `ClipMask.pictureChannel`). The evaluation adds that track's layers tagged `LayerRequest.matteFor` (v65).
    case picture
    /// v87 Color range: the clip's own picture, keyed by distance to a picked color (`ColorRangeKey`). Evaluated per pixel
    /// in the compositor on the picture the mask belongs to; no matte image, no polygon.
    case colorRange

    /// Mattes instead of a polygon (a color range reads the picture itself: neither).
    public var usesMatte: Bool { self != .path && self != .colorRange }

    /// Unknown values (a newer build's source) read as `.path`, so the mask keeps its stored path.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MaskSource(rawValue: raw) ?? .path
    }
}

/// C6: which part of the matte track's picture a Picture mask reads.
public enum MatteChannel: String, Sendable, Hashable, Codable, CaseIterable {
    /// The picture's alpha (its shape).
    case shape
    /// Rec.709 luma of the display-encoded straight color, times alpha.
    case brightness

    public var title: String {
        switch self {
        case .shape: "Shape"
        case .brightness: "Brightness"
        }
    }

    /// The matte value 0...1 of one pixel of straight (not premultiplied), display-encoded color.
    public func value(red r: Double, green g: Double, blue b: Double, alpha a: Double) -> Double {
        let alpha = min(max(a, 0), 1)
        switch self {
        case .shape: return alpha
        case .brightness: return min(max(0.2126 * r + 0.7152 * g + 0.0722 * b, 0), 1) * alpha
        }
    }

    /// Unknown values (a newer build's channel) read as `.shape`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MatteChannel(rawValue: raw) ?? .shape
    }
}

/// A single-channel matte, 0 (background) ... 1 (subject), row-major, row 0 at the top. Texel centers sit at (x + 0.5, y + 0.5)
/// in matte px; frame fractions map to matte px by scaling with the size (the matte covers the whole frame).
public struct SubjectMatte: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public var values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        precondition(width > 0 && height > 0 && values.count == width * height, "SubjectMatte size mismatch")
        self.width = width; self.height = height; self.values = values
    }

    public subscript(x: Int, y: Int) -> Float { values[y * width + x] }

    /// Sum of all values (px² of subject).
    public var area: Double { values.reduce(0) { $0 + Double($1) } }

    /// No value reaches one 8-bit step (the matte store keeps 8 bit): the matte covers nothing. A Magic pick or tracked
    /// frame like that counts as "nothing found", never as a mask that cuts the whole picture.
    public var isBlank: Bool { !values.contains { $0 >= 0.5 / 255 } }

    /// Value-weighted center in matte px (texel centers at +0.5), nil for an empty matte.
    public var centroid: Vec2? {
        var s = 0.0, sx = 0.0, sy = 0.0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let v = Double(values[row + x])
                if v == 0 { continue }
                s += v; sx += v * (Double(x) + 0.5); sy += v * (Double(y) + 0.5)
            }
        }
        return s > 1e-9 ? Vec2(sx / s, sy / s) : nil
    }

    /// Bilinear sample at matte px `(px, py)` (texel centers at +0.5), clamped to the edge texels.
    public func sample(px: Double, py: Double) -> Double {
        let fx = min(max(px - 0.5, 0), Double(width - 1)), fy = min(max(py - 0.5, 0), Double(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let a = Double(values[y0 * width + x0]), b = Double(values[y0 * width + x1])
        let c = Double(values[y1 * width + x0]), d = Double(values[y1 * width + x1])
        let top = a + (b - a) * tx, bottom = c + (d - c) * tx
        return top + (bottom - top) * ty
    }

    /// Bilinear sample at frame fractions `(u, v)` (0...1, origin top left), like the shader's sampler on the matte texture.
    public func sample(u: Double, v: Double) -> Double { sample(px: u * Double(width), py: v * Double(height)) }

    /// The same matte at another size (bilinear).
    public func resampled(width w: Int, height h: Int) -> SubjectMatte {
        if w == width && h == height { return self }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let v = (Double(y) + 0.5) / Double(h)
            for x in 0..<w { out[y * w + x] = Float(sample(u: (Double(x) + 0.5) / Double(w), v: v)) }
        }
        return SubjectMatte(width: w, height: h, values: out)
    }

    /// The matte moved by `d` matte px (bilinear, edges clamped: a subject cut by the frame edge stays cut there).
    public func translated(by d: Vec2) -> SubjectMatte {
        if d.x == 0 && d.y == 0 { return self }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let py = Double(y) + 0.5 - d.y
            for x in 0..<width { out[y * width + x] = Float(sample(px: Double(x) + 0.5 - d.x, py: py)) }
        }
        return SubjectMatte(width: width, height: height, values: out)
    }

    // MARK: Edge flicker measure

    /// How far the 0.5 contours of two same-size mattes lie apart, in matte px: from every contour point of one matte, the
    /// distance along its normal to the other's contour (searched up to `reach` px, a miss counts as `reach`), both ways.
    public static func edgeDelta(_ a: SubjectMatte, _ b: SubjectMatte, reach: Double = 16) -> (max: Double, mean: Double) {
        precondition(a.width == b.width && a.height == b.height, "edgeDelta needs equal sizes")
        var worst = 0.0, sum = 0.0, n = 0
        for (from, to) in [(a, b), (b, a)] {
            for p in from.contourPoints() {
                let d = from.distanceAlongNormal(from: p, to: to, reach: reach)
                worst = max(worst, d); sum += d; n += 1
            }
        }
        return (worst, n > 0 ? sum / Double(n) : 0)
    }

    /// Points (matte px) where the matte crosses 0.5 between horizontally or vertically adjacent texel centers.
    func contourPoints() -> [Vec2] {
        var pts: [Vec2] = []
        for y in 0..<height {
            for x in 0..<width {
                let v = Double(self[x, y]) - 0.5
                if x + 1 < width {
                    let w = Double(self[x + 1, y]) - 0.5
                    if (v < 0) != (w < 0), v != w { pts.append(Vec2(Double(x) + 0.5 + v / (v - w), Double(y) + 0.5)) }
                }
                if y + 1 < height {
                    let w = Double(self[x, y + 1]) - 0.5
                    if (v < 0) != (w < 0), v != w { pts.append(Vec2(Double(x) + 0.5, Double(y) + 0.5 + v / (v - w))) }
                }
            }
        }
        return pts
    }

    /// Distance from contour point `p` of this matte along its normal to the nearest 0.5 crossing of `other`.
    func distanceAlongNormal(from p: Vec2, to other: SubjectMatte, reach: Double) -> Double {
        let gx = sample(px: p.x + 0.5, py: p.y) - sample(px: p.x - 0.5, py: p.y)
        let gy = sample(px: p.x, py: p.y + 0.5) - sample(px: p.x, py: p.y - 0.5)
        let g = (gx * gx + gy * gy).squareRoot()
        guard g > 1e-9 else { return 0 }
        let n = Vec2(gx / g, gy / g)
        func f(_ s: Double) -> Double { other.sample(px: p.x + n.x * s, py: p.y + n.y * s) - 0.5 }
        let f0 = f(0)
        if abs(f0) < 1e-9 { return 0 }
        let step = 0.25
        var s = step
        while s <= reach + 1e-9 {
            for dir in [1.0, -1.0] {
                let prev = f(dir * (s - step)), cur = f(dir * s)
                if (prev < 0) != (cur < 0) || cur == 0 {
                    var lo = s - step, hi = s
                    for _ in 0..<30 {
                        let mid = (lo + hi) / 2
                        if (f(dir * mid) < 0) == (prev < 0) { lo = mid } else { hi = mid }
                    }
                    return (lo + hi) / 2
                }
            }
            s += step
        }
        return reach
    }
}

/// Temporal smoothing of per-frame person mattes, so segmentation edges do not flicker. Motion compensated: the smoothed
/// matte of the neighboring frame (index +-1, so forward and reverse playback both smooth) is moved onto the new matte's
/// centroid before blending, so a walking subject is followed without lag. Blending is gated by how far the edge moved
/// at each pixel (`edgeDisplacement`): edge wobble of a few px is averaged, a part that really moved (a head turning while
/// the body stands still, which the centroid does not see) takes the new matte, so it neither trails the motion nor leaves
/// a half-transparent ghost of the old position (DECISIONS 2026-10-07 "Magic mask tracking quality and corrections"). The last few results are kept by frame index: a
/// frame shown again (paused redraw) returns its result unchanged, and frames arriving out of order (parallel prefetch) blend
/// with whichever neighbor is there. A frame without a smoothed neighbor, a size change, an empty matte or a scene change
/// (subject jumps, grows/shrinks a lot, or the aligned shapes disagree) starts from the raw matte.
public struct SubjectMatteSmoother: Sendable {
    /// Weight of the new frame in the running average.
    public var newFrameWeight: Double
    /// When set, blending is gated per pixel by how far the edge moved (see the type doc); nil = plain blend.
    public var motionGate: MotionGate?

    /// Edge moves up to `wobble` matte px count as segmentation wobble and are averaged; from `motion` px on they are
    /// motion and the new matte is taken as is (linear in between).
    public struct MotionGate: Sendable, Hashable {
        public var wobble: Double
        public var motion: Double
        public init(wobble: Double, motion: Double) { self.wobble = wobble; self.motion = motion }
    }
    /// Results kept by frame index (oldest first).
    public var capacity: Int
    private var recent: [(frame: Int, matte: SubjectMatte)] = []

    public init(newFrameWeight: Double = 0.25, capacity: Int = 8, motionGate: MotionGate? = nil) {
        self.newFrameWeight = newFrameWeight; self.capacity = max(capacity, 2); self.motionGate = motionGate
    }

    public mutating func reset() { recent.removeAll() }

    /// The smoothed matte already made for `frameIndex`, if still kept.
    public func cached(frameIndex: Int) -> SubjectMatte? { recent.last { $0.frame == frameIndex }?.matte }

    /// Adds the raw matte of frame `frameIndex` and returns the smoothed matte for it (the kept one if that frame was done).
    public mutating func push(_ raw: SubjectMatte, frameIndex: Int) -> SubjectMatte {
        if let done = cached(frameIndex: frameIndex) { return done }
        let prev = recent.last { abs($0.frame - frameIndex) == 1 && $0.matte.width == raw.width && $0.matte.height == raw.height }
        let out = prev.map { blend(raw, onto: $0.matte) } ?? raw
        recent.append((frameIndex, out))
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        return out
    }

    private func blend(_ raw: SubjectMatte, onto prev: SubjectMatte) -> SubjectMatte {
        guard let cRaw = raw.centroid, let cPrev = prev.centroid else { return raw }
        let aRaw = raw.area, aPrev = prev.area
        let shift = cRaw - cPrev
        let diag = Double(max(raw.width, raw.height))
        if aRaw / aPrev > 1.5 || aPrev / aRaw > 1.5 || shift.length > 0.1 * diag { return raw }
        let moved = prev.translated(by: shift)
        var diff = 0.0
        for i in 0..<raw.values.count { diff += abs(Double(raw.values[i]) - Double(moved.values[i])) }
        if diff > 0.5 * aRaw { return raw }
        let k = Float(newFrameWeight)
        var out = moved.values
        guard let gate = motionGate else {
            for i in 0..<out.count { out[i] += (raw.values[i] - out[i]) * k }
            return SubjectMatte(width: raw.width, height: raw.height, values: out)
        }
        // Spread over a few px and soften, so the weight is one smooth field (a per-pixel switch makes stray contours).
        let w0 = raw.width, h0 = raw.height
        let disp = MatteRefine.boxBlur(MatteRefine.morph(Self.edgeDisplacement(raw, moved), width: w0, height: h0, radius: 2, erode: false),
                                       width: w0, height: h0, radius: 2)
        let r0 = Float(gate.wobble), r1 = Float(max(gate.motion, gate.wobble + 0.5))
        for i in 0..<out.count {
            // Weight of the new frame: k up to wobble reach, ramping to 1 (the new matte alone) at motion reach.
            let t = min(max((disp[i] - r0) / (r1 - r0), 0), 1)
            let w = k + (1 - k) * t
            out[i] += (raw.values[i] - out[i]) * w
        }
        return SubjectMatte(width: raw.width, height: raw.height, values: out)
    }

    /// Per pixel, how far the 0.5 edge moved between `a` and `b` (matte px) where they disagree (one inside, the other
    /// outside): distance to `a`'s edge plus distance to `b`'s edge (chamfer distances). 0 where they agree.
    static func edgeDisplacement(_ a: SubjectMatte, _ b: SubjectMatte) -> [Float] {
        let w = a.width, h = a.height, n = w * h
        let aIn = a.values.map { $0 >= 0.5 }, bIn = b.values.map { $0 >= 0.5 }
        let toAIn = distanceTransform(aIn, w, h), toAOut = distanceTransform(aIn.map { !$0 }, w, h)
        let toBIn = distanceTransform(bIn, w, h), toBOut = distanceTransform(bIn.map { !$0 }, w, h)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n where aIn[i] != bIn[i] {
            // Inside a, outside b: distance to a's outside plus distance to b's inside (each about the gap to that edge).
            out[i] = aIn[i] ? toAOut[i] + toBIn[i] : toAIn[i] + toBOut[i]
        }
        return out
    }

    /// Chamfer distance (1, sqrt 2) of every pixel to the nearest `true` pixel; a large value when there is none.
    static func distanceTransform(_ m: [Bool], _ w: Int, _ h: Int) -> [Float] {
        let far = Float(w + h)
        var out = m.map { $0 ? Float(0) : far }
        let s2 = Float(2).squareRoot()
        out.withUnsafeMutableBufferPointer { d in
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    var v = d[i]
                    if v == 0 { continue }
                    if x > 0 { v = min(v, d[i - 1] + 1) }
                    if y > 0 {
                        v = min(v, d[i - w] + 1)
                        if x > 0 { v = min(v, d[i - w - 1] + s2) }
                        if x + 1 < w { v = min(v, d[i - w + 1] + s2) }
                    }
                    d[i] = v
                }
            }
            for y in stride(from: h - 1, through: 0, by: -1) {
                for x in stride(from: w - 1, through: 0, by: -1) {
                    let i = y * w + x
                    var v = d[i]
                    if v == 0 { continue }
                    if x + 1 < w { v = min(v, d[i + 1] + 1) }
                    if y + 1 < h {
                        v = min(v, d[i + w] + 1)
                        if x + 1 < w { v = min(v, d[i + w + 1] + s2) }
                        if x > 0 { v = min(v, d[i + w - 1] + s2) }
                    }
                    d[i] = v
                }
            }
        }
        return out
    }
}
