#if canImport(Metal)
import Foundation
import ImageIO
import Testing
import simd
import SQCore
@testable import SQRender

/// Compares our Basic Correction (Lumetri tone model) with frames the maintainer exports from Premiere's Lumetri, patch by patch.
/// Inputs (never committed): `TestMedia/color-reference.png` (scripts/make-color-reference.py) and
/// `TestMedia/premiere-ref/<slider><+-value>.png` (docs/research/COLOR-REFERENCE-HOWTO.md). Skips when they are absent.
/// Every file prints a `PERF COLORREF` line (worst / mean error in IRE) for calibrating the `BasicToneCurves` constants;
/// the tone sliders fail beyond `toneTolerance`, color sliders (whose maths is not matched yet) only report.
@Suite struct ColorReferenceComparisonTests {
    static let toneTolerance: Float = 0.02     // 2 IRE on the gray patches
    static let toneSliders: Set<String> = ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "combo"]

    /// `SQ_COLOR_REF_DIR`, else `<checkout>/TestMedia` (from a worktree: the main checkout's).
    static var mediaDir: URL? {
        if let d = ProcessInfo.processInfo.environment["SQ_COLOR_REF_DIR"] { return URL(fileURLWithPath: d) }
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { repo.deleteLastPathComponent() }
        var candidates = [repo.appendingPathComponent("TestMedia")]
        if let r = repo.path.range(of: "/.claude/worktrees/") {
            candidates.append(URL(fileURLWithPath: String(repo.path[..<r.lowerBound])).appendingPathComponent("TestMedia"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("color-reference.png").path) }
    }
    static var references: [URL] {
        guard let d = mediaDir?.appendingPathComponent("premiere-ref") else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: File name -> settings

    /// `contrast+50.png`, `exposure-1.5.png`, `neutral.png`, `combo.png` (Contrast 40, Highlights -30, Shadows 30,
    /// Whites 10, Blacks -10). nil: not a reference file.
    static func settings(_ name: String) -> (slider: String, b: BasicCorrection)? {
        var b = BasicCorrection()
        let base = (name as NSString).deletingPathExtension.lowercased()
        if base == "neutral" { return ("neutral", b) }
        if base == "combo" {
            b.contrast = 40; b.highlights = -30; b.shadows = 30; b.whites = 10; b.blacks = -10
            return ("combo", b)
        }
        guard let i = base.firstIndex(where: { $0 == "+" || $0 == "-" }), let v = Float(base[i...]) else { return nil }
        let slider = String(base[..<i])
        switch slider {
        case "exposure": b.exposure = v
        case "contrast": b.contrast = v
        case "highlights": b.highlights = v
        case "shadows": b.shadows = v
        case "whites": b.whites = v
        case "blacks": b.blacks = v
        case "temperature": b.temperature = v
        case "tint": b.tint = v
        case "saturation": b.saturation = v
        case "vibrance": b.vibrance = v
        default: return nil
        }
        return (slider, b)
    }

    // MARK: Pixels (raw code values, no color management)

    struct Picture {
        let w: Int, h: Int
        let at: (Int, Int) -> SIMD3<Float>
        /// Mean over a box centered on (cx, cy).
        func mean(_ cx: Int, _ cy: Int, _ rw: Int, _ rh: Int) -> SIMD3<Float> {
            var s = SIMD3<Float>.zero, n: Float = 0
            for y in (cy - rh / 2)..<(cy + rh / 2) { for x in (cx - rw / 2)..<(cx + rw / 2) { s += at(x, y); n += 1 } }
            return s / n
        }
    }

    static func load(_ url: URL) -> Picture? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = img.dataProvider?.data as Data? else { return nil }
        let bpc = img.bitsPerComponent, bpp = img.bitsPerPixel, row = img.bytesPerRow
        guard bpc == 8 || bpc == 16 else { return nil }
        let comps = bpp / bpc
        let alpha = img.alphaInfo
        let first = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
        let off = comps == 4 && first ? 1 : 0
        let little = img.byteOrderInfo == .order16Little || img.byteOrderInfo == .order32Little
        let bytes = [UInt8](data)
        return Picture(w: img.width, h: img.height) { x, y in
            var c = SIMD3<Float>()
            for k in 0..<3 {
                let i = y * row + (x * comps + off + k) * (bpc / 8)
                if bpc == 8 {
                    c[k] = Float(bytes[i]) / 255
                } else {
                    let v = little ? Int(bytes[i]) | Int(bytes[i + 1]) << 8 : Int(bytes[i]) << 8 | Int(bytes[i + 1])
                    c[k] = Float(v) / 65535
                }
            }
            // 32-bit little-endian packs BGRA / ARGB reversed.
            return bpc == 8 && img.byteOrderInfo == .order32Little && comps == 4 ? SIMD3(c.z, c.y, c.x) : c
        }
    }

    /// Patch centers and box sizes (scripts/make-color-reference.py layout): 21 grays, 48 ramp points, 24 chart patches.
    static let greys = (0..<21).map { (15 + 90 * $0 + 45, 180, 40, 200) }
    static let ramp = (0..<48).map { (20 + $0 * 39, 440, 4, 100) }
    static let chart = (0..<24).map { (60 + 300 * ($0 % 6) + 145, 548 + 132 * ($0 / 6) + 60, 200, 80) }

    // MARK: Test

    @Test(.enabled(if: !references.isEmpty, "no Premiere reference frames in TestMedia/premiere-ref"))
    func basicCorrectionMatchesPremiereReferenceFrames() throws {
        let dir = try #require(Self.mediaDir)
        let source = try #require(Self.load(dir.appendingPathComponent("color-reference.png")), "color-reference.png unreadable")
        #expect(source.w == 1920 && source.h == 1080)
        for url in Self.references {
            guard let (slider, b) = Self.settings(url.lastPathComponent) else {
                Issue.record("unknown reference name \(url.lastPathComponent) (see COLOR-REFERENCE-HOWTO.md)"); continue
            }
            guard let ref = Self.load(url), ref.w == source.w, ref.h == source.h else {
                Issue.record("\(url.lastPathComponent): unreadable or not 1920x1080"); continue
            }
            let p = PreparedBasic(b, gamut: .rec709)
            func ours(_ c: SIMD3<Float>) -> SIMD3<Float> { simd_clamp(p.apply(c, pre: false), .zero, .one) }
            func err(_ boxes: [(Int, Int, Int, Int)]) -> (worst: Float, mean: Float, at: Int) {
                var worst: Float = 0, sum: Float = 0, at = 0
                for (i, (x, y, w, h)) in boxes.enumerated() {
                    let d = simd_reduce_max(simd_abs(ours(source.mean(x, y, w, h)) - ref.mean(x, y, w, h)))
                    sum += d
                    if d > worst { worst = d; at = i }
                }
                return (worst, sum / Float(boxes.count), at)
            }
            let g = err(Self.greys + Self.ramp), c = err(Self.chart)
            print(String(format: "PERF COLORREF %@ gray worst %.1f IRE (patch %d) mean %.1f | chart worst %.1f mean %.1f",
                         url.lastPathComponent, g.worst * 100, g.at, g.mean * 100, c.worst * 100, c.mean * 100))
            if slider == "neutral" {
                #expect(g.worst < 1.5 / 255 && c.worst < 1.5 / 255,
                        "neutral export differs from the source: Premiere color management or export settings (HOWTO step 2)")
            } else if Self.toneSliders.contains(slider) {
                #expect(g.worst < Self.toneTolerance, "\(url.lastPathComponent): gray worst \(g.worst * 100) IRE at patch \(g.at)")
            }
        }
    }

    @Test(.enabled(if: mediaDir != nil, "TestMedia/color-reference.png absent"))
    func sourceStillHasTheExpectedLayout() throws {
        let dir = try #require(Self.mediaDir)
        let source = try #require(Self.load(dir.appendingPathComponent("color-reference.png")))
        for (i, (x, y, w, h)) in Self.greys.enumerated() {
            #expect(abs(source.mean(x, y, w, h).x - (Float(i) / 20 * 255).rounded() / 255) < 0.2 / 255, "gray \(i)")
        }
        for (x, y, w, h) in Self.ramp {
            #expect(abs(source.mean(x, y, w, h).y - (Float(x) / 1919 * 255).rounded() / 255) < 1.0 / 255, "ramp \(x)")
        }
        let first = source.mean(Self.chart[0].0, Self.chart[0].1, Self.chart[0].2, Self.chart[0].3) * 255
        #expect(simd_length(first - SIMD3(115, 82, 68)) < 0.2, "dark skin")
        let last = source.mean(Self.chart[23].0, Self.chart[23].1, Self.chart[23].2, Self.chart[23].3) * 255
        #expect(simd_length(last - SIMD3(52, 52, 52)) < 0.2, "black")
    }

    @Test func referenceNamesParse() {
        #expect(Self.settings("contrast+50.png")?.b.contrast == 50)
        #expect(Self.settings("exposure-1.5.png")?.b.exposure == -1.5)
        #expect(Self.settings("Temperature+30.PNG")?.b.temperature == 30)
        #expect(Self.settings("combo.png")?.b.shadows == 30)
        #expect(Self.settings("neutral.png")?.b.isNeutral == true)
        #expect(Self.settings("notes.png") == nil)
        #expect(Self.settings("contrast+50.png")?.b.model == .lumetri)
    }
}
#endif
