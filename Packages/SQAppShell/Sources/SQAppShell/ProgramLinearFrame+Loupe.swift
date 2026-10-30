import Foundation
import SQDrawMonitor

extension ProgramLinearFrame {
    /// The loupe's grid around a 0…1 position (y down) from the read-back picture (the Mac `ColorPickHub.hover` with
    /// `MagnifierGrid`): `ColorLoupe.side` pixels per side, cut at the picture edge with the center moved to match;
    /// display values as `FrameSampler.display8` (clamp, BT.709 OETF, 8 bit). nil outside the picture.
    public func loupe(at p: SIMD2<Double>, side: Int = ColorLoupe.side) -> ColorLoupe? {
        guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1, pixels.count == width * height,
              let (x0, y0, w, h) = Self.patch(width: width, height: height, at: p, radius: side / 2) else { return nil }
        let cx = min(max(Int(p.x * Double(width)), 0), width - 1), cy = min(max(Int(p.y * Double(height)), 0), height - 1)
        var out: [SIMD3<UInt8>] = []
        out.reserveCapacity(w * h)
        for y in y0..<(y0 + h) { for x in x0..<(x0 + w) { out.append(Self.display8(pixels[y * width + x])) } }
        return ColorLoupe(width: w, height: h, pixels: out, centerX: cx - x0, centerY: cy - y0)
    }

    /// `Rec709Output.encode` (SQRender) to 8 bit, written out: SQAppShell does not link SQRender.
    static func display8(_ linear: SIMD3<Float>) -> SIMD3<UInt8> {
        func ch(_ v: Float) -> UInt8 {
            guard !v.isNaN else { return 0 }
            let c = min(max(v, 0), 1)
            let e = c < 0.018 ? 4.5 * c : 1.099 * powf(c, 0.45) - 0.099
            return UInt8(min(max(e, 0), 1) * 255 + 0.5)
        }
        return SIMD3(ch(linear.x), ch(linear.y), ch(linear.z))
    }
}
