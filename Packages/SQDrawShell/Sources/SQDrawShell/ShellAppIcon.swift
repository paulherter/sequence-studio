import Foundation
import SQDrawKit

/// The app icon on the DrawKit canvas (portable redraw of `App/AppIcon.icon`: the gradient field, Pip's head, his face).
/// The Mac host puts the real icon over the About card instead; the Windows host has no image to place, so the card draws
/// this. Art space is the 512 px icon picture.
public enum ShellAppIcon {
    static let fieldTop = DrawColor(hex: 0xFFA94D), fieldBottom = DrawColor(hex: 0x5A1590)
    static let face = DrawColor(hex: 0x1A1A1F)

    /// Image slot of the real icon picture while the About card shows (borrows the Slip two-up slot like the Export preview:
    /// no Slip drag runs under a modal card). shortcut: one borrowed slot; upgrade when the renderers keep a seventh.
    public static let slot = 1
    /// True once the host holds the real icon picture (`ShellHost.appIconImage`): the card places it from `slot`.
    nonisolated(unsafe) static var hasImage = false

    /// The real icon (`ShellAppIconPixels`, 128 px from Windows/Resources/SequenceStudio.ico) as one quad per run of equal
    /// pixels: the draw list has no spare image slot for a picture. shortcut: nearest-neighbor at 128 px; upgrade with an
    /// image slot when the renderers get a seventh.
    public static func draw(in rect: CGRect, into c: inout Canvas) {
        let n = ShellAppIconPixels.size
        if hasImage, rect.width > 0, rect.height > 0 {
            let side = min(rect.width, rect.height)
            c.draw(imageSlot: slot, in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
            return
        }
        guard rect.width > 0, rect.height > 0, !runs.isEmpty else { return drawVector(in: rect, into: &c) }
        let s = min(rect.width, rect.height) / CGFloat(n)
        let ox = rect.midX - s * CGFloat(n) / 2, oy = rect.midY - s * CGFloat(n) / 2
        let grow = s * 0.5   // the next run paints over this overlap: no seams between neighbors
        for r in runs {
            c.fill(CGRect(x: ox + CGFloat(r.x) * s, y: oy + CGFloat(r.y) * s, width: CGFloat(r.length) * s + grow, height: s + grow), r.color)
        }
    }

    private struct Run { var x, y, length: Int; var color: DrawColor }

    /// Runs of equal (6-bit quantized) pixels, row by row; transparent pixels are skipped.
    private static let runs: [Run] = {
        guard let data = Data(base64Encoded: ShellAppIconPixels.base64, options: .ignoreUnknownCharacters) else { return [] }
        let n = ShellAppIconPixels.size
        guard data.count == n * n * 4 else { return [] }
        let px = [UInt8](data)
        var out: [Run] = []
        for y in 0..<n {
            var x = 0
            while x < n {
                func key(_ x: Int) -> (UInt8, UInt8, UInt8, UInt8) {
                    let i = (y * n + x) * 4
                    return (px[i] & 0xFC, px[i + 1] & 0xFC, px[i + 2] & 0xFC, px[i + 3] & 0xFC)
                }
                let k = key(x)
                var e = x + 1
                while e < n, key(e) == k { e += 1 }
                if k.3 >= 8 {
                    out.append(Run(x: x, y: y, length: e - x, color: DrawColor(Float(k.0) / 252, Float(k.1) / 252, Float(k.2) / 252, Float(k.3) / 252)))
                }
                x = e
            }
        }
        return out
    }()

    /// The portable redraw of `App/AppIcon.icon` (the gradient field, Pip's head, his face): the fallback.
    static func drawVector(in rect: CGRect, into c: inout Canvas) {
        let s = Double(min(rect.width, rect.height)) / 512
        let base = ShellMascot.Aff.move(Double(rect.minX), Double(rect.minY)).concat(.scale(s, s))
        // Field: the rounded square as horizontal slabs, orange at the top to violet at the bottom.
        let field = ShellMascot.Gfx(m: base)
        let square = ShellMascot.Path.roundedRect(CGRect(x: 0, y: 0, width: 512, height: 512), radius: 115)
        let pts = field.map(square)
        if let lo = pts.map(\.y).min(), let hi = pts.map(\.y).max() {
            let n = max(2, min(32, Int((hi - lo) / 1.5)))
            for i in 0..<n {
                let y0 = lo + (hi - lo) * CGFloat(i) / CGFloat(n)
                let y1 = lo + (hi - lo) * CGFloat(i + 1) / CGFloat(n) + (i == n - 1 ? 0 : 0.6)
                let t = Float((i * 2 + 1)) / Float(n * 2)
                let col = DrawColor(fieldTop.r + (fieldBottom.r - fieldTop.r) * t, fieldTop.g + (fieldBottom.g - fieldTop.g) * t,
                                    fieldTop.b + (fieldBottom.b - fieldTop.b) * t)
                let slab = ShellMascot.Gfx.clip(pts, y0, y1)
                if slab.count >= 3 { c.fill(polygon: slab, col) }
            }
        }
        drawHead(in: rect, into: &c)
    }

    /// Pip's head and face alone (no gradient field): the About card's mascot (art.html 43).
    static func drawHead(in rect: CGRect, into c: inout Canvas) {
        let s = Double(min(rect.width, rect.height)) / 512
        let base = ShellMascot.Aff.move(Double(rect.minX), Double(rect.minY)).concat(.scale(s, s))
        // Head: the mascot's head outline (art 1024) placed as in the icon (scale 1.04 about the middle).
        let headM = base.concat(.move(256, 269.5)).concat(.scale(0.52, 0.52)).concat(.move(-512, -652))
        let head = ShellMascot.Gfx(m: headM)
        head.gradient(ShellMascot.headPath, &c)
        // Face: two bars and a smile.
        let g = ShellMascot.Gfx(m: base)
        for x in [169.0, 305.0] {
            g.fill(.roundedRect(CGRect(x: x, y: 193, width: 36, height: 95), radius: 18), face, &c)
        }
        var smile = ShellMascot.Path()
        smile.move(220, 326); smile.quad(255, 358, 290, 326)
        g.stroke(smile, width: 20, face, closed: false, &c)
    }
}
