import Accelerate
import CoreVideo
import Foundation
import SQCore

/// The Quality edge step of a tracked subject matte: the tracking model's mask (256 x 256 for the whole picture) is
/// turned into soft alpha at the picture's own size, long edge at most `Settings.longEdge`.
///
/// A fast guided filter (He and Sun) with the color picture as guide: per pixel the alpha is modeled as a linear
/// function of the three color channels inside a small window. The model is solved at a reduced size, repeated with
/// the answer of the pass before as input (each pass is one step toward the matting Laplacian's solution), and
/// applied to the full-size picture, which is where the fine detail comes from. It only acts in a band around the
/// mask's edge: the inside and the outside stay as the tracking model gave them.
///
/// Not a matting network: when this was written there was none whose weights may be shipped in a free GPL app (the
/// choice is recorded in the design notes). Strands that differ in color from the background next to the mask's edge are taken in; strands far
/// outside the mask, or on a background of their own color, are not. The optional color step (`Settings.strands`)
/// raises the alpha of strands thinner than a coefficient pixel from their own color.
enum SubjectMatteRefiner {
    struct Settings: Sendable, Equatable {
        /// Long edge of the size the matte is made at; a larger picture is scaled down to it first.
        var longEdge = 1920
        /// Long edge of the size the filter's coefficients are solved at.
        var coefficientEdge = 480
        /// Box radius at the coefficient size.
        var radius = 3
        var epsilon: Float = 1e-4
        var passes = 2
        /// How fast the band saturates around the mask's edge (1: only the edge itself counts fully).
        var bandGain: Float = 3
        /// Box radius of the band at the coefficient size: how far from the mask's edge the picture may decide.
        var bandRadius = 5
        /// The full-size step works only inside the bounding box of the band (outside it the matte is the model's mask
        /// anyway). False: the whole frame, the reference the tests compare to.
        var restrictToBand = true
        /// Box radius at the coefficient size of the color step: inside the band, a pixel's alpha is where its color
        /// lies between the background and the subject colors seen nearby (strands thinner than a coefficient pixel
        /// take their alpha from their own color). 0: off.
        var colorRadius = 0
        /// Distance (0...1 RGB) the two nearby colors must differ by before the color step is trusted at all; at twice
        /// it, fully.
        var colorContrast: Float = 0.1
        /// How much of the color step's answer is taken where it is trusted (1: all of it).
        var colorMix: Float = 1
        /// The color step only raises alpha (strands outside the mask), never lowers it.
        var colorAddsOnly = false
        /// The color step is trusted less the further a pixel's color lies off the line between the two nearby colors.
        var colorOnLine = false
        /// With `colorAddsOnly`: alpha is raised only as far as the guided step already gave some.
        var colorNeedsSupport = false
        /// Box radius at the coefficient size of the keep step: where the model is sure of a pixel (mask over 0.5,
        /// fully from 0.9) and its color is not the background's seen nearby, the filter may not lower its alpha.
        /// A part thinner than the filter's window (a phone held out in the hand) otherwise takes the window's
        /// average and turns see-through. 0: off.
        var keepRadius = 10
        /// Distance (0...1 RGB) from the nearby background color at which a pixel starts to count as something
        /// else (at twice it, fully); at least twice the background's own spread.
        var keepContrast: Float = 0.1

        /// The color step for strands: it only raises alpha, on the line between the two nearby colors, where the
        /// guided step gave some.
        // shortcut: off by default (`SQ_SUBJECT_MASK_STRANDS=1` in `SubjectTrackLeg`): on the 13-clip bench it lowers
        // J&F 0.9216 -> 0.9203, whose polygon labels leave hair out; switch on when a bench with soft-alpha truth shows the gain.
        static let strands = Settings(colorRadius: 10, colorAddsOnly: true, colorOnLine: true, colorNeedsSupport: true)
    }

    /// The guide picture as three planes, 0...1, with the full-size work planes of one frame. A leg keeps one and
    /// loads every frame into it, so a frame allocates nothing at the picture's size but the matte it returns.
    final class Picture {
        private(set) var width = 0
        private(set) var height = 0
        fileprivate(set) var r: [Float] = []
        fileprivate(set) var g: [Float] = []
        fileprivate(set) var b: [Float] = []
        /// Takes the frame's fourth channel on load (the conversion writes four planes), then the filter's
        /// full-size intermediate.
        fileprivate var work: [Float] = []
        /// The model's mask at the picture's size.
        fileprivate var mask: [Float] = []
        /// The frame scaled down, when it is larger than the size it is worked at.
        private var small: [UInt8] = []

        /// False: not a BGRA frame, too small to filter, or the conversion failed.
        func load(_ pb: CVPixelBuffer, longEdge: Int) -> Bool {
            guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return false }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            guard w >= 64, h >= 64 else { return false }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
            var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: CVPixelBufferGetBytesPerRow(pb))
            let size = SubjectMatteRefiner.workSize(width: w, height: h, longEdge: longEdge)
            let n = size.width * size.height
            if r.count != n {
                r = [Float](repeating: 0, count: n); g = r; b = r; work = r; mask = r
            }
            width = size.width; height = size.height
            if size.width == w, size.height == h { return planes(&src) }
            if small.count != n * 4 { small = [UInt8](repeating: 0, count: n * 4) }
            var dst = vImage_Buffer()
            let scaled = small.withUnsafeMutableBytes { s -> Bool in
                dst = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(size.height), width: vImagePixelCount(size.width), rowBytes: size.width * 4)
                return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
            guard scaled else { return false }
            return small.withUnsafeMutableBytes { s -> Bool in
                dst.data = s.baseAddress
                return planes(&dst)
            }
        }

        private func planes(_ from: inout vImage_Buffer) -> Bool {
            let w = width, h = height
            return r.withUnsafeMutableBytes { pr in g.withUnsafeMutableBytes { pg in b.withUnsafeMutableBytes { pb in work.withUnsafeMutableBytes { pa in
                func plane(_ p: UnsafeMutableRawBufferPointer) -> vImage_Buffer {
                    vImage_Buffer(data: p.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                }
                var dr = plane(pr), dg = plane(pg), db = plane(pb), da = plane(pa)
                let top: [Float] = [1, 1, 1, 1], bottom: [Float] = [0, 0, 0, 0]
                // The frame is B, G, R, A in memory: the "ARGB" planes come out in that order.
                return vImageConvert_ARGB8888toPlanarF(&from, &db, &dg, &dr, &da, top, bottom, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            } } } }
        }
    }

    /// Size a picture of `width` x `height` is worked at.
    static func workSize(width: Int, height: Int, longEdge: Int) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > longEdge, longEdge > 0 else { return (width, height) }
        let k = Double(longEdge) / Double(long)
        return (max(Int((Double(width) * k).rounded()), 1), max(Int((Double(height) * k).rounded()), 1))
    }

    /// An image operation of the system failed: there is no matte, the caller keeps the quick step.
    struct Failed: Error {}

    /// The matte at the size the picture is worked at, or nil when the frame cannot be a guide or an image operation
    /// failed (the caller keeps the quick step). `scratch`: the caller's picture to load the frame into.
    static func refine(_ matte: SubjectMatte, guide pb: CVPixelBuffer, settings: Settings = Settings(), scratch: Picture? = nil) -> SubjectMatte? {
        let picture = scratch ?? Picture()
        guard picture.load(pb, longEdge: settings.longEdge) else { return nil }
        return try? refine(matte, picture: picture, settings: settings)
    }

    /// `matte` may have any size: it is laid over the whole picture.
    static func refine(_ matte: SubjectMatte, picture: Picture, settings: Settings = Settings()) throws -> SubjectMatte {
        let w = picture.width, h = picture.height
        let k = max(1, Int((Double(max(w, h)) / Double(max(settings.coefficientEdge, 1))).rounded()))
        let lw = max(w / k, 1), lh = max(h / k, 1), n = lw * lh
        try scale(matte.values, matte.width, matte.height, into: &picture.mask, w, h)
        clip(&picture.mask)
        guard lw >= 16, lh >= 16 else { return SubjectMatte(width: w, height: h, values: picture.mask) }
        let mask = vDSP.clip(try scaled(matte.values, matte.width, matte.height, lw, lh), to: 0...1)
        let planes = [try scaled(picture.r, w, h, lw, lh), try scaled(picture.g, w, h, lw, lh), try scaled(picture.b, w, h, lw, lh)]
        let radius = max(settings.radius, 1)
        let means = try planes.map { try box($0, lw, lh, radius) }

        // The band: 1 around the mask's edge, 0 where the mask is plainly in or out within the band's reach.
        let near = try box(mask, lw, lh, max(settings.bandRadius, 1))
        var band = [Float](repeating: 0, count: n)
        for i in 0..<n { band[i] = min(max(4 * settings.bandGain * near[i] * (1 - near[i]), 0), 1) }
        let colors = settings.colorRadius > 0 ? try localColors(planes, near: near, lw, lh, radius: settings.colorRadius) : nil
        let background = settings.keepRadius > 0 ? try localBackground(planes, near: near, lw, lh, radius: settings.keepRadius) : nil

        // Inverse of the picture's covariance (+ epsilon) per window: the same for every pass.
        var inverse = [[Float]](repeating: [Float](repeating: 0, count: n), count: 6)
        do {
            var cov: [[Float]] = []
            for (a, b) in [(0, 0), (0, 1), (0, 2), (1, 1), (1, 2), (2, 2)] {
                var c = try box(vDSP.multiply(planes[a], planes[b]), lw, lh, radius)
                vDSP.subtract(c, vDSP.multiply(means[a], means[b]), result: &c)
                cov.append(c)
            }
            let e = settings.epsilon
            for i in 0..<n {
                let rr = cov[0][i] + e, rg = cov[1][i], rb = cov[2][i], gg = cov[3][i] + e, gb = cov[4][i], bb = cov[5][i] + e
                let c0 = gg * bb - gb * gb, c1 = rb * gb - rg * bb, c2 = rg * gb - rb * gg
                let det = rr * c0 + rg * c1 + rb * c2
                let d = abs(det) > 1e-20 ? 1 / det : 0
                inverse[0][i] = c0 * d; inverse[1][i] = c1 * d; inverse[2][i] = c2 * d
                inverse[3][i] = (rr * bb - rb * rb) * d; inverse[4][i] = (rb * rg - rr * gb) * d
                inverse[5][i] = (rr * gg - rg * rg) * d
            }
        }

        var input = mask
        var a = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3), b = [Float](repeating: 0, count: n)
        for pass in 0..<max(settings.passes, 1) {
            let meanInput = try box(input, lw, lh, radius)
            var cross: [[Float]] = []
            for c in 0..<3 {
                var x = try box(vDSP.multiply(planes[c], input), lw, lh, radius)
                vDSP.subtract(x, vDSP.multiply(means[c], meanInput), result: &x)
                cross.append(x)
            }
            for i in 0..<n {
                let x = cross[0][i], y = cross[1][i], z = cross[2][i]
                let ar = inverse[0][i] * x + inverse[1][i] * y + inverse[2][i] * z
                let ag = inverse[1][i] * x + inverse[3][i] * y + inverse[4][i] * z
                let ab = inverse[2][i] * x + inverse[4][i] * y + inverse[5][i] * z
                a[0][i] = ar; a[1][i] = ag; a[2][i] = ab
                b[i] = meanInput[i] - ar * means[0][i] - ag * means[1][i] - ab * means[2][i]
            }
            for c in 0..<3 { a[c] = try box(a[c], lw, lh, radius) }
            b = try box(b, lw, lh, radius)
            guard pass + 1 < max(settings.passes, 1) else { break }
            // The next pass starts from this one's answer inside the band and from the mask outside it.
            for i in 0..<n {
                let q = min(max(a[0][i] * planes[0][i] + a[1][i] * planes[1][i] + a[2][i] * planes[2][i] + b[i], 0), 1)
                input[i] = mask[i] + band[i] * (q - mask[i])
            }
        }

        // Applied to the full-size picture, inside the band's bounding box: outside it the matte is the model's mask.
        // The matte that is returned is the plane made here.
        var lx0 = 0, ly0 = 0, lx1 = lw, ly1 = lh
        if settings.restrictToBand {
            lx0 = lw; ly0 = lh; lx1 = 0; ly1 = 0
            for y in 0..<lh {
                for x in 0..<lw where band[y * lw + x] > 0.02 {
                    if x < lx0 { lx0 = x }
                    if x >= lx1 { lx1 = x + 1 }
                    if y < ly0 { ly0 = y }
                    if y >= ly1 { ly1 = y + 1 }
                }
            }
            // One coefficient pixel of margin for the resampling's reach.
            lx0 = max(lx0 - 1, 0); ly0 = max(ly0 - 1, 0); lx1 = min(lx1 + 1, lw); ly1 = min(ly1 + 1, lh)
            guard lx1 > lx0, ly1 > ly0 else { return SubjectMatte(width: w, height: h, values: picture.mask) }
        }
        let fx0 = lx0 * w / lw, fy0 = ly0 * h / lh
        let fx1 = lx1 == lw ? w : lx1 * w / lw, fy1 = ly1 == lh ? h : ly1 * h / lh
        let cw = fx1 - fx0, ch = fy1 - fy0
        let whole = cw == w && ch == h
        func crop(_ v: [Float], _ vw: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [Float] {
            if x0 == 0, y0 == 0, x1 == vw, y1 * vw == v.count { return v }
            var o = [Float](repeating: 0, count: (x1 - x0) * (y1 - y0))
            for y in y0..<y1 { o.replaceSubrange((y - y0) * (x1 - x0)..<(y - y0 + 1) * (x1 - x0), with: v[(y * vw + x0)..<(y * vw + x1)]) }
            return o
        }
        func resized(_ v: [Float]) throws -> [Float] {
            try scaled(crop(v, lw, lx0, ly0, lx1, ly1), lx1 - lx0, ly1 - ly0, cw, ch)
        }
        var fine = try resized(b)
        var tmp = [Float](repeating: 0, count: cw * ch)
        for c in 0..<3 {
            try scale(crop(a[c], lw, lx0, ly0, lx1, ly1), lx1 - lx0, ly1 - ly0, into: &tmp, cw, ch)
            multiply(&tmp, whole ? (c == 0 ? picture.r : c == 1 ? picture.g : picture.b) : crop(c == 0 ? picture.r : c == 1 ? picture.g : picture.b, w, fx0, fy0, fx1, fy1))
            add(&fine, tmp)
        }
        clip(&fine)
        var weight = try resized(band)
        clip(&weight)
        var base = whole ? picture.mask : crop(picture.mask, w, fx0, fy0, fx1, fy1)
        subtract(&fine, base)
        multiply(&fine, weight)
        add(&fine, base)
        if let colors {
            // The color step at full size: each band pixel's color projected on the line from the nearby background
            // color to the nearby subject color, taken where the two differ enough and both were seen.
            let local = try colors.map { try resized($0) }
            let crops = whole ? [picture.r, picture.g, picture.b] : [picture.r, picture.g, picture.b].map { crop($0, w, fx0, fy0, fx1, fy1) }
            let low = settings.colorContrast, mix = settings.colorMix
            for i in 0..<(cw * ch) {
                // The resampling may overshoot a little: the weight stays within 0...1.
                let wgt = min(weight[i] * min(max(local[6][i], 0), 1), 1)
                guard wgt > 0.01 else { continue }
                let dr = local[0][i] - local[3][i], dg = local[1][i] - local[4][i], db = local[2][i] - local[5][i]
                let d2 = dr * dr + dg * dg + db * db
                let trust = min(max((d2.squareRoot() - low) / low, 0), 1)
                guard trust > 0 else { continue }
                let er = crops[0][i] - local[3][i], eg = crops[1][i] - local[4][i], eb = crops[2][i] - local[5][i]
                let p = (er * dr + eg * dg + eb * db) / d2
                var t = trust
                if settings.colorOnLine {
                    // How far the color is off the line between the two: a third color (another part of the subject,
                    // something else in the background) is not a mix of these two.
                    let ox = er - p * dr, oy = eg - p * dg, oz = eb - p * db
                    t *= min(max(1 - (ox * ox + oy * oy + oz * oz).squareRoot() / (0.5 * d2.squareRoot()), 0), 1)
                }
                let target = min(max(p, 0), 1)
                if settings.colorAddsOnly {
                    guard target > fine[i] else { continue }
                    // Raised only where the guided step already gave some alpha (0.2 and up: fully): a patch of the
                    // subject's color further out in the background is not a strand.
                    if settings.colorNeedsSupport { t *= min(fine[i] * 5, 1) }
                }
                fine[i] += mix * wgt * t * (target - fine[i])
            }
        }
        if let background {
            // The keep step at full size: alpha the filter took from a pixel the model is sure of and whose color is
            // not the nearby background is given back.
            let local = try background.map { try resized($0) }
            let crops = whole ? [picture.r, picture.g, picture.b] : [picture.r, picture.g, picture.b].map { crop($0, w, fx0, fy0, fx1, fy1) }
            for i in 0..<(cw * ch) where fine[i] < base[i] && base[i] > 0.5 {
                let sure = min((base[i] - 0.5) / 0.4, 1)
                let seen = min(max(local[4][i], 0), 1)
                guard sure * seen > 0.01 else { continue }
                let er = crops[0][i] - local[0][i], eg = crops[1][i] - local[1][i], eb = crops[2][i] - local[2][i]
                let low = max(settings.keepContrast, 2 * max(local[3][i], 0))
                // Distance to the background color, and, where the subject's color was seen nearby, to the line
                // between the two: a mix of both (a soft edge) is what the filter is there to lower.
                let toBackground = (er * er + eg * eg + eb * eb).squareRoot()
                var distance = toBackground
                let inside = min(max(local[8][i], 0), 1)
                if inside > 0.01 {
                    let dr = local[5][i] - local[0][i], dg = local[6][i] - local[1][i], db = local[7][i] - local[2][i]
                    let d2 = max(dr * dr + dg * dg + db * db, 1e-6)
                    let p = min(max((er * dr + eg * dg + eb * db) / d2, 0), 1)
                    let ox = er - p * dr, oy = eg - p * dg, oz = eb - p * db
                    distance = inside * (ox * ox + oy * oy + oz * oz).squareRoot() + (1 - inside) * toBackground
                }
                let other = min(max((distance - low) / low, 0), 1)
                fine[i] += sure * seen * other * (base[i] - fine[i])
            }
        }
        if whole { return SubjectMatte(width: w, height: h, values: fine) }
        base = []
        var out = picture.mask
        for y in 0..<ch { out.replaceSubrange((fy0 + y) * w + fx0..<(fy0 + y) * w + fx0 + cw, with: fine[(y * cw)..<((y + 1) * cw)]) }
        return SubjectMatte(width: w, height: h, values: out)
    }

    /// The color step's local colors at the coefficient size: mean subject color (r, g, b) over the pixels plainly
    /// inside the mask within `radius`, mean background color (r, g, b) over those plainly outside, and how well both
    /// were seen (0...1): seven planes. `near`: the mask's box mean over the band's reach (0 or 1 = plainly out or in).
    static func localColors(_ planes: [[Float]], near: [Float], _ w: Int, _ h: Int, radius: Int) throws -> [[Float]] {
        let n = w * h
        let inside = near.map { $0 > 0.99 ? Float(1) : 0 }, outside = near.map { $0 < 0.01 ? Float(1) : 0 }
        let seenIn = try box(inside, w, h, radius), seenOut = try box(outside, w, h, radius)
        var out: [[Float]] = []
        for (mask, seen) in [(inside, seenIn), (outside, seenOut)] {
            for c in 0..<3 {
                var sum = try box(vDSP.multiply(planes[c], mask), w, h, radius)
                for i in 0..<n { sum[i] = seen[i] > 1e-4 ? sum[i] / seen[i] : 0 }
                out.append(sum)
            }
        }
        // Seen when at least 5 % of the window is plainly in and 5 % plainly out.
        out.append((0..<n).map { min(min(seenIn[$0], seenOut[$0]) * 20, 1) })
        return out
    }

    /// The keep step's colors at the coefficient size: mean color (r, g, b) over the pixels plainly outside the mask
    /// within `radius`, the spread of their colors around it (RGB distance, root of the mean square), how well it was
    /// seen (0...1, fully from 5 % of the window), then the mean color (r, g, b) of the pixels plainly inside and how
    /// well that was seen: nine planes. `near` as in `localColors`.
    static func localBackground(_ planes: [[Float]], near: [Float], _ w: Int, _ h: Int, radius: Int) throws -> [[Float]] {
        let n = w * h
        let outside = near.map { $0 < 0.01 ? Float(1) : 0 }, inside = near.map { $0 > 0.99 ? Float(1) : 0 }
        let seen = try box(outside, w, h, radius), seenIn = try box(inside, w, h, radius)
        var out: [[Float]] = []
        var square = [Float](repeating: 0, count: n)
        for c in 0..<3 {
            let masked = vDSP.multiply(planes[c], outside)
            var mean = try box(masked, w, h, radius)
            for i in 0..<n { mean[i] = seen[i] > 1e-4 ? mean[i] / seen[i] : 0 }
            vDSP.add(square, try box(vDSP.multiply(masked, planes[c]), w, h, radius), result: &square)
            out.append(mean)
        }
        var spread = [Float](repeating: 0, count: n)
        for i in 0..<n where seen[i] > 1e-4 {
            let m2 = out[0][i] * out[0][i] + out[1][i] * out[1][i] + out[2][i] * out[2][i]
            spread[i] = max(square[i] / seen[i] - m2, 0).squareRoot()
        }
        out.append(spread)
        out.append(seen.map { min($0 * 20, 1) })
        for c in 0..<3 {
            var mean = try box(vDSP.multiply(planes[c], inside), w, h, radius)
            for i in 0..<n { mean[i] = seenIn[i] > 1e-4 ? mean[i] / seenIn[i] : 0 }
            out.append(mean)
        }
        out.append(seenIn.map { min($0 * 20, 1) })
        return out
    }

    // In place, so a plane the picture keeps is neither copied nor read while it is written.
    private static func clip(_ v: inout [Float]) {
        var low: Float = 0, high: Float = 1
        v.withUnsafeMutableBufferPointer { p in vDSP_vclip(p.baseAddress!, 1, &low, &high, p.baseAddress!, 1, vDSP_Length(p.count)) }
    }

    private static func multiply(_ v: inout [Float], _ other: [Float]) {
        precondition(v.count == other.count)
        v.withUnsafeMutableBufferPointer { p in other.withUnsafeBufferPointer { o in vDSP_vmul(p.baseAddress!, 1, o.baseAddress!, 1, p.baseAddress!, 1, vDSP_Length(p.count)) } }
    }

    private static func add(_ v: inout [Float], _ other: [Float]) {
        precondition(v.count == other.count)
        v.withUnsafeMutableBufferPointer { p in other.withUnsafeBufferPointer { o in vDSP_vadd(p.baseAddress!, 1, o.baseAddress!, 1, p.baseAddress!, 1, vDSP_Length(p.count)) } }
    }

    /// `v` minus `other`.
    private static func subtract(_ v: inout [Float], _ other: [Float]) {
        precondition(v.count == other.count)
        v.withUnsafeMutableBufferPointer { p in other.withUnsafeBufferPointer { o in vDSP_vsub(o.baseAddress!, 1, p.baseAddress!, 1, p.baseAddress!, 1, vDSP_Length(p.count)) } }
    }

    static func scaled(_ values: [Float], _ w: Int, _ h: Int, _ toW: Int, _ toH: Int) throws -> [Float] {
        if w == toW, h == toH { return values }
        var out = [Float](repeating: 0, count: toW * toH)
        try scale(values, w, h, into: &out, toW, toH)
        return out
    }

    /// `out` must hold `toW * toH` values.
    static func scale(_ values: [Float], _ w: Int, _ h: Int, into out: inout [Float], _ toW: Int, _ toH: Int) throws {
        guard w > 0, h > 0, values.count >= w * h, out.count >= toW * toH else { throw Failed() }
        if w == toW, h == toH { out = values; return }
        let error = values.withUnsafeBytes { s in
            out.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(toH), width: vImagePixelCount(toW), rowBytes: toW * 4)
                return vImageScale_PlanarF(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        guard error == kvImageNoError else { throw Failed() }
    }

    /// Box mean of radius `radius`, edges extended.
    static func box(_ values: [Float], _ w: Int, _ h: Int, _ radius: Int) throws -> [Float] {
        let side = 2 * radius + 1
        let kernel = [Float](repeating: 1 / Float(side), count: side)
        var out = [Float](repeating: 0, count: w * h)
        guard values.count >= w * h else { throw Failed() }
        let error = values.withUnsafeBytes { s in
            out.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                return vImageSepConvolve_PlanarF(&src, &dst, nil, 0, 0, kernel, UInt32(side), kernel, UInt32(side), 0, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        guard error == kvImageNoError else { throw Failed() }
        return out
    }
}
