import AppKit

// Draws one Pip pose with Core Graphics in the design's art space (1024 units, y down). Port of the design player's
// `draw`; colors are Theme.Mascot tokens. The context must be y-down (a flipped view).

extension Theme {
    public enum Mascot {
        public static let headTop = Theme.Splash.pipTop
        public static let headBottom = Theme.Splash.pipBottom
        public static let headEdge = Theme.hex(0x8D93A8, alpha: 0.6)
        public static let armEdge = Theme.hex(0x8D93A8, alpha: 0.75)
        public static let ink = Theme.Splash.pipFace
        public static let cheek = Theme.hex(0xFF8FA3)
        public static let tongue = Theme.hex(0xFF7389)
        public static let violet = Theme.hex(0xA48CF0)
        public static let lens = Theme.hex(0xDFE6FF)
        public static let spark = Theme.hex(0xF7B23B)
        public static let heart = Theme.hex(0xF2577F)
        public static let drop = Theme.hex(0x58AEF7)
        public static let ok = Theme.hex(0x30C463)
    }
}

public enum SQMascotArt {
    private static let leftEyeX = 384.5, rightEyeX = 639.5

    nonisolated(unsafe) private static let head: CGPath = {   // immutable after init
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 261, y: 280))
        p.addLine(to: CGPoint(x: 763, y: 280))
        p.addCurve(to: CGPoint(x: 887, y: 404), control1: CGPoint(x: 842.4, y: 280), control2: CGPoint(x: 887, y: 324.6))
        p.addLine(to: CGPoint(x: 887, y: 730))
        p.addCurve(to: CGPoint(x: 812, y: 844), control1: CGPoint(x: 887, y: 777.9), control2: CGPoint(x: 851.6, y: 814.1))
        p.addLine(to: CGPoint(x: 605.8, y: 1000))
        p.addCurve(to: CGPoint(x: 418.2, y: 1000), control1: CGPoint(x: 559.5, y: 1035), control2: CGPoint(x: 464.5, y: 1035))
        p.addLine(to: CGPoint(x: 212, y: 844))
        p.addCurve(to: CGPoint(x: 137, y: 730), control1: CGPoint(x: 172.4, y: 814.1), control2: CGPoint(x: 137, y: 777.9))
        p.addLine(to: CGPoint(x: 137, y: 404))
        p.addCurve(to: CGPoint(x: 261, y: 280), control1: CGPoint(x: 137, y: 324.6), control2: CGPoint(x: 181.6, y: 280))
        p.closeSubpath()
        return p
    }()

    nonisolated(unsafe) private static let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [Theme.Mascot.headTop.cgColor, Theme.Mascot.headBottom.cgColor] as CFArray, locations: [0, 1])!

    /// Draws `pose` (art space). `tight` omits the hand and the floating marks.
    public static func draw(_ p: SQMascotPose, tight: Bool, in ctx: CGContext) {
        if p[.hide] >= 0.5 { return }
        ctx.saveGState()
        ctx.translateBy(x: p[.tx], y: p[.ty])
        ctx.translateBy(x: 512, y: 653)
        ctx.rotate(by: p[.rot] * .pi / 180)
        ctx.translateBy(x: -512, y: -653)
        ctx.translateBy(x: 512, y: 1026)
        ctx.scaleBy(x: p[.sx], y: p[.sy])
        ctx.translateBy(x: -512, y: -1026)
        let edge = tight ? 10.0 : 8.0
        if !tight, p[.hL] > 3 {
            ctx.saveGState()
            ctx.translateBy(x: 824, y: 742)
            ctx.rotate(by: p[.hd] * .pi / 180)
            ctx.translateBy(x: -824, y: -742)
            let r = CGRect(x: 777, y: 742 - p[.hL] - 47, width: 94, height: p[.hL] + 94)
            let path = CGPath(roundedRect: r, cornerWidth: 47, cornerHeight: 47, transform: nil)
            fillGradient(path, in: ctx)
            ctx.setStrokeColor(Theme.Mascot.armEdge.cgColor)
            ctx.setLineWidth(8)
            ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
        }
        fillGradient(head, in: ctx)
        ctx.setStrokeColor(Theme.Mascot.headEdge.cgColor)
        ctx.setLineWidth(edge)
        ctx.addPath(head); ctx.strokePath()
        if p[.dps] > 0.03 { drop(p, in: ctx) }
        face(p, in: ctx)
        if !tight, p[.mgs] > 0.03 { lens(p, in: ctx) }
        ctx.restoreGState()
        if !tight { marks(p, in: ctx) }
    }

    private static func fillGradient(_ path: CGPath, in ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 280), end: CGPoint(x: 0, y: 1046),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // MARK: strokes

    private static func arc(_ ctx: CGContext, _ build: (CGMutablePath) -> Void, width: Double, color: NSColor = Theme.Mascot.ink) {
        let p = CGMutablePath()
        build(p)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.addPath(p); ctx.strokePath()
    }

    private static func fill(_ ctx: CGContext, _ path: CGPath, _ color: NSColor, alpha: Double = 1) {
        ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
        ctx.addPath(path); ctx.fillPath()
    }

    private static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    private static func squeezed(_ ctx: CGContext, at c: CGPoint, sx: Double, sy: Double, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: sx, y: sy)
        ctx.translateBy(x: -c.x, y: -c.y)
        body()
        ctx.restoreGState()
    }

    // MARK: face

    private static func face(_ p: SQMascotPose, in ctx: CGContext) {
        ctx.saveGState()
        if p[.fx] != 0 || p[.fy] != 0 { ctx.translateBy(x: p[.fx], y: p[.fy]) }
        if p[.bl] > 0 {
            let a = min(1, p[.bl])
            for x in [286 - p[.bldx], 738 + p[.bldx]] {
                fill(ctx, CGPath(ellipseIn: CGRect(x: x - 50, y: p[.bly] - 30, width: 100, height: 60), transform: nil),
                     Theme.Mascot.cheek, alpha: a)
            }
        }
        let xl = leftEyeX + p[.ex] - p[.esp], xr = rightEyeX + p[.ex] + p[.esp]
        let bl = p.blink
        func eyeK(_ s: SQMascotShape, _ k: Double) -> Double { (s.kind == "pill" || s.kind == "rpill" ? bl : 1) * k }
        eye(ctx, x: xl, side: 1, p.eL, ey: p[.ey], k: eyeK(p.eL, p.kEyeL))
        eye(ctx, x: xr, side: -1, p.eR, ey: p[.ey], k: eyeK(p.eR, p.kEyeR))
        brows(ctx, p, xl: xl, xr: xr)
        mouth(ctx, p.m, k: p.kMouth)
        ctx.restoreGState()
    }

    private static func eye(_ ctx: CGContext, x: Double, side s: Double, _ e: SQMascotShape, ey: Double, k: Double) {
        let a = e.a
        func v(_ i: Int) -> Double { i < a.count ? a[i] : 0 }
        var cy: Double
        var body: () -> Void
        switch e.kind {
        case "pill", "rpill":
            let w = v(0)
            var h = v(1)
            cy = v(2) + ey
            if k < 1 { let lo = min(h, 30), h2 = lo + (h - lo) * k; cy += (h - h2) * 0.12; h = h2 }
            let r = CGRect(x: x - w / 2, y: cy - h / 2, width: w, height: h)
            let c = cy, rot = e.kind == "rpill" ? v(3) * s : 0
            body = {
                ctx.saveGState()
                if rot != 0 {
                    ctx.translateBy(x: x, y: c); ctx.rotate(by: rot * .pi / 180); ctx.translateBy(x: -x, y: -c)
                }
                let rad = min(r.width, r.height) / 2
                fill(ctx, CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil), Theme.Mascot.ink)
                ctx.restoreGState()
            }
            body()
            return
        case "up", "dn":
            let dir = e.kind == "up" ? -1.0 : 1.0
            cy = v(2) + ey
            let top = cy
            body = { arc(ctx, { $0.move(to: pt(x - v(0), top)); $0.addQuadCurve(to: pt(x + v(0), top), control: pt(x, top + dir * v(1))) }, width: v(3)) }
            cy += dir * v(1) * 0.4
        case "chev":
            cy = v(0) + ey
            let c = cy
            body = {
                arc(ctx, { $0.move(to: pt(x - s * 50, c - 56)); $0.addLine(to: pt(x + s * 44, c)); $0.addLine(to: pt(x - s * 50, c + 56)) }, width: 40)
            }
        case "heart":
            cy = v(0) + ey
            let c = cy
            body = { fill(ctx, heartPath(x, c, v(1)), Theme.Mascot.ink) }
        default:   // line
            cy = v(1) + ey
            let c = cy
            body = { arc(ctx, { $0.move(to: pt(x - v(0), c)); $0.addLine(to: pt(x + v(0), c)) }, width: v(2)) }
        }
        if k < 0.995 { squeezed(ctx, at: pt(x, cy), sx: 0.6 + 0.4 * k, sy: max(0.1, k), body) } else { body() }
    }

    private static func heartPath(_ cx: Double, _ cy: Double, _ s: Double) -> CGPath {
        func q(_ x: Double, _ y: Double) -> CGPoint { pt(cx + x * s, cy + y * s) }
        let p = CGMutablePath()
        p.move(to: q(0, 52))
        p.addCurve(to: q(0, -34), control1: q(-92, -8), control2: q(-54, -82))
        p.addCurve(to: q(0, 52), control1: q(54, -82), control2: q(92, -8))
        p.closeSubpath()
        return p
    }

    private static func brows(_ ctx: CGContext, _ p: SQMascotPose, xl: Double, xr: Double) {
        for (x0, s, a) in [(xl, 1.0, p[.baL]), (xr, -1.0, p[.baR])] where a >= 0.06 {
            let m = min(1, a)
            let x = x0 + s * p[.bdx], hl = p[.bhl] * m, t = p[.btilt] * m, cy = p[.bcy]
            arc(ctx, {
                $0.move(to: pt(x - s * hl, cy + t))
                $0.addQuadCurve(to: pt(x + s * hl, cy - t), control: pt(x, cy - p[.bbow] * m))
            }, width: p[.bsw] * (0.6 + 0.4 * m))
        }
    }

    private static func mouth(_ ctx: CGContext, _ m: SQMascotShape, k: Double) {
        let a = m.a
        func v(_ i: Int) -> Double { i < a.count ? a[i] : 0 }
        var c = pt(512, 795)
        var body: () -> Void
        switch m.kind {
        case "smile":
            let cx = (v(0) + v(1)) / 2
            c = pt(cx, v(2) + v(3) / 2)
            body = { arc(ctx, { $0.move(to: pt(v(0), v(2))); $0.addQuadCurve(to: pt(v(1), v(2)), control: pt(cx, v(2) + v(3))) }, width: v(4)) }
        case "open":
            let x = v(0), y = v(1), w = v(2), h = v(3), x0 = x - w / 2, x1 = x + w / 2
            c = pt(x, y + h / 2)
            body = {
                let p = CGMutablePath()
                p.move(to: pt(x0, y)); p.addLine(to: pt(x1, y))
                p.addQuadCurve(to: pt(x, y + h), control: pt(x1, y + h))
                p.addQuadCurve(to: pt(x0, y), control: pt(x0, y + h))
                p.closeSubpath()
                fill(ctx, p, Theme.Mascot.ink)
                ctx.setStrokeColor(Theme.Mascot.ink.cgColor); ctx.setLineWidth(22); ctx.setLineJoin(.round)
                ctx.addPath(p); ctx.strokePath()
                if v(4) != 0 {
                    let t = CGMutablePath()
                    t.move(to: pt(x - w * 0.27, y + h * 0.74))
                    t.addQuadCurve(to: pt(x + w * 0.27, y + h * 0.74), control: pt(x, y + h * 0.42))
                    t.addQuadCurve(to: pt(x, y + h + 4), control: pt(x + w * 0.14, y + h + 4))
                    t.addQuadCurve(to: pt(x - w * 0.27, y + h * 0.74), control: pt(x - w * 0.14, y + h + 4))
                    t.closeSubpath()
                    fill(ctx, t, Theme.Mascot.tongue)
                }
            }
        case "o":
            c = pt(v(0), v(1))
            body = { fill(ctx, CGPath(ellipseIn: CGRect(x: v(0) - v(2), y: v(1) - v(3), width: v(2) * 2, height: v(3) * 2), transform: nil), Theme.Mascot.ink) }
        case "wavy":
            let y = v(0)
            c = pt(512, y)
            body = {
                arc(ctx, {
                    $0.move(to: pt(436, y))
                    $0.addQuadCurve(to: pt(486, y), control: pt(461, y - 32))
                    $0.addQuadCurve(to: pt(537, y), control: pt(511, y + 32))
                    $0.addQuadCurve(to: pt(588, y), control: pt(563, y - 32))
                }, width: 30)
            }
        default:   // conc: pressed lips, tongue out at the corner
            let x0 = 548 + v(0)
            body = {
                arc(ctx, { $0.move(to: pt(452, 790)); $0.addQuadCurve(to: pt(572, 790), control: pt(512, 812)) }, width: 33)
                let t = CGMutablePath(), r = 30.0, kc = r * 0.5523
                t.move(to: pt(x0, 800)); t.addLine(to: pt(x0 + 60, 800)); t.addLine(to: pt(x0 + 60, 816))
                t.addCurve(to: pt(x0 + 30, 816 + r), control1: pt(x0 + 60, 816 + kc), control2: pt(x0 + 30 + kc, 816 + r))
                t.addCurve(to: pt(x0, 816), control1: pt(x0 + 30 - kc, 816 + r), control2: pt(x0, 816 + kc))
                t.closeSubpath()
                fill(ctx, t, Theme.Mascot.tongue)
                ctx.setStrokeColor(Theme.Mascot.ink.cgColor); ctx.setLineWidth(12); ctx.setLineJoin(.round)
                ctx.addPath(t); ctx.strokePath()
            }
        }
        if k < 0.995 { squeezed(ctx, at: c, sx: 0.45 + 0.55 * k, sy: 0.45 + 0.55 * k, body) } else { body() }
    }

    // MARK: props

    private static func drop(_ p: SQMascotPose, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: p[.dpx], y: p[.dpy])
        ctx.scaleBy(x: p[.dps], y: p[.dps])
        let d = CGMutablePath(), kc = 48 * 0.5523
        d.move(to: pt(0, 0))
        d.addCurve(to: pt(-48, 100), control1: pt(0, 0), control2: pt(-48, 66))
        d.addCurve(to: pt(0, 148), control1: pt(-48, 100 + kc), control2: pt(-kc, 148))
        d.addCurve(to: pt(48, 100), control1: pt(kc, 148), control2: pt(48, 100 + kc))
        d.addCurve(to: pt(0, 0), control1: pt(48, 66), control2: pt(0, 0))
        d.closeSubpath()
        fill(ctx, d, Theme.Mascot.drop)
        ctx.restoreGState()
    }

    private static func lens(_ p: SQMascotPose, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: p[.mgx], y: p[.mgy])
        ctx.scaleBy(x: p[.mgs], y: p[.mgs])
        let circle = CGPath(ellipseIn: CGRect(x: -70, y: -70, width: 140, height: 140), transform: nil)
        fill(ctx, circle, Theme.Mascot.lens, alpha: p[.mgo])
        ctx.setStrokeColor(Theme.Mascot.violet.cgColor); ctx.setLineWidth(30)
        ctx.addPath(circle); ctx.strokePath()
        arc(ctx, { $0.move(to: pt(54, 54)); $0.addLine(to: pt(114, 114)) }, width: 36, color: Theme.Mascot.violet)
        ctx.restoreGState()
    }

    /// Badge, dots, Zs, sparkles and hearts: drawn outside the head's transform.
    private static func marks(_ p: SQMascotPose, in ctx: CGContext) {
        func at(_ x: Double, _ y: Double, _ s: Double, _ body: () -> Void) {
            ctx.saveGState(); ctx.translateBy(x: x, y: y); ctx.scaleBy(x: s, y: s); body(); ctx.restoreGState()
        }
        func disc(_ x: Double, _ y: Double, _ r: Double, _ c: NSColor) {
            fill(ctx, CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil), c)
        }
        if p[.bs] > 0.03 {
            at(868, 968, p[.bs]) {
                disc(0, 0, 86, Theme.Mascot.ok)
                arc(ctx, { $0.move(to: pt(-40, 0)); $0.addLine(to: pt(-12, 30)); $0.addLine(to: pt(42, -32)) }, width: 26, color: Theme.Mascot.headTop)
            }
        }
        let dots: [(Double, Double, Double, SQMascotKey)] = [(742, 228, 21, .d1), (812, 220, 26, .d2), (890, 228, 21, .d3)]
        for d in dots where p[d.3] > 0.03 { disc(d.0, d.1, d.2 * p[d.3], Theme.Mascot.violet) }
        let zs: [(Double, Double, Double, SQMascotKey, SQMascotKey)] = [(716, 214, 40, .z1, .z1y), (800, 236, 56, .z2, .z2y), (898, 196, 36, .z3, .z3y)]
        for z in zs where p[z.3] > 0.03 {
            let q = z.2
            at(z.0 + q / 2, z.1 + q * 0.575 + p[z.4], p[z.3]) {
                arc(ctx, {
                    $0.move(to: pt(-q / 2, -q * 0.575)); $0.addLine(to: pt(q / 2, -q * 0.575))
                    $0.addLine(to: pt(-q / 2, q * 0.575)); $0.addLine(to: pt(q / 2, q * 0.575))
                }, width: max(12, q * 0.26), color: Theme.Mascot.violet)
            }
        }
        if p[.sp] > 0.03 {
            let s = p[.sp]
            func spark(_ x: Double, _ y: Double, _ r: Double) {
                at(x, y, s) {
                    let sp = CGMutablePath()
                    sp.move(to: pt(0, -r)); sp.addQuadCurve(to: pt(r, 0), control: pt(0, 0))
                    sp.addQuadCurve(to: pt(0, r), control: pt(0, 0)); sp.addQuadCurve(to: pt(-r, 0), control: pt(0, 0))
                    sp.addQuadCurve(to: pt(0, -r), control: pt(0, 0)); sp.closeSubpath()
                    fill(ctx, sp, Theme.Mascot.spark)
                }
            }
            spark(150, 262, 58); spark(900, 330, 40); spark(96, 560, 30)
            disc(930, 560, 17 * s, Theme.Mascot.heart); disc(215, 1010, 15 * s, Theme.Mascot.violet); disc(880, 930, 13 * s, Theme.Mascot.spark)
        }
        if p[.h1] > 0.03 { fill(ctx, heartPath(884, 250, 0.62 * p[.h1]), Theme.Mascot.heart) }
        if p[.h2] > 0.03 { fill(ctx, heartPath(150, 330, 0.4 * p[.h2]), Theme.Mascot.heart) }
    }
}
