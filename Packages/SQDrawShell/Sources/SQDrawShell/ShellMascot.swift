import Foundation
import SQUIKit
import SQDrawKit

/// Pip's still poses on the DrawKit canvas (portable port of the Mac `SQMascotArt`, which is CoreGraphics). Curves are
/// flattened to polygons, the head gradient is drawn as horizontal slabs. Used by the export queue rows and the dialog
/// footer, and animated by `ShellMascotPlayer` (lens, floating marks, squeezed eyes for blinks, round caps).
public enum ShellMascot {
    // MARK: Affine

    struct Aff {
        var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
        /// `self` followed by `m` applied first to a point (CoreGraphics `concatenating` order of translate/rotate/scale calls).
        func concat(_ m: Aff) -> Aff {
            Aff(a: a * m.a + c * m.b, b: b * m.a + d * m.b, c: a * m.c + c * m.d, d: b * m.c + d * m.d,
                tx: a * m.tx + c * m.ty + tx, ty: b * m.tx + d * m.ty + ty)
        }
        static func move(_ x: Double, _ y: Double) -> Aff { Aff(tx: x, ty: y) }
        static func scale(_ x: Double, _ y: Double) -> Aff { Aff(a: x, d: y) }
        static func rotate(_ deg: Double) -> Aff {
            let r = deg * .pi / 180
            return Aff(a: cos(r), b: sin(r), c: -sin(r), d: cos(r))
        }
        func apply(_ p: CGPoint) -> CGPoint {
            CGPoint(x: a * Double(p.x) + c * Double(p.y) + tx, y: b * Double(p.x) + d * Double(p.y) + ty)
        }
        var meanScale: Double { sqrt(abs(a * d - b * c)) }
    }

    // MARK: Path (art space, flattened while building)

    struct Path {
        var pts: [CGPoint] = []
        private var cur = CGPoint.zero
        static let steps = 10
        mutating func move(_ x: Double, _ y: Double) { cur = CGPoint(x: x, y: y); pts = [cur] }
        mutating func line(_ x: Double, _ y: Double) { cur = CGPoint(x: x, y: y); pts.append(cur) }
        mutating func quad(_ cx: Double, _ cy: Double, _ x: Double, _ y: Double) {
            let p0 = cur
            for i in 1...Self.steps {
                let t = Double(i) / Double(Self.steps), u = 1 - t
                pts.append(CGPoint(x: u * u * Double(p0.x) + 2 * u * t * cx + t * t * x,
                                   y: u * u * Double(p0.y) + 2 * u * t * cy + t * t * y))
            }
            cur = CGPoint(x: x, y: y)
        }
        mutating func cubic(_ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double, _ x: Double, _ y: Double) {
            let p0 = cur
            for i in 1...Self.steps {
                let t = Double(i) / Double(Self.steps), u = 1 - t
                let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
                pts.append(CGPoint(x: w0 * Double(p0.x) + w1 * c1x + w2 * c2x + w3 * x,
                                   y: w0 * Double(p0.y) + w1 * c1y + w2 * c2y + w3 * y))
            }
            cur = CGPoint(x: x, y: y)
        }
        static func ellipse(cx: Double, cy: Double, rx: Double, ry: Double) -> Path {
            var p = Path()
            for i in 0..<28 {
                let a = Double(i) / 28 * 2 * .pi
                p.pts.append(CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a)))
            }
            return p
        }
        static func roundedRect(_ r: CGRect, radius: Double) -> Path {
            var p = Path()
            let rad = min(radius, Double(min(r.width, r.height)) / 2)
            let corners: [(Double, Double, Double)] = [
                (Double(r.maxX) - rad, Double(r.minY) + rad, -90), (Double(r.maxX) - rad, Double(r.maxY) - rad, 0),
                (Double(r.minX) + rad, Double(r.maxY) - rad, 90), (Double(r.minX) + rad, Double(r.minY) + rad, 180),
            ]
            for (cx, cy, start) in corners {
                for i in 0...6 {
                    let a = (start + Double(i) / 6 * 90) * .pi / 180
                    p.pts.append(CGPoint(x: cx + rad * cos(a), y: cy + rad * sin(a)))
                }
            }
            return p
        }
        static func heart(_ cx: Double, _ cy: Double, _ s: Double) -> Path {
            var p = Path()
            p.move(cx, cy + 52 * s)
            p.cubic(cx - 92 * s, cy - 8 * s, cx - 54 * s, cy - 82 * s, cx, cy - 34 * s)
            p.cubic(cx + 54 * s, cy - 82 * s, cx + 92 * s, cy - 8 * s, cx, cy + 52 * s)
            return p
        }
    }

    // MARK: Colors

    static let headTop = DrawColor(hex: 0xFFFFFF), headBottom = DrawColor(hex: 0xC3C9D9)
    static let ink = DrawColor(hex: 0x17171B)
    static let headEdge = DrawColor(hex: 0x8D93A8, alpha: 0.6), armEdge = DrawColor(hex: 0x8D93A8, alpha: 0.75)
    static let cheek = DrawColor(hex: 0xFF8FA3), tongue = DrawColor(hex: 0xFF7389), drop = DrawColor(hex: 0x58AEF7)

    // MARK: Entry

    /// Draws the still of `anim` aspect-fitted and centered in `rect` (window points).
    public static func draw(_ anim: SQMascotAnim, in rect: CGRect, into c: inout Canvas) {
        let a = SQMascotLibrary.shared.animation(anim)
        let side = Double(min(rect.width, rect.height))
        var tight = a.tight
        var vb = a.viewBox
        if side <= 24 { tight = true; vb = CGRect(x: 125, y: 268, width: 774, height: 774) }
        draw(pose: a.still, tight: tight, viewBox: vb, in: rect, into: &c)
    }

    static func draw(pose p: SQMascotPose, tight: Bool, viewBox vb: CGRect, in rect: CGRect, into c: inout Canvas) {
        if p[.hide] >= 0.5 { return }
        let s = Double(min(rect.width, rect.height)) / Double(max(vb.width, vb.height))
        let ox = Double(rect.midX) - Double(vb.width) * s / 2 - Double(vb.minX) * s
        let oy = Double(rect.midY) - Double(vb.height) * s / 2 - Double(vb.minY) * s
        let base = Aff.move(ox, oy).concat(.scale(s, s))
        var m = base
        m = m.concat(.move(p[.tx], p[.ty])).concat(.move(512, 653)).concat(.rotate(p[.rot])).concat(.move(-512, -653))
        m = m.concat(.move(512, 1026)).concat(.scale(p[.sx], p[.sy])).concat(.move(-512, -1026))
        let g = Gfx(m: m)
        let edge = tight ? 10.0 : 8.0
        if !tight, p[.hL] > 3 {
            let h = Gfx(m: m.concat(.move(824, 742)).concat(.rotate(p[.hd])).concat(.move(-824, -742)))
            let arm = Path.roundedRect(CGRect(x: 777, y: 742 - p[.hL] - 47, width: 94, height: p[.hL] + 94), radius: 47)
            h.gradient(arm, &c)
            h.stroke(arm, width: 8, armEdge, closed: true, &c)
        }
        let head = headPath
        g.gradient(head, &c)
        g.stroke(head, width: edge, headEdge, closed: true, &c)
        if p[.dps] > 0.03 {
            var d = Path()
            let k = 48 * 0.5523
            d.move(0, 0)
            d.cubic(0, 0, -48, 66, -48, 100)
            d.cubic(-48, 100 + k, -k, 148, 0, 148)
            d.cubic(k, 148, 48, 100 + k, 48, 100)
            d.cubic(48, 66, 0, 0, 0, 0)
            Gfx(m: m.concat(.move(p[.dpx], p[.dpy])).concat(.scale(p[.dps], p[.dps]))).fill(d, drop, &c)
        }
        face(p, Gfx(m: m.concat(.move(p[.fx], p[.fy]))), &c)
        if !tight, p[.mgs] > 0.03 { lens(p, g, &c) }
        if !tight { marks(p, Gfx(m: base), &c) }
    }

    static let violet = DrawColor(hex: 0xA48CF0), lensFill = DrawColor(hex: 0xDFE6FF), spark = DrawColor(hex: 0xF7B23B)
    static let heartColor = DrawColor(hex: 0xF2577F), ok = DrawColor(hex: 0x30C463)

    static func lens(_ p: SQMascotPose, _ g: Gfx, _ c: inout Canvas) {
        let lg = Gfx(m: g.m.concat(.move(p[.mgx], p[.mgy])).concat(.scale(p[.mgs], p[.mgs])))
        let circle = Path.ellipse(cx: 0, cy: 0, rx: 70, ry: 70)
        lg.fill(circle, lensFill.alpha(Float(min(1, max(0, p[.mgo])))), &c)
        lg.stroke(circle, width: 30, violet, closed: true, &c)
        var h = Path()
        h.move(54, 54); h.line(114, 114)
        lg.stroke(h, width: 36, violet, closed: false, &c)
    }

    /// Badge, dots, Zs, sparkles and hearts: drawn outside the head's transform.
    static func marks(_ p: SQMascotPose, _ g: Gfx, _ c: inout Canvas) {
        func at(_ x: Double, _ y: Double, _ k: Double) -> Gfx { Gfx(m: g.m.concat(.move(x, y)).concat(.scale(k, k))) }
        func disc(_ x: Double, _ y: Double, _ r: Double, _ col: DrawColor, _ c: inout Canvas) {
            g.fill(.ellipse(cx: x, cy: y, rx: r, ry: r), col, &c)
        }
        if p[.bs] > 0.03 {
            let b = at(868, 968, p[.bs])
            b.fill(.ellipse(cx: 0, cy: 0, rx: 86, ry: 86), ok, &c)
            var t = Path()
            t.move(-40, 0); t.line(-12, 30); t.line(42, -32)
            b.stroke(t, width: 26, headTop, closed: false, &c)
        }
        let dots: [(Double, Double, Double, SQMascotKey)] = [(742, 228, 21, .d1), (812, 220, 26, .d2), (890, 228, 21, .d3)]
        for d in dots where p[d.3] > 0.03 { disc(d.0, d.1, d.2 * p[d.3], violet, &c) }
        let zs: [(Double, Double, Double, SQMascotKey, SQMascotKey)] = [
            (716, 214, 40, .z1, .z1y), (800, 236, 56, .z2, .z2y), (898, 196, 36, .z3, .z3y),
        ]
        for z in zs where p[z.3] > 0.03 {
            let q = z.2
            var zp = Path()
            zp.move(-q / 2, -q * 0.575); zp.line(q / 2, -q * 0.575); zp.line(-q / 2, q * 0.575); zp.line(q / 2, q * 0.575)
            at(z.0 + q / 2, z.1 + q * 0.575 + p[z.4], p[z.3]).stroke(zp, width: max(12, q * 0.26), violet, closed: false, &c)
        }
        if p[.sp] > 0.03 {
            let k = p[.sp]
            func star(_ x: Double, _ y: Double, _ r: Double, _ c: inout Canvas) {
                var sp = Path()
                sp.move(0, -r); sp.quad(0, 0, r, 0); sp.quad(0, 0, 0, r); sp.quad(0, 0, -r, 0); sp.quad(0, 0, 0, -r)
                at(x, y, k).fill(sp, spark, &c)
            }
            star(150, 262, 58, &c); star(900, 330, 40, &c); star(96, 560, 30, &c)
            disc(930, 560, 17 * k, heartColor, &c); disc(215, 1010, 15 * k, violet, &c); disc(880, 930, 13 * k, spark, &c)
        }
        if p[.h1] > 0.03 { g.fill(.heart(884, 250, 0.62 * p[.h1]), heartColor, &c) }
        if p[.h2] > 0.03 { g.fill(.heart(150, 330, 0.4 * p[.h2]), heartColor, &c) }
    }

    static let headPath: Path = {
        var p = Path()
        p.move(261, 280); p.line(763, 280)
        p.cubic(842.4, 280, 887, 324.6, 887, 404); p.line(887, 730)
        p.cubic(887, 777.9, 851.6, 814.1, 812, 844); p.line(605.8, 1000)
        p.cubic(559.5, 1035, 464.5, 1035, 418.2, 1000); p.line(212, 844)
        p.cubic(172.4, 814.1, 137, 777.9, 137, 730); p.line(137, 404)
        p.cubic(137, 324.6, 181.6, 280, 261, 280)
        return p
    }()

    // MARK: Drawing under a transform

    struct Gfx {
        var m: Aff
        func map(_ p: Path) -> [CGPoint] { p.pts.map(m.apply) }

        /// `self` scaled about the art point (x, y).
        func squeezed(at x: Double, _ y: Double, sx: Double, sy: Double) -> Gfx {
            Gfx(m: m.concat(.move(x, y)).concat(.scale(sx, sy)).concat(.move(-x, -y)))
        }

        func fill(_ p: Path, _ col: DrawColor, _ c: inout Canvas) { c.fill(polygon: map(p), col) }

        func stroke(_ p: Path, width: Double, _ col: DrawColor, closed: Bool, _ c: inout Canvas) {
            let pts = map(p)
            let w = CGFloat(max(width * m.meanScale, 0.75))
            if closed { c.stroke(polygon: pts, width: w, col) } else {
                c.strokePolyline(pts, width: w, col)
                for e in [pts.first, pts.last] {   // round caps
                    if let e { c.fill(ellipseIn: CGRect(x: e.x - w / 2, y: e.y - w / 2, width: w, height: w), col) }
                }
            }
        }

        /// The head gradient (art y 280...1046) as horizontal slabs of the polygon.
        func gradient(_ p: Path, _ c: inout Canvas) {
            let pts = map(p)
            guard let lo = pts.map(\.y).min(), let hi = pts.map(\.y).max() else { return }
            let n = max(2, min(24, Int((hi - lo) / 1.5)))
            let top = m.apply(CGPoint(x: 0, y: 280)).y, bottom = m.apply(CGPoint(x: 0, y: 1046)).y
            for i in 0..<n {
                let y0 = lo + (hi - lo) * CGFloat(i) / CGFloat(n)
                let y1 = lo + (hi - lo) * CGFloat(i + 1) / CGFloat(n) + (i == n - 1 ? 0 : 0.6)
                let mid = (y0 + y1) / 2
                let t = Float(min(max((mid - top) / max(bottom - top, 0.001), 0), 1))
                let col = DrawColor(headTop.r + (headBottom.r - headTop.r) * t, headTop.g + (headBottom.g - headTop.g) * t,
                                    headTop.b + (headBottom.b - headTop.b) * t)
                let slab = Self.clip(pts, y0, y1)
                if slab.count >= 3 { c.fill(polygon: slab, col) }
            }
        }

        /// Sutherland-Hodgman against the band y0...y1.
        static func clip(_ poly: [CGPoint], _ y0: CGFloat, _ y1: CGFloat) -> [CGPoint] {
            func cut(_ pts: [CGPoint], keep: (CGPoint) -> Bool, at y: CGFloat) -> [CGPoint] {
                var out: [CGPoint] = []
                for i in pts.indices {
                    let a = pts[i], b = pts[(i + 1) % pts.count]
                    let ia = keep(a), ib = keep(b)
                    if ia { out.append(a) }
                    if ia != ib {
                        let t = (y - a.y) / (b.y - a.y)
                        out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: y))
                    }
                }
                return out
            }
            let r = cut(poly, keep: { $0.y >= y0 }, at: y0)
            return r.isEmpty ? [] : cut(r, keep: { $0.y <= y1 }, at: y1)
        }
    }

    // MARK: Face

    static func face(_ p: SQMascotPose, _ g: Gfx, _ c: inout Canvas) {
        if p[.bl] > 0 {
            let a = Float(min(1, p[.bl]))
            for x in [286 - p[.bldx], 738 + p[.bldx]] {
                g.fill(.ellipse(cx: x, cy: p[.bly], rx: 50, ry: 30), cheek.alpha(a), &c)
            }
        }
        let xl = 384.5 + p[.ex] - p[.esp], xr = 639.5 + p[.ex] + p[.esp]
        func eyeK(_ e: SQMascotShape, _ k: Double) -> Double { (e.kind == "pill" || e.kind == "rpill" ? p.blink : 1) * k }
        eye(g, x: xl, side: 1, p.eL, ey: p[.ey], k: eyeK(p.eL, p.kEyeL), &c)
        eye(g, x: xr, side: -1, p.eR, ey: p[.ey], k: eyeK(p.eR, p.kEyeR), &c)
        for (x0, s, a) in [(xl, 1.0, p[.baL]), (xr, -1.0, p[.baR])] where a >= 0.06 {
            let mm = min(1, a)
            let x = x0 + s * p[.bdx], hl = p[.bhl] * mm, t = p[.btilt] * mm, cy = p[.bcy]
            var b = Path()
            b.move(x - s * hl, cy + t)
            b.quad(x, cy - p[.bbow] * mm, x + s * hl, cy - t)
            g.stroke(b, width: p[.bsw] * (0.6 + 0.4 * mm), ink, closed: false, &c)
        }
        mouth(g, p.m, k: p.kMouth, &c)
    }

    static func eye(_ g0: Gfx, x: Double, side s: Double, _ e: SQMascotShape, ey: Double, k: Double,
                    _ c: inout Canvas) {
        func v(_ i: Int) -> Double { i < e.a.count ? e.a[i] : 0 }
        var g = g0
        switch e.kind {
        case "pill", "rpill": break   // squeezed in height below
        case "up", "dn":
            let cy = v(2) + ey + (e.kind == "up" ? -1.0 : 1.0) * v(1) * 0.4
            if k < 0.995 { g = g0.squeezed(at: x, cy, sx: 0.6 + 0.4 * k, sy: max(0.1, k)) }
        case "chev", "heart":
            if k < 0.995 { g = g0.squeezed(at: x, v(0) + ey, sx: 0.6 + 0.4 * k, sy: max(0.1, k)) }
        default:
            if k < 0.995 { g = g0.squeezed(at: x, v(1) + ey, sx: 0.6 + 0.4 * k, sy: max(0.1, k)) }
        }
        switch e.kind {
        case "pill", "rpill":
            let w = v(0)
            var h = v(1), cy = v(2) + ey
            if k < 0.995 { let lo = min(h, 30), h2 = lo + (h - lo) * k; cy += (h - h2) * 0.12; h = h2 }
            var gg = g
            if e.kind == "rpill" { gg.m = g.m.concat(.move(x, cy)).concat(.rotate(v(3) * s)).concat(.move(-x, -cy)) }
            gg.fill(.roundedRect(CGRect(x: x - w / 2, y: cy - h / 2, width: w, height: h), radius: min(w, h) / 2), ink, &c)
        case "up", "dn":
            let dir = e.kind == "up" ? -1.0 : 1.0, top = v(2) + ey
            var p = Path()
            p.move(x - v(0), top); p.quad(x, top + dir * v(1), x + v(0), top)
            g.stroke(p, width: v(3), ink, closed: false, &c)
        case "chev":
            let cy = v(0) + ey
            var p = Path()
            p.move(x - s * 50, cy - 56); p.line(x + s * 44, cy); p.line(x - s * 50, cy + 56)
            g.stroke(p, width: 40, ink, closed: false, &c)
        case "heart":
            g.fill(.heart(x, v(0) + ey, v(1)), ink, &c)
        default:
            var p = Path()
            let cy = v(1) + ey
            p.move(x - v(0), cy); p.line(x + v(0), cy)
            g.stroke(p, width: v(2), ink, closed: false, &c)
        }
    }

    static func mouth(_ g0: Gfx, _ m: SQMascotShape, k: Double, _ c: inout Canvas) {
        func v(_ i: Int) -> Double { i < m.a.count ? m.a[i] : 0 }
        var g = g0
        if k < 0.995 {
            let ctr: (Double, Double)
            switch m.kind {
            case "smile": ctr = ((v(0) + v(1)) / 2, v(2) + v(3) / 2)
            case "open": ctr = (v(0), v(1) + v(3) / 2)
            case "o": ctr = (v(0), v(1))
            case "wavy": ctr = (512, v(0))
            default: ctr = (512, 795)
            }
            let q = 0.45 + 0.55 * k
            g = g0.squeezed(at: ctr.0, ctr.1, sx: q, sy: q)
        }
        switch m.kind {
        case "smile":
            var p = Path()
            p.move(v(0), v(2)); p.quad((v(0) + v(1)) / 2, v(2) + v(3), v(1), v(2))
            g.stroke(p, width: v(4), ink, closed: false, &c)
        case "open":
            let x = v(0), y = v(1), w = v(2), h = v(3), x0 = x - w / 2, x1 = x + w / 2
            var p = Path()
            p.move(x0, y); p.line(x1, y); p.quad(x1, y + h, x, y + h); p.quad(x0, y + h, x0, y)
            g.fill(p, ink, &c)
            g.stroke(p, width: 22, ink, closed: true, &c)
            if v(4) != 0 {
                var t = Path()
                t.move(x - w * 0.27, y + h * 0.74)
                t.quad(x, y + h * 0.42, x + w * 0.27, y + h * 0.74)
                t.quad(x + w * 0.14, y + h + 4, x, y + h + 4)
                t.quad(x - w * 0.14, y + h + 4, x - w * 0.27, y + h * 0.74)
                g.fill(t, tongue, &c)
            }
        case "o":
            g.fill(.ellipse(cx: v(0), cy: v(1), rx: v(2), ry: v(3)), ink, &c)
        case "wavy":
            let y = v(0)
            var p = Path()
            p.move(436, y); p.quad(461, y - 32, 486, y); p.quad(511, y + 32, 537, y); p.quad(563, y - 32, 588, y)
            g.stroke(p, width: 30, ink, closed: false, &c)
        default:
            var p = Path()
            p.move(452, 790); p.quad(512, 812, 572, 790)
            g.stroke(p, width: 33, ink, closed: false, &c)
            let x0 = 548 + v(0)
            var t = Path()
            t.move(x0, 800); t.line(x0 + 60, 800); t.line(x0 + 60, 816)
            t.cubic(x0 + 60, 816 + 16.5, x0 + 30 + 16.5, 846, x0 + 30, 846)
            t.cubic(x0 + 30 - 16.5, 846, x0, 816 + 16.5, x0, 816)
            g.fill(t, tongue, &c)
            g.stroke(t, width: 12, ink, closed: true, &c)
        }
    }
}
