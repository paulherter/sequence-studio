import Foundation
import SQCore
import SQDrawKit
import SQUIKit

/// SafeMarginsView translated to the canvas: aspect frame, platform zone and its UI mock, the 90 % / 80 % margins and
/// the center cross, rulers and guides. The canvas has no even-odd fill or dashes: the dimmed band is four rects around
/// the clear one and the dashed edge is drawn as segments.
extension MonitorPanel {
    static let rulerThickness: CGFloat = 14, guideGrab: CGFloat = 4

    func drawOverlays(_ c: inout Canvas, in r: CGRect) {
        guard r.width > 4 else { return }
        let t = theme
        if let f = model.aspectFrame.rect(in: r) {
            // Dim the picture outside the frame so the crop reads at a glance; the frame edge is a thin guide line.
            Self.fillBand(&c, outer: r, inner: f, t.guide.alpha(0.18))
            c.stroke(roundedRect: f, radius: 0, width: 1, t.guide)
        }
        if model.mode == .program, model.safeZone != .off, let z = platformZone {
            // Dim what the platform's own buttons, name and caption cover; the clear rectangle is where content stays visible.
            let safe = CGRect(x: r.minX + z.x * r.width, y: r.minY + z.y * r.height, width: z.width * r.width, height: z.height * r.height)
            Self.fillBand(&c, outer: r, inner: safe, t.guide.alpha(0.18))
            Self.dashedRect(&c, safe, dash: 4, gap: 3, t.guide)
            drawMock(&c, in: r)
        }
        if model.safeMargins {
            for k in model.safeMarginSizes.fractions {
                let w = r.width * k, h = r.height * k
                c.stroke(roundedRect: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), radius: 0, width: 1, t.guide)
            }
            c.strokeLine(from: CGPoint(x: r.midX - 8, y: r.midY), to: CGPoint(x: r.midX + 8, y: r.midY), width: 1, t.guide)
            c.strokeLine(from: CGPoint(x: r.midX, y: r.midY - 8), to: CGPoint(x: r.midX, y: r.midY + 8), width: 1, t.guide)
        }
        drawGuides(&c, in: r)
    }

    /// `outer` minus `inner` (the even-odd band) as up to four rects.
    static func fillBand(_ c: inout Canvas, outer o: CGRect, inner i0: CGRect, _ color: DrawColor) {
        let i = i0.intersection(o)
        guard !i.isNull else { c.fill(o, color); return }
        c.fill(CGRect(x: o.minX, y: o.minY, width: o.width, height: i.minY - o.minY), color)
        c.fill(CGRect(x: o.minX, y: i.maxY, width: o.width, height: o.maxY - i.maxY), color)
        c.fill(CGRect(x: o.minX, y: i.minY, width: i.minX - o.minX, height: i.height), color)
        c.fill(CGRect(x: i.maxX, y: i.minY, width: o.maxX - i.maxX, height: i.height), color)
    }

    /// A 1 pt rect outline dashed `dash` on, `gap` off (`setLineDash([4, 3])`).
    static func dashedRect(_ c: inout Canvas, _ r: CGRect, dash: CGFloat, gap: CGFloat, _ color: DrawColor) {
        func run(_ a: CGPoint, _ b: CGPoint) {
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0 else { return }
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            var s: CGFloat = 0
            while s < len {
                let e = min(s + dash, len)
                c.strokeLine(from: CGPoint(x: a.x + ux * s, y: a.y + uy * s), to: CGPoint(x: a.x + ux * e, y: a.y + uy * e),
                             width: 1, color)
                s = e + gap
            }
        }
        run(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY))
        run(CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY))
        run(CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY))
        run(CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY))
    }

    func drawGuides(_ c: inout Canvas, in r: CGRect) {
        let t = theme
        if model.showsRulers {
            let th = Self.rulerThickness
            c.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: th), t.field.alpha(0.85))
            c.fill(CGRect(x: r.minX, y: r.minY + th, width: th, height: r.height - th), t.field.alpha(0.85))
            let steps = Int((1 / MonitorGuides.minorStep).rounded())
            for i in 0...steps {
                let f = Double(i) * MonitorGuides.minorStep
                let major = i % 2 == 0
                let len: CGFloat = major ? th * 0.6 : th * 0.3
                let x = (r.minX + CGFloat(f) * r.width).rounded(), y = (r.minY + CGFloat(f) * r.height).rounded()
                c.fill(CGRect(x: x, y: r.minY + th - len, width: 1, height: len), t.label3)
                if i > 0 { c.fill(CGRect(x: r.minX + th - len, y: y, width: len, height: 1), t.label3) }
                if major, i > 0, i < steps {
                    c.draw("\(Int((f * 100).rounded()))", at: CGPoint(x: x + 2, y: r.minY), fontSize: 10, t.label3)
                }
            }
        }
        for v in model.guides.vertical {
            c.fill(CGRect(x: (r.minX + CGFloat(v) * r.width).rounded(), y: r.minY, width: 1, height: r.height), t.accent)
        }
        for h in model.guides.horizontal {
            c.fill(CGRect(x: r.minX, y: (r.minY + CGFloat(h) * r.height).rounded(), width: r.width, height: 1), t.accent)
        }
    }

    private static func glyph(_ kind: PlatformUIMock.Kind) -> SQIcon? {
        switch kind {
        case .avatar: .user
        case .like: .heart
        case .comment: .discord
        case .share: .share
        case .save: .bookmarkFilled
        default: nil
        }
    }

    /// Light placeholder shapes of the platform's own UI; geometry from SQCore (`PlatformUIMock`), color from one token.
    private func drawMock(_ c: inout Canvas, in r: CGRect) {
        guard model.showsPlatformMock else { return }
        let ink = theme.platformMock
        for e in platformMock {
            let box = CGRect(x: r.minX + e.rect.x * r.width, y: r.minY + e.rect.y * r.height,
                             width: e.rect.width * r.width, height: e.rect.height * r.height)
            if e.isRoundButton {
                c.fill(ellipseIn: box, ink.alpha(0.22))
                if let name = Self.glyph(e.kind) {
                    let s = box.width * 0.42
                    c.draw(icon: name, at: CGPoint(x: box.midX - s / 2, y: box.midY - s / 2), size: s, ink)
                }
            } else if e.kind == .progressBar {
                c.fill(box, ink.alpha(0.5))
            } else {
                c.fill(roundedRect: box, radius: box.height / 2, ink.alpha(e.kind == .accountName ? 0.55 : 0.32))
            }
        }
    }

    // MARK: Guides (SafeMarginsView's mouse handling)

    /// What a press at `p` grabs: an existing guide (move it) or a ruler strip (pull a new guide out).
    enum GuideTarget: Equatable { case guide(MonitorGuides.Axis, Int), newVertical, newHorizontal }

    func guideTarget(at p: CGPoint) -> GuideTarget? {
        let r = canvasRect
        guard r.width > 4, !model.overlaysHidden, model.showsRulers || !model.guides.isEmpty else { return nil }
        let g = model.guides
        if r.insetBy(dx: -Self.guideGrab, dy: -Self.guideGrab).contains(p) {
            for (i, f) in g.vertical.enumerated() where abs(p.x - (r.minX + CGFloat(f) * r.width)) <= Self.guideGrab { return .guide(.vertical, i) }
            for (i, f) in g.horizontal.enumerated() where abs(p.y - (r.minY + CGFloat(f) * r.height)) <= Self.guideGrab { return .guide(.horizontal, i) }
        }
        guard model.showsRulers else { return nil }
        let t = Self.rulerThickness
        if CGRect(x: r.minX, y: r.minY, width: r.width, height: t).contains(p) { return .newHorizontal }
        if CGRect(x: r.minX, y: r.minY, width: t, height: r.height).contains(p) { return .newVertical }
        return nil
    }

    private func fraction(_ axis: MonitorGuides.Axis, at p: CGPoint) -> Double {
        let r = canvasRect
        return axis == .vertical ? Double((p.x - r.minX) / max(r.width, 1)) : Double((p.y - r.minY) / max(r.height, 1))
    }

    func beginGuideDrag(at p: CGPoint) {
        guard let target = guideTarget(at: p) else { return }
        switch target {
        case .guide(let a, let i): activeGuide = (a, i)
        case .newVertical: activeGuide = (.vertical, model.guides.add(.vertical, at: fraction(.vertical, at: p)))
        case .newHorizontal: activeGuide = (.horizontal, model.guides.add(.horizontal, at: fraction(.horizontal, at: p)))
        }
    }

    func dragGuide(to p: CGPoint) {
        guard let g = activeGuide else { return }
        model.guides.move(g.axis, index: g.index, to: fraction(g.axis, at: p))
    }

    func endGuideDrag(at p: CGPoint) {
        guard let g = activeGuide else { return }
        activeGuide = nil
        let r = canvasRect
        let f = fraction(g.axis, at: p)
        // Dropped back into the ruler or outside the picture: the guide is gone.
        let t = Double(Self.rulerThickness / max(g.axis == .vertical ? r.width : r.height, 1))
        if f < t * 0.5 || f > 1.02 || !r.insetBy(dx: -40, dy: -40).contains(p) { model.guides.remove(g.axis, index: g.index) }
    }
}
