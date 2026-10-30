import Foundation
import SQGPUKernels
import SQUIKit

// The Scopes panel (Mac SQMonitorUI `ScopesView`, `ScopeOverlayView`, `ScopeRenderer`) translated to the portable
// canvas: the same box layout, the same graticule drawing, and the Metal fragment shader's mapping as CPU code that
// turns `ScopeCounts` into the picture of one scope (shown through an image slot).

/// Layout of the Scopes panel (design board Panels "Scopes"): body inset 12 at the sides and 10 above and below, 8
/// between a popup and its scope and between two scopes; the first scope box is 170 high when two are shown.
public enum ScopeBoxLayout {
    public static let side: CGFloat = 12        // Theme.Spacing.md
    public static let top: CGFloat = 10
    public static let gap: CGFloat = 8          // Theme.Spacing.sm
    public static let firstBox: CGFloat = 170
    /// The least height a second scope is worth showing at.
    public static let minSecondBox: CGFloat = 120
    /// Board: the vectorscope disc is 190 across and its gamut ring sits at 46 % of that (92 % of the disc).
    public static let vectorDisc: CGFloat = 190
    public static let vectorRing: CGFloat = 0.92

    /// The dark disc around a vectorscope ring `p`.
    public static func vectorDisc(ofRing p: CGRect) -> CGRect {
        p.insetBy(dx: -p.width * (1 / vectorRing - 1) / 2, dy: -p.height * (1 / vectorRing - 1) / 2)
    }

    /// Board label positions inside the disc: R top-center, Mg right, B bottom-right, Cy bottom-left, G left, Yl top-left.
    public static func vectorLabelOrigins(disc d: CGRect, textHeight h: CGFloat, widthOf: (String) -> CGFloat) -> [(String, CGPoint)] {
        [("R", CGPoint(x: d.minX + d.width * 0.5, y: d.minY + 12)),
         ("Mg", CGPoint(x: d.maxX - 16 - widthOf("Mg"), y: d.minY + d.height * 0.44)),
         ("B", CGPoint(x: d.maxX - 50 - widthOf("B"), y: d.maxY - 14 - h)),
         ("Cy", CGPoint(x: d.minX + 40, y: d.maxY - 16 - h)),
         ("G", CGPoint(x: d.minX + 14, y: d.minY + d.height * 0.5)),
         ("Yl", CGPoint(x: d.minX + 40, y: d.minY + 22))]
    }

    /// Color page row (version 9): 2 pt between the scopes, each under a caption.
    public static let rowGap: CGFloat = 2
    public static let rowInset: CGFloat = 8
    public static func caption(_ k: ScopeKind) -> String {
        switch k {
        case .waveform: "Waveform"
        case .parade: "RGB parade"
        case .vectorscope: "Vectorscope"
        case .histogram: "Histogram"
        }
    }

    /// The popup titles: the scope and what it measures.
    public static func title(_ k: ScopeKind) -> String {
        switch k {
        case .waveform: "Waveform \u{00B7} Luma"
        case .parade: "Parade \u{00B7} RGB"
        case .vectorscope: "Vectorscope"
        case .histogram: "Histogram"
        }
    }

    /// The plot inside a scope box of `size`: waveform leaves 26 at the left for its labels, the histogram 16 below;
    /// the vectorscope is the largest centered circle with room for its labels.
    public static func plot(_ k: ScopeKind, in size: CGSize) -> CGRect {
        let w = size.width, h = size.height
        switch k {
        case .waveform: return CGRect(x: 26, y: 8, width: max(w - 32, 0), height: max(h - 16, 0))
        case .parade: return CGRect(x: 6, y: 8, width: max(w - 12, 0), height: max(h - 16, 0))
        case .histogram: return CGRect(x: 6, y: 6, width: max(w - 12, 0), height: max(h - 22, 0))
        case .vectorscope:
            let d = max(min(vectorDisc, w, h), 0) * vectorRing
            return CGRect(x: ((w - d) / 2).rounded(), y: ((h - d) / 2).rounded(), width: d, height: d)
        }
    }

    /// Whether a second scope fits under the first in a panel `height` high with popups `popup` high.
    public static func showsTwo(height: CGFloat, popup: CGFloat) -> Bool {
        height >= 2 * top + 2 * popup + 3 * gap + firstBox + minSecondBox
    }
}

/// The picture of one scope from its counts: the CPU form of the Mac's `ScopeRenderer` fragment shader (count / max,
/// bilinear clamp sampling, compressive map, 4-tap cross glow, phosphor tints, additive histogram curves on 12/255 gray).
public enum ScopeImage {
    static let background: Float = 12 / 255

    /// A count / max plane (the Mac's r32Float scope texture).
    struct Plane {
        let w: Int, h: Int
        let v: [Float]
        init(_ counts: [UInt32], w: Int, h: Int, max m: UInt32) {
            self.w = w; self.h = h
            let inv = m > 0 ? 1 / Float(m) : 0
            v = counts.map { Float($0) * inv }
        }
        func sample(_ u: Float, _ t: Float) -> Float {
            let fx = u * Float(w) - 0.5, fy = t * Float(h) - 0.5
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
            let ax = fx - Float(x0), ay = fy - Float(y0)
            func at(_ x: Int, _ y: Int) -> Float { v[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
            let top = at(x0, y0) * (1 - ax) + at(x0 + 1, y0) * ax
            let bottom = at(x0, y0 + 1) * (1 - ax) + at(x0 + 1, y0 + 1) * ax
            return top * (1 - ay) + bottom * ay
        }
    }

    static func saturate(_ x: Float) -> Float { min(max(x, 0), 1) }
    /// count/max (0...1) -> display intensity: compressive so sparse traces stay visible.
    static func map(_ v: Float, _ gain: Float) -> Float { saturate(pow(max(v, 0), 0.45) * 1.6 * gain) }
    /// Vectorscope: log over five decades with a visible floor for any occupied bin.
    static func mapVector(_ v: Float, _ gain: Float) -> Float {
        v <= 0 ? 0 : saturate((0.34 + 0.66 * saturate(1 + log10(v) / 5)) * gain)
    }
    static func glow(_ p: Plane, _ u: Float, _ t: Float, _ gain: Float, _ sx: Float, _ sy: Float, vector: Bool) -> Float {
        let f = vector ? mapVector : map
        let tx = sx / Float(p.w), ty = sy / Float(p.h)
        let g = f(p.sample(u + tx, t), gain) + f(p.sample(u - tx, t), gain) + f(p.sample(u, t + ty), gain)
            + f(p.sample(u, t - ty), gain)
        return saturate(f(p.sample(u, t), gain) + 0.18 * g)
    }

    /// The scope `kind` drawn `width` x `height` pixels (opaque RGBA).
    public static func render(_ kind: ScopeKind, _ c: ScopeCounts, width: Int, height: Int, intensity gain: Float = 1) -> RGBAImage {
        let l = c.layout
        let plane: Plane
        switch kind {
        case .waveform: plane = Plane(c.waveformLuma, w: l.waveformWidth, h: l.waveformLevels, max: c.maxWaveformLuma)
        case .parade: plane = Plane(c.waveformParade, w: 3 * l.waveformWidth, h: l.waveformLevels, max: c.maxWaveformParade)
        case .vectorscope: plane = Plane(c.vectorscope, w: l.vectorscopeSize, h: l.vectorscopeSize, max: c.maxVectorscope)
        case .histogram: plane = Plane(c.histogram, w: ScopeLayout.histogramBins, h: 4, max: c.maxHistogram)
        }
        var px = [UInt8](repeating: 255, count: max(width * height, 0) * 4)
        let bg = background
        for y in 0..<max(height, 0) {
            let t = (Float(y) + 0.5) / Float(height)
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                var col: (Float, Float, Float)
                switch kind {
                case .waveform:
                    let i = glow(plane, u, t, gain, 1.5, 1.5, vector: false)
                    col = (bg + i * 0.62, bg + i, bg + i * 0.72)
                case .parade:
                    let panel = min((u * 3).rounded(.down), 2)
                    let i = glow(plane, u, t, gain, 1, 1.5, vector: false)
                    let tint: (Float, Float, Float) = panel < 0.5 ? (1, 0.30, 0.26) : (panel < 1.5 ? (0.30, 1, 0.42) : (0.30, 0.52, 1))
                    col = (bg + i * tint.0, bg + i * tint.1, bg + i * tint.2)
                case .vectorscope:
                    let i = glow(plane, u, t, gain, 1.5, 1.5, vector: true)
                    col = (bg + i * 0.70, bg + i, bg + i * 0.80)
                case .histogram:
                    let h = 1 - t
                    var add: (Float, Float, Float) = (0, 0, 0)
                    let tints: [(Float, Float, Float)] = [(0.85, 0.12, 0.10), (0.10, 0.75, 0.22), (0.12, 0.30, 0.95), (0.22, 0.22, 0.22)]
                    for r in 0..<4 where h <= plane.sample(u, (Float(r) + 0.5) / 4).squareRoot() {
                        add = (add.0 + tints[r].0, add.1 + tints[r].1, add.2 + tints[r].2)
                    }
                    col = (bg + add.0 * gain, bg + add.1 * gain, bg + add.2 * gain)
                }
                let i = (y * width + x) * 4
                px[i] = UInt8(saturate(col.0) * 255 + 0.5); px[i + 1] = UInt8(saturate(col.1) * 255 + 0.5)
                px[i + 2] = UInt8(saturate(col.2) * 255 + 0.5)
            }
        }
        return RGBAImage(width: max(width, 0), height: max(height, 0), pixels: px)
    }
}

/// The graticule over a scope box (ScopeOverlayView.draw): IRE lines and labels, parade dividers, the vectorscope disc,
/// rings, cross, skin tone line and color labels, the histogram verticals and axis labels.
public enum ScopeOverlay {
    public static func draw(_ c: inout Canvas, _ kind: ScopeKind, box: CGRect, theme t: DrawTheme) {
        let bounds = CGSize(width: box.width, height: box.height)
        var p = ScopeBoxLayout.plot(kind, in: bounds)
        p.origin.x += box.minX; p.origin.y += box.minY
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: p.minX + x * p.width, y: p.minY + y * p.height) }
        let line = DrawColor.white.alpha(0.075), major = DrawColor.white.alpha(0.12)
        let font: CGFloat = 10                    // Theme.Typography.caption
        let textH = c.size(of: "R", fontSize: font).height
        switch kind {
        case .waveform, .parade:
            for ire in [100, 75, 50, 25, 0] {
                let y = pt(0, 1 - Double(ire) / 100).y
                c.fill(CGRect(x: p.minX, y: min(max(y - 0.5, p.minY), p.maxY - 1), width: p.width, height: 1), line)
                guard kind == .waveform else { continue }
                // Board label tops: 4 pt from the top, 27 %, 48 %, 70 % of the box, 4 pt from the bottom.
                let top: CGFloat
                switch ire {
                case 100: top = 4
                case 75: top = bounds.height * 0.27
                case 50: top = bounds.height * 0.48
                case 25: top = bounds.height * 0.70
                default: top = bounds.height - 4 - textH
                }
                _ = c.draw("\(ire)", at: CGPoint(x: box.minX + 6, y: box.minY + top), fontSize: font, t.label3)
            }
            if kind == .parade {
                for i in 1...2 { c.fill(CGRect(x: p.minX + p.width * CGFloat(i) / 3 - 0.5, y: p.minY, width: 1, height: p.height), line) }
            }
        case .vectorscope:
            // Board: a dark disc, the gamut ring at 46 % of its diameter, an inner ring at 23 %, the cross, labels only.
            let disc = ScopeBoxLayout.vectorDisc(ofRing: p)
            c.fill(ellipseIn: disc, DrawColor(hex: 0x0A0A0A))      // Theme.Colors.scopeBox
            c.stroke(ellipseIn: p.insetBy(dx: 0.5, dy: 0.5), width: 1, major)
            c.stroke(ellipseIn: CGRect(x: p.midX - p.width / 4, y: p.midY - p.height / 4, width: p.width / 2, height: p.height / 2),
                     width: 1, major)
            c.strokeLine(from: CGPoint(x: p.minX, y: p.midY), to: CGPoint(x: p.maxX, y: p.midY), width: 1, major)
            c.strokeLine(from: CGPoint(x: p.midX, y: p.minY), to: CGPoint(x: p.midX, y: p.maxY), width: 1, major)
            let e = ScopeGraticule.skinToneLineEnd
            c.strokeLine(from: pt(0.5, 0.5), to: pt(e.x, e.y), width: 1, DrawTheme.color(t.palette.warning))
            for (name, origin) in ScopeBoxLayout.vectorLabelOrigins(disc: disc, textHeight: textH.rounded(.up),
                                                                    widthOf: { c.size(of: $0, fontSize: font).width }) {
                _ = c.draw(name, at: origin, fontSize: font, t.label3)
            }
        case .histogram:
            for v in ScopeGraticule.histogramVerticals {
                let x = pt(v, 0).x
                c.fill(CGRect(x: min(max(x - 0.5, p.minX), p.maxX - 1), y: p.minY, width: 1, height: p.height),
                       v == 0 || v == 1 ? major : line)
            }
            for (v, label) in [(0.0, "0"), (0.5, "50"), (1.0, "100")] {
                let size = c.size(of: label, fontSize: font)
                let x = pt(v, 0).x
                _ = c.draw(label, at: CGPoint(x: min(max(x - size.width / 2, p.minX), p.maxX - size.width),
                                              y: p.maxY + ((box.maxY - p.maxY - size.height) / 2).rounded()), fontSize: font, t.label3)
            }
        }
    }
}
