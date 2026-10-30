import CoreVideo
import Foundation
import SQCore
import Testing
@testable import SQAnalysis

/// The inside of the model's mask is solid after every step (upsample, both edge steps, a pick of the system's
/// segmentation): soft alpha only in a thin band at the edge. The maintainer's clip: hair top, beard and a finger were
/// see-through, a white phone added by click stayed transparent. Synthetic pictures only.
@Suite struct SubjectSolidInteriorTests {
    /// Share of the pixels in `r` (frame pixels of a `w` x `h` frame) below 0.99, and the lowest alpha there.
    static func soft(_ m: SubjectMatte, _ r: (x0: Int, y0: Int, x1: Int, y1: Int), _ w: Int, _ h: Int) -> (share: Double, low: Float) {
        let kx = Double(m.width) / Double(w), ky = Double(m.height) / Double(h)
        var below = 0, n = 0, low: Float = 1
        for y in Int(Double(r.y0) * ky)..<Int(Double(r.y1) * ky) {
            for x in Int(Double(r.x0) * kx)..<Int(Double(r.x1) * kx) {
                let v = m.values[y * m.width + x]
                n += 1; low = min(low, v)
                if v < 0.99 { below += 1 }
            }
        }
        return (Double(below) / Double(max(n, 1)), low)
    }

    static func edgers() -> [(String, SubjectMatteEdger)] {
        let speed = SubjectMatteEdger(), quality = SubjectMatteEdger()
        speed.refines = true; speed.quality = .speed
        quality.refines = true; quality.quality = .quality
        return [("speed", speed), ("quality", quality)]
    }

    /// Hair: strands 1 px dark, 1 px of the bright background between them, on top of a dark body. The model's mask
    /// is weak there (logits +-1, as on the first frame of a pick).
    @Test func denseHairOnABrightBackgroundStaysSolidInside() throws {
        let w = 1280, h = 720
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &made)
        let pb = try #require(made)
        func region(_ x: Int, _ y: Int) -> Int {   // 0 background, 1 body, 2 hair
            guard x >= 440, x < 840 else { return 0 }
            return y >= 300 ? 1 : y >= 140 ? 2 : 0
        }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h {
            for x in 0..<w {
                let r = region(x, y)
                let v: UInt8 = r == 1 ? 50 : r == 2 && x % 2 == 0 ? 40 : 235
                let p = base + y * row + x * 4
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let size = SubjectTrackRules.logitSize
        var logits = [Float](repeating: -1, count: size * size)
        for y in 0..<size { for x in 0..<size where region((x * w + w / 2) / size, (y * h + h / 2) / size) != 0 { logits[y * size + x] = 1 } }
        let raw = SubjectMatteUpsample.matte(logits: logits, size: size, width: w, height: h)
        // 20 px in from the mask's edge.
        let hair = (x0: 460, y0: 160, x1: 820, y1: 290)
        let r = Self.soft(raw, hair, w, h)
        #expect(r.share == 0, "raw: \(r)")
        for (name, edger) in Self.edgers() {
            let s = Self.soft(edger.edged(raw, pb), hair, w, h)
            #expect(s.share < 0.001 && s.low > 0.9, "\(name): \(s)")
        }
    }

    /// A white phone held out before a bright wall: the model's weak mask takes it in, no edge step makes it see-through.
    @Test(arguments: [SubjectHeldObjectTests.Layout.wide, .front])
    func aWhitePhoneBeforeABrightWallStaysSolid(layout: SubjectHeldObjectTests.Layout) throws {
        let s = try SubjectHeldObjectTests.scene(object: [245, 245, 245], layout: layout, back: [222, 222, 222], inside: 1.5)
        let raw = SubjectMatteUpsample.matte(logits: s.logits, size: SubjectTrackRules.logitSize, width: s.width, height: s.height)
        // Further in than the band (8 px at 1920) and the model's cell (7.5 px).
        let inner = (x0: s.object.x0 + 12, y0: s.object.y0 + 12, x1: s.object.x1 - 12, y1: s.object.y1 - 12)
        #expect(Self.soft(raw, inner, s.width, s.height).share == 0)
        for (name, edger) in Self.edgers() {
            let e = Self.soft(edger.edged(raw, s.frame), inner, s.width, s.height)
            #expect(e.share < 0.001 && e.low > 0.9, "\(name) \(layout.rawValue): \(e)")
        }
    }

    /// A person click plus an add click on a phone: the system's segmentation gives both soft (0.85, 0.7), the
    /// pick is solid inside both.
    @Test func anAddClickOnASoftObjectGivesASolidPick() throws {
        let w = 320, h = 180
        var labels = [UInt8](repeating: 0, count: w * h)
        for y in 40..<180 { for x in 100..<180 { labels[y * w + x] = 1 } }
        for y in 60..<110 { for x in 180..<210 { labels[y * w + x] = 2 } }
        let l = InstanceLabels(width: w, height: h, labels: labels)
        let frame = InstanceFrame(labels: l) { selected in
            SubjectMatte(width: w, height: h, values: l.labels.map { selected.contains($0) ? ($0 == 1 ? 0.85 : $0 == 2 ? 0.7 : 0) : 0 })
        }
        let t = Time(0, 600)
        let points = [MagicPoint(position: Vec2(140.0 / 320, 100.0 / 180), subtract: false, sourceTime: t),
                      MagicPoint(position: Vec2(195.0 / 320, 85.0 / 180), subtract: false, sourceTime: t)]
        let m = try #require(MagicMaskTracker.pickMatte(frame, pts: 0, points: points))
        let band = SubjectMatteCore.band(width: w, height: h)
        let phone = Self.soft(m, (x0: 182, y0: 60 + band, x1: 210 - band, y1: 110 - band), w, h)
        let person = Self.soft(m, (x0: 100 + band, y0: 40 + band, x1: 180 - band, y1: 180 - band), w, h)
        #expect(phone.share == 0 && person.share == 0, "phone \(phone) person \(person)")
        // Outside both it stays empty.
        #expect(m.values[20 * w + 20] == 0 && m.values[150 * w + 260] == 0)
    }
}
