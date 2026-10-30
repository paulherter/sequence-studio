import Foundation

/// Which devices run the subject tracking model (the Core ML compute units, named without Core ML: SQCore has no
/// Apple-only imports).
public enum SubjectTrackCompute: String, Sendable, Equatable {
    /// CPU and GPU: fastest on Pro / Max / Ultra chips (about 50 ms per frame), about 400 MB.
    case gpu
    /// CPU and Neural Engine: about 80 ms per frame, about 110 MB. The choice of every other Apple chip.
    case neuralEngine
}

/// A box in frame fractions (0...1, y down), `x0 <= x1`, `y0 <= y1`.
public struct SubjectTrackBox: Sendable, Equatable {
    public var x0: Double, y0: Double, x1: Double, y1: Double
    public init(x0: Double, y0: Double, x1: Double, y1: Double) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }

    public var width: Double { max(x1 - x0, 0) }
    public var height: Double { max(y1 - y0, 0) }
    public var area: Double { width * height }
    public func contains(_ p: Vec2) -> Bool { p.x >= x0 && p.x <= x1 && p.y >= y0 && p.y <= y1 }

    /// Grown by `dx` / `dy` on each side.
    public func grown(_ dx: Double, _ dy: Double) -> SubjectTrackBox { SubjectTrackBox(x0: x0 - dx, y0: y0 - dy, x1: x1 + dx, y1: y1 + dy) }

    public func intersects(_ o: SubjectTrackBox) -> Bool { min(x1, o.x1) > max(x0, o.x0) && min(y1, o.y1) > max(y0, o.y0) }

    /// Intersection over union with `o` (0 when they do not touch).
    public func iou(_ o: SubjectTrackBox) -> Double {
        let w = min(x1, o.x1) - max(x0, o.x0), h = min(y1, o.y1) - max(y0, o.y0)
        guard w > 0, h > 0 else { return 0 }
        let inter = w * h, union = area + o.area - inter
        return union > 0 ? inter / union : 0
    }
}

/// The model-free rules of subject tracking with a segment-and-remember model (EdgeTAM): how a frame maps onto the
/// model's square, how its answer becomes a matte, which prompt answer to keep.
///
/// The frame is stretched onto the model square (no letterbox): a point at frame fractions (u, v) is at
/// (u * 1024, v * 1024), and the 256 x 256 logits cover the whole frame. A matte is the logits resampled to the frame
/// size (bilinear, texel centers) and then put through the sigmoid, in that order (the reference code's order).
public enum SubjectTrackRules {
    /// Side of the model's input square (px).
    public static let modelSize = 1024
    /// Side of the model's mask logits.
    public static let logitSize = 256
    /// Largest logit written for a matte given as the subject (`logits(from:)`).
    public static let matteLogit: Float = 10

    /// The compute units for this Mac, nil = the model does not run here (Intel: no Neural Engine, GPUs too slow for
    /// it; the subject mask stays on the system's segmentation). Never "all devices": that plan was the slowest to
    /// load and no faster to run.
    public static func compute(cpuBrand: String, isIntel: Bool, lowMemory: Bool) -> SubjectTrackCompute? {
        if isIntel { return nil }
        if lowMemory { return .neuralEngine }
        let brand = cpuBrand.lowercased()
        for big in [" pro", " max", " ultra"] where brand.contains(big) { return .gpu }
        return .neuralEngine
    }

    public static func modelPoint(_ p: Vec2) -> (x: Double, y: Double) { (p.x * Double(modelSize), p.y * Double(modelSize)) }

    public static func modelBox(_ b: SubjectTrackBox) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        let s = Double(modelSize)
        return (b.x0 * s, b.y0 * s, b.x1 * s, b.y1 * s)
    }

    /// Width (output pixels) of the soft band at a matte's edge: alpha runs from 0 to 1 across it.
    public static let matteEdgeWidth: Float = 2
    /// Smallest logit slope (per pixel) the edge distance divides by.
    public static let matteSlopeFloor: Float = 1e-4

    /// The matte (`width` x `height`) of `size` x `size` logits: bilinear resample, then alpha from each pixel's
    /// distance to the edge (`edgeAlpha`).
    public static func matte(logits: [Float], size: Int, width: Int, height: Int) -> SubjectMatte {
        precondition(logits.count == size * size && width > 0 && height > 0, "logits size mismatch")
        var out = [Float](repeating: 0, count: width * height)
        // Column taps once per matte.
        var x0s = [Int](repeating: 0, count: width), x1s = x0s, txs = [Float](repeating: 0, count: width)
        for x in 0..<width {
            let fx = min(max((Double(x) + 0.5) * Double(size) / Double(width) - 0.5, 0), Double(size - 1))
            x0s[x] = Int(fx); x1s[x] = min(Int(fx) + 1, size - 1); txs[x] = Float(fx - Double(Int(fx)))
        }
        logits.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let fy = min(max((Double(y) + 0.5) * Double(size) / Double(height) - 0.5, 0), Double(size - 1))
                    let r0 = Int(fy) * size, r1 = min(Int(fy) + 1, size - 1) * size, ty = Float(fy - Double(Int(fy)))
                    for x in 0..<width {
                        let a = src[r0 + x0s[x]], b = src[r0 + x1s[x]], c = src[r1 + x0s[x]], d = src[r1 + x1s[x]]
                        let top = a + (b - a) * txs[x], bottom = c + (d - c) * txs[x]
                        dst[y * width + x] = top + (bottom - top) * ty
                    }
                }
            }
        }
        return SubjectMatte(width: width, height: height, values: edgeAlpha(out, width: width, height: height))
    }

    /// Alpha of a resampled logit plane: the pixel's signed distance to the edge (logit / slope, in pixels), mapped
    /// to 0...1 across `matteEdgeWidth`. Inside the mask alpha is 1 however weak the logits are (sigmoid of the
    /// first frame's +0.5...2 on hair and beard gave 0.6-0.9, a see-through subject); 0.5 stays where the logits
    /// cross 0. The slope is the central difference (one-sided, doubled, at the border).
    public static func edgeAlpha(_ v: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: v.count)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let gx: Float = width < 2 ? 0 : x == 0 ? 2 * (v[i + 1] - v[i]) : x == width - 1 ? 2 * (v[i] - v[i - 1]) : v[i + 1] - v[i - 1]
                let gy: Float = height < 2 ? 0 : y == 0 ? 2 * (v[i + width] - v[i]) : y == height - 1 ? 2 * (v[i] - v[i - width]) : v[i + width] - v[i - width]
                let slope = max((gx * gx + gy * gy).squareRoot() * 0.5, matteSlopeFloor)
                out[i] = min(max(v[i] / slope * (1 / matteEdgeWidth) + 0.5, 0), 1)
            }
        }
        return out
    }

    /// `size` x `size` logits of a matte (a mask the user corrected, a frame tracked before): the model's memory of a
    /// frame can be made from them. 0.5 is the edge; fully in or out is `matteLogit`.
    public static func logits(from matte: SubjectMatte, size: Int) -> [Float] {
        var out = [Float](repeating: -matteLogit, count: size * size)
        for y in 0..<size {
            let py = (Double(y) + 0.5) * Double(matte.height) / Double(size)
            for x in 0..<size {
                let px = (Double(x) + 0.5) * Double(matte.width) / Double(size)
                out[y * size + x] = Float(matte.sample(px: px, py: py) - 0.5) * 2 * matteLogit
            }
        }
        return out
    }

    /// Share of the frame the logits call subject (> 0) and the box around it; nil when nothing is.
    public static func stats(logits: [Float], size: Int) -> (area: Double, box: SubjectTrackBox?) {
        var n = 0, minX = size, minY = size, maxX = -1, maxY = -1
        logits.withUnsafeBufferPointer { p in
            for y in 0..<size {
                let row = y * size
                for x in 0..<size where p[row + x] > 0 {
                    n += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard n > 0 else { return (0, nil) }
        let s = Double(size)
        return (Double(n) / (s * s), SubjectTrackBox(x0: Double(minX) / s, y0: Double(minY) / s, x1: Double(maxX + 1) / s, y1: Double(maxY + 1) / s))
    }

    /// The box around the subject of a matte (values >= 0.5); nil when it holds none.
    public static func box(of m: SubjectMatte) -> SubjectTrackBox? {
        var minX = m.width, minY = m.height, maxX = -1, maxY = -1
        m.values.withUnsafeBufferPointer { p in
            for y in 0..<m.height {
                let row = y * m.width
                for x in 0..<m.width where p[row + x] >= 0.5 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= 0 else { return nil }
        let w = Double(m.width), h = Double(m.height)
        return SubjectTrackBox(x0: Double(minX) / w, y0: Double(minY) / h, x1: Double(maxX + 1) / w, y1: Double(maxY + 1) / h)
    }

    /// A prompt box wider than this many times its instance's box is shrunk to the instance (a person box that took
    /// in neighbors, measured on the mask bench: 0.076 against a truth of 0.047).
    public static let promptBoxMaxRatio = 1.3

    /// The box of the connected piece of the matte (values >= 0.5, 4-connected, worked at <= 256 px) that holds the
    /// click, or the nearest piece when the click is off the subject; nil for a matte with no subject. Unlike
    /// `box(of:)` it does not join a neighbor that only shares the matte.
    public static func instanceBox(in m: SubjectMatte, at p: Vec2) -> SubjectTrackBox? {
        let side = 256
        let gw = min(m.width, side), gh = min(m.height, side)
        var grid = [Bool](repeating: false, count: gw * gh)
        var any = false
        for y in 0..<gh {
            let sy = min(Int((Double(y) + 0.5) * Double(m.height) / Double(gh)), m.height - 1)
            for x in 0..<gw {
                let sx = min(Int((Double(x) + 0.5) * Double(m.width) / Double(gw)), m.width - 1)
                if m.values[sy * m.width + sx] >= 0.5 { grid[y * gw + x] = true; any = true }
            }
        }
        guard any else { return nil }
        let cx = min(max(Int(p.x * Double(gw)), 0), gw - 1), cy = min(max(Int(p.y * Double(gh)), 0), gh - 1)
        var seed = cy * gw + cx
        if !grid[seed] {
            var best = Int.max
            for i in 0..<grid.count where grid[i] {
                let dx = i % gw - cx, dy = i / gw - cy
                if dx * dx + dy * dy < best { best = dx * dx + dy * dy; seed = i }
            }
        }
        var minX = gw, minY = gh, maxX = -1, maxY = -1
        var stack = [seed]
        grid[seed] = false
        while let i = stack.popLast() {
            let x = i % gw, y = i / gw
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < gw && ny >= 0 && ny < gh && grid[ny * gw + nx] {
                grid[ny * gw + nx] = false; stack.append(ny * gw + nx)
            }
        }
        return SubjectTrackBox(x0: Double(minX) / Double(gw), y0: Double(minY) / Double(gh), x1: Double(maxX + 1) / Double(gw), y1: Double(maxY + 1) / Double(gh))
    }

    /// The box of a person whose label an occluder may have split: the piece under the click (`instanceBox`) united with
    /// every other piece (values >= 0.5, 4-connected, worked at <= 256 px) of at least `minShare` of the biggest piece.
    /// Specks across the picture stay out; a head and a torso on either side of a table both stay in.
    public static func piecesBox(in m: SubjectMatte, at p: Vec2, minShare: Double = 0.05) -> SubjectTrackBox? {
        guard let click = instanceBox(in: m, at: p) else { return nil }
        let side = 256
        let gw = min(m.width, side), gh = min(m.height, side)
        var grid = [Bool](repeating: false, count: gw * gh)
        for y in 0..<gh {
            let sy = min(Int((Double(y) + 0.5) * Double(m.height) / Double(gh)), m.height - 1)
            for x in 0..<gw {
                let sx = min(Int((Double(x) + 0.5) * Double(m.width) / Double(gw)), m.width - 1)
                if m.values[sy * m.width + sx] >= 0.5 { grid[y * gw + x] = true }
            }
        }
        var pieces: [(count: Int, box: SubjectTrackBox)] = []
        for start in 0..<grid.count where grid[start] {
            var count = 0, minX = gw, minY = gh, maxX = -1, maxY = -1
            var stack = [start]
            grid[start] = false
            while let i = stack.popLast() {
                let x = i % gw, y = i / gw
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < gw && ny >= 0 && ny < gh && grid[ny * gw + nx] {
                    grid[ny * gw + nx] = false; stack.append(ny * gw + nx)
                }
            }
            pieces.append((count, SubjectTrackBox(x0: Double(minX) / Double(gw), y0: Double(minY) / Double(gh), x1: Double(maxX + 1) / Double(gw), y1: Double(maxY + 1) / Double(gh))))
        }
        let biggest = pieces.map(\.count).max() ?? 0
        var out = click
        for piece in pieces where Double(piece.count) >= minShare * Double(biggest) {
            out = SubjectTrackBox(x0: min(out.x0, piece.box.x0), y0: min(out.y0, piece.box.y0), x1: max(out.x1, piece.box.x1), y1: max(out.y1, piece.box.y1))
        }
        return out
    }

    /// What `seen` holds that `first` does not, kept to the pixels inside `box` (frame fractions): the area a second
    /// person-sized box clamped into `box` can contain its point in.
    public static func leftover(seen: [Float], first: [Float], within box: SubjectTrackBox, size: Int) -> [Float] {
        var out = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            let v = (Double(y) + 0.5) / Double(size)
            guard v >= box.y0, v <= box.y1 else { continue }
            for x in 0..<size {
                let u = (Double(x) + 0.5) / Double(size), i = y * size + x
                if u >= box.x0, u <= box.x1, seen[i] > 0, first[i] <= 0 { out[i] = 1 }
            }
        }
        return out
    }

    /// A standing person's share of the person box's height, and a person's width over height, for `clickBox`.
    public static let clickBoxHeight = 0.85
    public static let clickBoxAspect = 0.25

    /// A box for the one person under the click when the person box may hold several (touching people): as tall as a
    /// share of the person box, a person's width, centered on the click, kept inside the person box and the frame.
    public static func clickBox(click: Vec2, person: SubjectTrackBox) -> SubjectTrackBox {
        let h = person.height * clickBoxHeight, w = h * clickBoxAspect
        func place(_ c: Double, _ size: Double, _ lo: Double, _ hi: Double) -> (Double, Double) {
            let a = min(max(c - size / 2, lo), max(hi - size, lo))
            return (a, min(a + size, hi))
        }
        let x = place(click.x, w, max(person.x0, 0), min(person.x1, 1)), y = place(click.y, h, max(person.y0, 0), min(person.y1, 1))
        return SubjectTrackBox(x0: x.0, y0: y.0, x1: x.1, y1: y.1)
    }

    /// Whether the picked area (`seen`, logits) held several people: `first` is the model's mask for a person-sized
    /// box over the click (`clickBox`), `second` its mask for another person-sized box over what is left of `seen`.
    /// True when the two are as large as each other (0.8 to 1.25 times), hardly touch (<= 8% of either) and together
    /// cover most of `seen` (>= 75%). Measured on the mask bench: two fighters 0.03 / 0.02 overlap and 86% covered;
    /// a flying-legs dancer whose two looks were separate but covered 60%.
    public static func holdsSeveralPeople(first: [Float], second: [Float], seen: [Float], size: Int) -> Bool {
        guard first.count == size * size, second.count == size * size, seen.count == size * size else { return false }
        var a = 0, b = 0, both = 0, union = 0, area = 0
        for i in 0..<size * size {
            let p = first[i] > 0, q = second[i] > 0
            if p { a += 1 }
            if q { b += 1 }
            if p && q { both += 1 }
            if seen[i] > 0 { area += 1; if p || q { union += 1 } }
        }
        guard a > 0, b > 0, area > 0 else { return false }
        let ratio = Double(b) / Double(a)
        guard ratio >= 0.8, ratio <= 1.25 else { return false }
        guard Double(both) / Double(a) <= 0.08, Double(both) / Double(b) <= 0.08 else { return false }
        return Double(union) >= 0.75 * Double(area)
    }

    /// `box` as the model's prompt: when it is much larger than the instance the click meant (`promptBoxMaxRatio`),
    /// the instance's own bounds.
    public static func promptBox(_ box: SubjectTrackBox, instance: SubjectTrackBox?) -> SubjectTrackBox {
        guard let instance, instance.area > 0, box.area > promptBoxMaxRatio * instance.area else { return box }
        return instance
    }

    /// Pixels (logit grid) of erosion that take the outline slivers between two segmentations of one subject out of a
    /// held piece; the piece's part of `seen` must touch the answer within `heldTouch` pixels.
    public static let heldErosion = 1
    public static let heldTouch = 2
    /// A held piece is at most this share of the answer's area (a touching neighbor is about as large as the answer).
    public static let heldMaxShare = 0.35
    /// The overlap the model's answer for a held piece needs with it.
    public static let heldAgreement = 0.4
    /// Held pieces asked per pick.
    public static let heldLimit = 3
    /// A held piece is at least this many grid pixels (4 x 4 of 256 x 256): a phone held by a person a third of the
    /// frame tall is ~25. The segmentations' flecks along a body (9-60 pixels on the mask bench) cannot be told from
    /// it by size; the model's answer for them adds a fleck, and `others` takes out the ones of a neighbor.
    public static let heldMinPixels = 16
    /// A piece with more than this share in another person (`others`) is that person, not something held; one that
    /// touches another person (within `heldTouch`) is theirs too (a limb Vision's person mask cut short).
    public static let heldOtherShare = 0.3
    /// A piece whose box is more than this many times as long as wide is a strip along the person (a leg of someone
    /// behind them), not something held (a phone or a tablet is at most ~2).
    public static let heldMaxElongation = 4.0
    /// A piece with more than this share of its outline within `heldTouch` of the answer is a gap the answer surrounds
    /// (between an arm and the body, 0.76-1 on the mask bench), not something held out of the hand (0.37-0.69 with the
    /// real model, whose answer takes in part of the hand around it).
    public static let heldMaxEnclosed = 0.7
    /// A piece with at least this share in the picked person's own Vision person mask (`own`) is a limb the answer left
    /// out (a forearm and hand held up in front of the body, enclosed 0.83 on the maintainer's clip), held however much the
    /// answer surrounds it: a gap between arm and body is background, outside the person mask.
    public static let heldOwnShare = 0.6
    /// A limb is at least this share of the answer's area (0.12 on the maintainer's clip) and reaches the outline (enclosed at
    /// most `heldLimbMaxEnclosed`): the holes the coarse person mask covers (31-55 pixels, enclosed 0.85-1 on the mask
    /// bench's walking clip) are no limb.
    public static let heldLimbMinShare = 0.03
    public static let heldLimbMaxEnclosed = 0.95

    /// What the person holds and the model's answer left out (a phone in the hand: Vision's person mask, so the
    /// person's box prompt, excludes it; the system's foreground segmentation `seen` holds it). The largest piece of
    /// `seen` outside `answer` (logit grids of `size`) that is more than an outline sliver (`heldErosion`), is joined
    /// to the answer in `seen` (its part of `seen` outside the answer, slivers and a thin arm included, comes within
    /// `heldTouch` of it) and is at most `heldMaxShare` of it; as logits (+matteLogit in it), nil when none.
    public static func heldPiece(seen: [Float], answer: [Float], size: Int) -> [Float]? {
        heldPieces(seen: seen, answer: answer, size: size, limit: 1).first
    }

    /// The pieces of `heldPiece`, largest first, at most `limit` (each costs the leg one model call), none smaller
    /// than `heldMinPixels`; with `others` (the grid's pixels of people other than the picked one, > 0) none that is more
    /// than `heldOtherShare` in them; with `own` (the picked person's pixels, > 0) one at least `heldOwnShare` in them
    /// passes the `heldMaxEnclosed` rule.
    // shortcut: at most `heldLimit` pieces per pick; raise it when a clip shows a person holding more.
    public static func heldPieces(seen: [Float], answer: [Float], size: Int, limit: Int = heldLimit, others: [Float]? = nil,
                                  own: [Float]? = nil) -> [[Float]] {
        let n = size * size
        guard seen.count == n, answer.count == n else { return [] }
        // Unsafe buffers and only the window around `rest`: this runs on the pick, on the frame lane, in unoptimized
        // Debug builds too.
        var answerArea = 0, x0 = size, y0 = size, x1 = -1, y1 = -1
        seen.withUnsafeBufferPointer { s in answer.withUnsafeBufferPointer { a in
            for y in 0..<size {
                for x in 0..<size {
                    let i = y * size + x
                    if a[i] > 0 { answerArea += 1 } else if s[i] > 0 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
                }
            }
        } }
        guard answerArea > 0, x1 >= 0 else { return [] }
        // Everything below looks at most this far from a pixel of `rest`; the window's edge is the grid's or farther.
        let margin = heldErosion * 2 + heldTouch + 1
        let wx = max(x0 - margin, 0), wy = max(y0 - margin, 0)
        let w = min(x1 + margin, size - 1) - wx + 1, h = min(y1 + margin, size - 1) - wy + 1, wn = w * h
        func window(_ grid: [Float], _ test: (Float) -> Bool) -> [Bool] {
            var out = [Bool](repeating: false, count: wn)
            grid.withUnsafeBufferPointer { g in out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h { for x in 0..<w { o[y * w + x] = test(g[(wy + y) * size + wx + x]) } }
            } }
            return out
        }
        let inAnswer = window(answer) { $0 > 0 }
        var rest = window(seen) { $0 > 0 }
        for i in 0..<wn where inAnswer[i] { rest[i] = false }
        // Opened (eroded, then grown back inside `rest`): the outline slivers go, a piece keeps its own shape.
        let core = square(rest, width: w, height: h, radius: heldErosion, all: true)
        var opened = square(core, width: w, height: h, radius: heldErosion, all: false), any = false
        for i in 0..<wn where opened[i] { if rest[i] { any = true } else { opened[i] = false } }
        guard any else { return [] }
        let near = square(inAnswer, width: w, height: h, radius: heldTouch, all: false)
        func flood(_ start: Int, _ inside: [Bool], _ visited: inout [Bool]) -> [Int] {
            var piece: [Int] = [], stack = [start]
            visited[start] = true
            while let i = stack.popLast() {
                piece.append(i)
                let x = i % w, y = i / w
                if x > 0, inside[i - 1], !visited[i - 1] { visited[i - 1] = true; stack.append(i - 1) }
                if x < w - 1, inside[i + 1], !visited[i + 1] { visited[i + 1] = true; stack.append(i + 1) }
                if y > 0, inside[i - w], !visited[i - w] { visited[i - w] = true; stack.append(i - w) }
                if y < h - 1, inside[i + w], !visited[i + w] { visited[i + w] = true; stack.append(i + w) }
            }
            return piece
        }
        // Which parts of `rest` (with their slivers) reach the answer.
        var joined = [Bool](repeating: false, count: wn), seenRest = [Bool](repeating: false, count: wn)
        for start in 0..<wn where opened[start] && !seenRest[start] {
            let part = flood(start, rest, &seenRest)
            if part.contains(where: { near[$0] }) { for i in part { joined[i] = true } }
        }
        let people = others.flatMap { $0.count == n ? window($0) { $0 > 0 } : nil }
        let otherNear = people.map { square($0, width: w, height: h, radius: heldTouch, all: false) }
        let mine = own.flatMap { $0.count == n ? window($0) { $0 > 0 } : nil }
        var visited = [Bool](repeating: false, count: wn)
        var pieces: [[Int]] = []
        for start in 0..<wn where opened[start] && joined[start] && !visited[start] {
            let piece = flood(start, opened, &visited)
            guard piece.count >= heldMinPixels, Double(piece.count) <= heldMaxShare * Double(answerArea) else { continue }
            let xs = piece.map { $0 % w }, ys = piece.map { $0 / w }
            let pw = Double(xs.max()! - xs.min()! + 1), ph = Double(ys.max()! - ys.min()! + 1)
            guard max(pw, ph) <= heldMaxElongation * min(pw, ph) else { continue }
            // A 4-neighbor in `opened` is in this piece (it is one 4-connected part of it); on the window's edge is on
            // the grid's (the margin).
            let outline = piece.filter { i in
                let x = i % w, y = i / w
                return x == 0 || y == 0 || x == w - 1 || y == h - 1
                    || !opened[i - 1] || !opened[i + 1] || !opened[i - w] || !opened[i + w]
            }
            let enclosed = Double(outline.filter { near[$0] }.count) / Double(outline.count)
            let limb = mine.map { m in
                Double(piece.count) >= heldLimbMinShare * Double(answerArea) && enclosed <= heldLimbMaxEnclosed
                    && Double(piece.reduce(0) { $0 + (m[$1] ? 1 : 0) }) >= heldOwnShare * Double(piece.count)
            } ?? false
            guard limb || enclosed <= heldMaxEnclosed else { continue }
            if let people, Double(piece.reduce(0) { $0 + (people[$1] ? 1 : 0) }) > heldOtherShare * Double(piece.count) { continue }
            if let otherNear, piece.contains(where: { otherNear[$0] }) { continue }
            pieces.append(piece)
        }
        return pieces.sorted { $0.count > $1.count }.prefix(max(limit, 0)).map { piece in
            var out = [Float](repeating: -matteLogit, count: n)
            for i in piece { out[(wy + i / w) * size + wx + i % w] = matteLogit }
            return out
        }
    }

    /// `answer` joined with the model's answer for a held piece (`object`), kept to the piece's box grown by half its
    /// size each way: nil when that answer is not the piece (overlap below `heldAgreement` outside `answer`).
    public static func withHeld(answer: [Float], object: [Float], piece: [Float], size: Int) -> [Float]? {
        let n = size * size
        guard answer.count == n, object.count == n, piece.count == n, let box = stats(logits: piece, size: size).box else { return nil }
        let near = box.grown(max(box.width / 2, 2 / Double(size)), max(box.height / 2, 2 / Double(size)))
        var kept = object, both = 0, union = 0
        for y in 0..<size {
            let v = (Double(y) + 0.5) / Double(size)
            for x in 0..<size {
                let i = y * size + x, u = (Double(x) + 0.5) / Double(size)
                if !near.contains(Vec2(u, v)) { kept[i] = min(kept[i], -matteLogit); continue }
                guard answer[i] <= 0 else { continue }
                let p = kept[i] > 0, q = piece[i] > 0
                if p && q { both += 1 }
                if p || q { union += 1 }
            }
        }
        guard union > 0, Double(both) / Double(union) >= heldAgreement else { return nil }
        return (0..<n).map { max(answer[$0], kept[$0]) }
    }

    /// Square neighborhood of `radius`: every pixel in it set (`all`, erosion) or any (dilation). Separable.
    private static func square(_ m: [Bool], width: Int, height: Int, radius r: Int, all: Bool) -> [Bool] {
        // A running count of set pixels over the 2r+1 window along each row, then each column (outside the grid counts
        // as unset); unsafe buffers because this runs on the pick, on the frame lane, in unoptimized Debug builds too.
        let full = 2 * r + 1
        func pass(_ src: [Bool], horizontal: Bool) -> [Bool] {
            var out = [Bool](repeating: false, count: src.count)
            let lines = horizontal ? height : width, length = horizontal ? width : height
            src.withUnsafeBufferPointer { s in
                out.withUnsafeMutableBufferPointer { o in
                    for line in 0..<lines {
                        let base = horizontal ? line * width : line, step = horizontal ? 1 : width
                        var count = 0
                        for k in 0..<min(r, length) where s[base + k * step] { count += 1 }
                        for k in 0..<length {
                            let ahead = k + r, behind = k - r - 1
                            if ahead < length, s[base + ahead * step] { count += 1 }
                            if behind >= 0, s[base + behind * step] { count -= 1 }
                            o[base + k * step] = all ? count == full : count > 0
                        }
                    }
                }
            }
            return out
        }
        return pass(pass(m, horizontal: true), horizontal: false)
    }

    /// A point on the subject of a matte (frame fractions): its pixel nearest to the center of mass, which need not
    /// lie on the subject itself (a ring, a person with arms out). nil when the matte holds no subject.
    public static func interiorPoint(of m: SubjectMatte) -> Vec2? {
        var n = 0.0, sx = 0.0, sy = 0.0
        for y in 0..<m.height {
            for x in 0..<m.width where m.values[y * m.width + x] >= 0.5 { n += 1; sx += Double(x); sy += Double(y) }
        }
        guard n > 0 else { return nil }
        let cx = sx / n, cy = sy / n
        var best = Double.infinity, bx = 0, by = 0
        for y in 0..<m.height {
            let dy = (Double(y) - cy) * (Double(y) - cy)
            guard dy < best else { continue }
            for x in 0..<m.width where m.values[y * m.width + x] >= 0.5 {
                let d = dy + (Double(x) - cx) * (Double(x) - cx)
                if d < best { best = d; bx = x; by = y }
            }
        }
        return Vec2((Double(bx) + 0.5) / Double(m.width), (Double(by) + 0.5) / Double(m.height))
    }

    /// The logit at frame fractions `p` (nearest texel).
    public static func value(logits: [Float], size: Int, at p: Vec2) -> Float {
        let x = min(max(Int(p.x * Double(size)), 0), size - 1), y = min(max(Int(p.y * Double(size)), 0), size - 1)
        return logits[y * size + x]
    }

    /// Intersection over union of two logit grids' subjects (> 0); 1 when both are empty.
    public static func iou(_ a: [Float], _ b: [Float]) -> Double {
        var inter = 0, union = 0
        for i in 0..<min(a.count, b.count) {
            let p = a[i] > 0, q = b[i] > 0
            if p && q { inter += 1 }
            if p || q { union += 1 }
        }
        return union == 0 ? 1 : Double(inter) / Double(union)
    }

    /// A click without a box has three answers (part, object, whole). The rule for a pick: the largest of the
    /// candidates 1...3 the model itself rates at `floor` or better (the whole person, not the shirt); when it trusts
    /// none, the best rated one that is not empty. `areas` / `ious`: per mask token 0...3.
    public static func largestCandidate(areas: [Double], ious: [Float], floor: Float = 0.6) -> Int {
        let candidates = (1...3).filter { $0 < areas.count && $0 < ious.count && areas[$0] > 0 }
        let trusted = candidates.filter { ious[$0] >= floor }
        if let best = trusted.max(by: { areas[$0] < areas[$1] }) { return best }
        return candidates.max(by: { ious[$0] < ious[$1] }) ?? 1
    }
}

/// Says when a tracked frame no longer shows the subject. The model's own "object present" score never reported an
/// absent subject on the measured clips, so the mask itself is judged against the frames found before it:
/// - an empty mask is lost;
/// - a mask under `shrink` of the usual area (the median of the last found frames) is lost: the track holds on to a
///   scrap of the subject or of what hides it;
/// - a mask over `grow` times the usual area whose box hardly overlaps the last one is lost: it flooded the background;
/// - a mask far from where the subject was on the frame before is lost: it jumped to something that looks alike.
/// A lost frame does not move the reference, so the subject is found again when it looks as before. So that no run
/// is locked out for good (a subject that really did change at a cut inside the clip), an odd state that holds for
/// `settle` frames in a row is taken as the subject.
public struct SubjectLostRule: Sendable {
    public var shrink = 0.25
    public var grow = 4.0
    public var minOverlap = 0.3
    public var settle = 4
    /// A mask under this share of the frame (49 of the 256 x 256 logit pixels) is lost, whatever the subject's usual size.
    public var tiny = 49.0 / 65536
    /// Distance from the frame edge that counts as touching it.
    public var edge = 0.01
    /// Found areas the usual area is the median of.
    public var window = 5

    private var areas: [Double] = []
    private var last: SubjectTrackBox?
    /// The frame before this one was found (only then a far jump says anything: after a gap the subject may be anywhere).
    private var lastFound = false
    private var odd: [(area: Double, box: SubjectTrackBox)] = []

    public init() {}

    /// Starts from a frame known to show the subject (the pick's frame).
    public init(area: Double, box: SubjectTrackBox) {
        if area > 0 { areas = [area]; last = box; lastFound = true }
    }

    private var usual: Double? {
        guard !areas.isEmpty else { return nil }
        return areas.sorted()[areas.count / 2]
    }

    /// Judges the mask of the next frame (in tracking order): share of the frame it covers and its box.
    public mutating func isLost(area: Double, box: SubjectTrackBox?) -> Bool {
        guard area > 0, let box else { odd = []; lastFound = false; return true }
        if area < tiny { odd = []; lastFound = false; return true }
        guard let usual, let last else { accept(area, box); return false }
        let ratio = area / usual
        // A subject leaving through a frame edge shrinks for real: its mask is right, not lost.
        let leaving = lastFound && Self.leaving(last, box, edge: edge)
        var suspicious = (ratio < shrink && !leaving) || (ratio > grow && box.iou(last) < minOverlap)
        if !suspicious, lastFound {
            // Room to move in one frame: its own size and a good part of the frame.
            let reach = last.grown(max(last.width, 0.15), max(last.height, 0.15))
            suspicious = !reach.intersects(box)
        }
        guard suspicious else { accept(area, box); return false }
        if let o = odd.last, area / o.area > 0.5, area / o.area < 2, box.iou(o.box) >= minOverlap {
            odd.append((area, box))
        } else {
            odd = [(area, box)]
        }
        if odd.count >= settle {
            areas = odd.map(\.area); self.last = box; lastFound = true; odd = []
            return false
        }
        lastFound = false
        return true
    }

    /// Both boxes touch a common frame edge and the box moved toward it (its center by at least `edge`): a subject
    /// that sits at the edge and merely collapses is not leaving.
    private static func leaving(_ a: SubjectTrackBox, _ b: SubjectTrackBox, edge: Double) -> Bool {
        let dx = (b.x0 + b.x1 - a.x0 - a.x1) / 2, dy = (b.y0 + b.y1 - a.y0 - a.y1) / 2
        return (a.x0 <= edge && b.x0 <= edge && dx <= -edge) || (a.x1 >= 1 - edge && b.x1 >= 1 - edge && dx >= edge)
            || (a.y0 <= edge && b.y0 <= edge && dy <= -edge) || (a.y1 >= 1 - edge && b.y1 >= 1 - edge && dy >= edge)
    }

    private mutating func accept(_ area: Double, _ box: SubjectTrackBox) {
        areas.append(area)
        if areas.count > window { areas.removeFirst(areas.count - window) }
        last = box; lastFound = true; odd = []
    }
}

/// Which tracked frames enter the tracker's memory: a frame is stored only when at least `minDistance` frames have
/// passed since the last stored one AND its mask is certain (mean |p - 0.5| of the logits as probabilities is at least
/// `minCertainty`), so blurry or uncertain masks never enter. The conditioning (first prompt) entry is not part of
/// this gate: it always stays.
public struct SubjectMemoryGate: Sendable, Equatable {
    public var minDistance: Int
    public var minCertainty: Double
    /// Frames seen since the last stored one (starts at "far enough": the first tracked frame may enter).
    private var sinceLast: Int

    /// The default admits every frame (distance 1, certainty 0): the behavior before the gate.
    public init(minDistance: Int = 1, minCertainty: Double = 0) {
        self.minDistance = max(minDistance, 1); self.minCertainty = minCertainty; sinceLast = self.minDistance
    }

    /// The tracker's setting, picked on the 13-clip mask benchmark (mean J&F 0.900 -> 0.905, no clip down by more than
    /// 0.004; certainty alone 0...0.48 changes nothing, 0.49 drops lindy-hop and walking).
    public static let tracker = SubjectMemoryGate(minDistance: 2, minCertainty: 0.45)

    /// Mean of |sigmoid(logit) - 0.5| (0...0.5). 0 for no logits.
    public static func certainty(logits: [Float]) -> Double {
        guard !logits.isEmpty else { return 0 }
        var sum = 0.0
        for l in logits { sum += abs(1 / (1 + Double(exp(-l))) - 0.5) }
        let c = sum / Double(logits.count)
        return c.isNaN ? 0 : c   // NaN logits count as uncertain (0), so certainty 0 still admits
    }

    /// Counts one tracked frame; true when it enters the memory (and restarts the distance).
    public mutating func admit(logits: [Float]) -> Bool {
        guard sinceLast >= minDistance, Self.certainty(logits: logits) >= minCertainty else { sinceLast += 1; return false }
        sinceLast = 1
        return true
    }

    /// Back to "the next frame may enter" (a new conditioning frame).
    public mutating func reset() { sinceLast = minDistance }
}

/// How many frames in a row the model calls empty enter its memory. The reference tracker remembers every one: once
/// the subject was out of view longer than the recent-frame memory (six slots), that memory holds only empty frames
/// and the model goes on answering "empty" after the subject is back (13-clip bench, exit-and-return: schoolgirls
/// never found again; docs/research/mask-tracking/BENCH-RECOVERY.md). Remembering only the first `limit` keeps frames
/// with the subject in the memory, so it is found again when it returns.
public struct SubjectAbsenceMemory: Sendable, Equatable {
    public var limit: Int
    private var run = 0

    /// The default remembers every empty frame (the behavior before this rule).
    public init(limit: Int = .max) { self.limit = max(limit, 0) }

    /// The tracker's setting, picked on the mask benchmark's recovery scenarios (BENCH-RECOVERY.md).
    public static let tracker = SubjectAbsenceMemory(limit: 2)

    /// Counts one frame the model called empty; true when it enters the memory.
    public mutating func admitsEmpty() -> Bool {
        if run < limit { run += 1; return true }
        return false
    }

    /// A frame with the subject on it (tracked or conditioned): the count starts over.
    public mutating func found() { run = 0 }
}

/// After a gap (at least `afterLost` frames in a row lost) a mask the model is not sure of (score under `minScore`)
/// is a re-acquisition only once it holds still: `settle` weak masks in a row, each within `areaTolerance` of the one
/// before in area and overlapping it by `minOverlap` (box IoU). Until then the frame stays lost and out of the memory.
/// Measured on the mask benchmark (BENCH-RECOVERY.md): with the subject hidden the model finds a look-alike (judo, box
/// occlusion: the other fighter at score 0.2 to 0.6, its area jumping 30 to 200% frame to frame), and a look-alike taken
/// once is followed from then on; the subject itself comes back at score 4 to 9, or, when it moved during the gap
/// (lady running), at 0.3 to 1 with the area steady within 2%.
public struct SubjectReacquireRule: Sendable, Equatable {
    public var minScore: Float
    public var afterLost: Int
    public var settle: Int
    public var areaTolerance: Double
    public var minOverlap: Double
    private var steady = 0
    private var last: (area: Double, box: SubjectTrackBox)?

    public init(minScore: Float, afterLost: Int, settle: Int, areaTolerance: Double = 0.15, minOverlap: Double = 0.6) {
        self.minScore = minScore; self.afterLost = max(afterLost, 1); self.settle = max(settle, 1)
        self.areaTolerance = areaTolerance; self.minOverlap = minOverlap
    }

    /// Off: every mask is taken as before this rule.
    public static let off = SubjectReacquireRule(minScore: -.infinity, afterLost: 1, settle: 1)
    /// The tracker's setting, picked on the mask benchmark's recovery scenarios (BENCH-RECOVERY.md).
    public static let tracker = SubjectReacquireRule(minScore: 2, afterLost: 3, settle: 3)

    /// True when a mask the model scored `score` (its area and box in frame fractions) may be taken after `lostRun`
    /// lost frames in a row.
    public mutating func accepts(score: Float, area: Double, box: SubjectTrackBox, lostRun: Int) -> Bool {
        if lostRun < afterLost || score >= minScore { empty(); return true }
        if let last, last.area > 0, abs(area / last.area - 1) <= areaTolerance, last.box.iou(box) >= minOverlap {
            steady += 1
        } else {
            steady = 1
        }
        last = (area, box)
        return steady >= settle
    }

    /// A frame without a mask: a weak mask after it starts the count over.
    public mutating func empty() { steady = 0; last = nil }

    public static func == (a: Self, b: Self) -> Bool {
        a.minScore == b.minScore && a.afterLost == b.afterLost && a.settle == b.settle
            && a.areaTolerance == b.areaTolerance && a.minOverlap == b.minOverlap
    }
}

/// A click made on a tracked frame (a correction) refines the tracked mask, it does not swap it for another one: a
/// mask that already answers the clicks stays as it is, else the model's answer that answers them and changes the
/// tracked mask least is taken. Replacing the tracked mask by the system's pick cost 0.024 mean J&F on the 13-clip
/// bench (docs/research/mask-tracking/BENCH-MIDCLIP.md).
public enum SubjectCorrectionRule {
    /// Share of the tracked mask an added click must keep (it adds, it does not move the mask).
    public static let keeps = 0.8
    /// Share of a removed click's answer that must lie on the tracked mask (it cuts, it does not move the mask).
    public static let inside = 0.8
    /// An added click grows the mask at most this much (area), a removed one shrinks it at most to `shrinkFloor`.
    public static let growLimit = 2.0
    public static let shrinkFloor = 0.25

    /// Whether the mask (logits, > 0 = subject) has every added point on it and every removed point off it. False
    /// for no points.
    public static func answers(_ points: [MagicPoint], logits: [Float], size: Int) -> Bool {
        guard !points.isEmpty, logits.count == size * size else { return false }
        return points.allSatisfy { (SubjectTrackRules.value(logits: logits, size: size, at: $0.position) > 0) != $0.subtract }
    }

    /// The same for a matte (>= 0.5 = subject, nearest pixel).
    public static func answers(_ points: [MagicPoint], matte m: SubjectMatte) -> Bool {
        guard !points.isEmpty, m.width > 0, m.height > 0 else { return false }
        return points.allSatisfy { p in
            let x = min(max(Int(p.position.x * Double(m.width)), 0), m.width - 1)
            let y = min(max(Int(p.position.y * Double(m.height)), 0), m.height - 1)
            return (m.values[y * m.width + x] >= 0.5) != p.subtract
        }
    }

    /// Index of the candidate (logits, the model's best rated first) that answers `points` and refines `tracked`:
    /// added points keep `keeps` of it and grow it at most `growLimit`, removed points stay `inside` it and leave at
    /// least `shrinkFloor`; of those the one closest to `tracked` (IoU). A lost frame (`tracked` empty): the first
    /// that answers. nil when none does.
    public static func refinement(_ candidates: [[Float]], tracked: [Float], points: [MagicPoint], size: Int) -> Int? {
        let trackedArea = tracked.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        let adds = points.contains { !$0.subtract }, removes = points.contains { $0.subtract }
        var best: (index: Int, iou: Double)?
        for (index, c) in candidates.enumerated() where c.count == tracked.count && answers(points, logits: c, size: size) {
            var both = 0, area = 0
            for i in 0..<c.count where c[i] > 0 { area += 1; if tracked[i] > 0 { both += 1 } }
            guard area > 0 else { continue }
            if trackedArea == 0 { return index }
            let t = Double(trackedArea), a = Double(area), b = Double(both)
            if adds, b / t < keeps || a > growLimit * t { continue }
            if removes, b / a < inside || a < shrinkFloor * t { continue }
            let iou = b / (t + a - b)
            if best == nil || iou > best!.iou { best = (index, iou) }
        }
        return best?.index
    }
}
