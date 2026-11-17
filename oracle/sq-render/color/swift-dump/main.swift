import Foundation
import simd

// Golden dumper for crates/sq-render/src/color. One TAB separated record per line: `op name inputs... -> outputs...`;
// floats are 8 hex digits of the f32 bit pattern, doubles 16 hex digits. The Rust test rebuilds every input and config
// from the same formulas (LCG below, config builders mirrored in color/tests_oracle.rs).

struct LCG {
    var s: UInt64
    mutating func next() -> Float {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Float(s >> 40) / Float(1 << 24)
    }
    mutating func rgb() -> SIMD3<Float> { SIMD3(next(), next(), next()) }
}

func h(_ f: Float) -> String { let s = String(f.bitPattern, radix: 16); return String(repeating: "0", count: 8 - s.count) + s }
func hd(_ f: Double) -> String { let s = String(f.bitPattern, radix: 16); return String(repeating: "0", count: 16 - s.count) + s }
func h3(_ v: SIMD3<Float>) -> String { "\(h(v.x)) \(h(v.y)) \(h(v.z))" }
func hm(_ m: simd_float3x3) -> String {
    [m.columns.0, m.columns.1, m.columns.2].map(h3).joined(separator: " ")
}
func line(_ parts: String...) { print(parts.joined(separator: "\t")) }

// MARK: shared configs (mirrored in Rust)

func wheel(_ hue: Float, _ amount: Float) -> WheelValue { WheelValue(hue: hue, amount: amount) }
func pts(_ p: [(Float, Float)]) -> [CurvePoint] { p.map { CurvePoint($0.0, $0.1) } }

func basicA(legacy: Bool) -> BasicCorrection {
    var b = legacy ? BasicCorrection(model: .legacy) : BasicCorrection()
    b.temperature = 20; b.tint = -10; b.exposure = 0.5; b.contrast = 20; b.highlights = -30; b.shadows = 25
    b.whites = 10; b.blacks = -15; b.saturation = 120; b.vibrance = 30
    return b
}
func creativeA() -> CreativeLook {
    var c = CreativeLook()
    c.fadedFilm = 30; c.saturation = 90; c.vibrance = -20
    c.shadowTint = wheel(200, 0.5); c.highlightTint = wheel(30, 0.6); c.tintBalance = 20
    return c
}
func curvesA() -> RGBCurves {
    var c = RGBCurves()
    c.master = pts([(0, 0), (0.3, 0.25), (0.7, 0.8), (1, 1)])
    c.red = pts([(0, 0), (0.5, 0.6), (1, 1)])
    return c
}
func hueCurvesA() -> HueCurves {
    var c = HueCurves()
    c.hueVsSat = pts([(0, 0.5), (0.08, 0.8), (0.5, 0.4), (1, 0.5)])
    c.hueVsHue = pts([(0, 0.5), (0.6, 0.7), (1, 0.5)])
    c.hueVsLuma = pts([(0, 0.5), (0.25, 0.35), (1, 0.5)])
    c.lumaVsSat = pts([(0, 0.5), (0.5, 0.7), (1, 0.5)])
    c.satVsSat = pts([(0, 0.5), (1, 0.8)])
    return c
}
func wheelsA() -> ColorWheels {
    var w = ColorWheels()
    w.shadows = wheel(240, 0.4); w.midtones = wheel(120, 0.3); w.highlights = wheel(30, 0.5)
    w.shadowsLuma = 10; w.midtonesLuma = -20; w.highlightsLuma = 15; w.saturation = 110
    return w
}
func hslRange() -> HSLSecondary {
    var r = HSLSecondary()
    r.hueCenter = 30; r.hueWidth = 60; r.satMin = 20; r.satMax = 100; r.lumMin = 10; r.lumMax = 90; r.softness = 30
    r.hueShift = 15; r.saturation = 130; r.exposure = 0.3; r.temperature = 20; r.tint = -10
    return r
}
func hslVolume() -> HSLSecondary {
    var r = HSLSecondary()
    r.maskMode = .volume; r.hueCenter = 200; r.volumeSat = 60; r.volumeLum = 50; r.volumeRadius = 50; r.softness = 40
    r.saturation = 70; r.hueShift = -20; r.exposure = -0.4
    return r
}
func zoneA() -> ZoneBoard {
    var z = ZoneBoard()
    z.shadows = ZoneSetting(puckX: 0.3, puckY: 0.6, saturation: 0.6, exposure: 0.4)
    z.highlights = ZoneSetting(puckX: 0.7, puckY: 0.4, saturation: 0.45, exposure: 0.6)
    z.global = ZoneSetting(puckX: 0.5, puckY: 0.55, saturation: 0.5, exposure: 0.52)
    return z
}
func vignetteA(_ roundness: Float) -> Vignette {
    var v = Vignette()
    v.amount = -1.5; v.midpoint = 40; v.roundness = roundness; v.feather = 60
    return v
}
func primariesA() -> StepPrimaries {
    var p = StepPrimaries()
    p.lift = ColorTriple(0.02, -0.01, 0.03); p.gamma = ColorTriple(1.1, 0.9, 1.0); p.gain = ColorTriple(1.05, 1, 0.95)
    p.offset = ColorTriple(0.01, 0, -0.01); p.contrast = 1.1; p.pivot = 0.435; p.saturation = 1.2
    return p
}
func qualifierA() -> ColorQualifier {
    var q = ColorQualifier()
    q.hueCenter = 25; q.hueWidth = 50; q.satMin = 10; q.satMax = 100; q.softness = 20
    return q
}
func windowA(_ shape: StepWindow.Shape) -> StepWindow {
    var w = StepWindow()
    w.shape = shape; w.centerX = 0.45; w.centerY = 0.55; w.width = 0.5; w.height = 0.4; w.rotation = 20; w.softness = 0.3
    return w
}

/// `.cube` text from integer formulas (exact binary fractions, so both languages print the same digits).
func cubeText(_ n: Int, flags: String) -> String {
    var s = flags + "LUT_3D_SIZE \(n)\n"
    for b in 0..<n { for g in 0..<n { for r in 0..<n {
        func v(_ k: Int) -> Float { Float((r * (k + 3) + g * (k + 1) * 2 + b * (5 - k) + k) % 17) / 16 }
        s += "\(v(0)) \(v(1)) \(v(2))\n"
    } } }
    return s
}
func cube1D() -> String {
    "LUT_1D_SIZE 4\n0 0.0625 0.5\n0.25 0.375 0.5625\n0.75 0.5 0.4375\n1 0.9375 1\n"
}
func lutA() -> CubeLUT { try! CubeLUT.parse(cubeText(5, flags: "")) }
func lutB() -> CubeLUT { try! CubeLUT.parse(cube1D()) }

func pipelines() -> [(String, ColorPipeline)] {
    var out: [(String, ColorPipeline)] = []
    for s in SourceColorSpace.allCases { out.append(("src_\(s)", ColorPipeline(source: s))) }
    for s in [SourceColorSpace.hlgBT2020, .pqBT2020, .appleLog] {
        var p = ColorPipeline(source: s); p.skipsToneMap = true
        out.append(("skip_\(s)", p))
    }
    for s in [SourceColorSpace.hlgBT2020, .sLog3SGamut3Cine, .pqBT2020] {
        out.append(("trim_\(s)", ColorPipeline(source: s, ops: [.conversion(nil)],
                                               toneMapping: ToneMapping(knee: 0.6, exposureStops: 1, compressesGamut: true))))
    }
    out.append(("A", ColorPipeline(source: .sLog3SGamut3Cine, ops: [
        .basic(basicA(legacy: false)), .conversion(nil), .creative(creativeA()), .curves(curvesA()), .hueCurves(hueCurvesA()),
        .wheels(wheelsA()), .hslSecondary(hslRange()), .zoneBoard(zoneA()), .vignette(vignetteA(-30)),
    ])))
    out.append(("A2", ColorPipeline(source: .vLogVGamut, ops: [
        .conversion(nil), .basic(basicA(legacy: false)), .creative(creativeA()), .curves(curvesA()), .hueCurves(hueCurvesA()),
        .wheels(wheelsA()), .hslSecondary(hslVolume()), .zoneBoard(zoneA()), .vignette(vignetteA(40)),
    ])))
    out.append(("B", ColorPipeline(source: .logC3WideGamut3, ops: [
        .basic(basicA(legacy: true)), .wheels(wheelsA()), .hueCurves(hueCurvesA()), .hslSecondary(hslRange()), .zoneBoard(zoneA()),
        .creative(creativeA()), .curves(curvesA()), .vignette(vignetteA(0)), .conversion(lutA()), .look(lutB(), intensity: 0.6),
        .basic(basicA(legacy: true)),
    ])))
    out.append(("B2", ColorPipeline(source: .hlgBT2020, ops: [.conversion(nil), .look(lutA(), intensity: 1), .basic(basicA(legacy: true))])))
    out.append(("C", ColorPipeline(source: .rec709, ops: [
        .conversion(nil), .hslSecondary(hslVolume()), .primaries(primariesA()), .stepBegin, .wheels(wheelsA()),
        .stepEnd(qualifier: qualifierA(), window: windowA(.rectangle), mix: 0.8), .vignette(vignetteA(-30)),
    ])))
    out.append(("C2", ColorPipeline(source: .appleLog, ops: [
        .conversion(nil), .stepBegin, .primaries(primariesA()), .stepEnd(qualifier: nil, window: windowA(.ellipse), mix: 1),
        .stepBegin, .curves(curvesA()), .stepEnd(qualifier: qualifierA(), window: windowA(.linear), mix: 1),
    ])))
    out.append(("D", ColorPipeline(source: .rec709, ops: [
        .conversion(nil), .groupBegin, .primaries(primariesA()), .branchEnd(layer: false, qualifier: qualifierA(), window: nil, mix: 1),
        .keyTerm(KeyTerm(qualifier: qualifierA(), window: windowA(.rectangle))), .wheels(wheelsA()),
        .branchEnd(layer: false, qualifier: nil, window: windowA(.ellipse), mix: 0.7), .groupMerge(count: 2), .curves(curvesA()),
        .layerMix(.screen), .branchEnd(layer: true, qualifier: qualifierA(), window: nil, mix: 0.9),
        .keyTerm(KeyTerm(qualifier: nil, window: windowA(.ellipse), outside: true, mode: .multiply)),
        .keyTerm(KeyTerm(qualifier: qualifierA(), window: nil, outside: false, mode: .add)), .keyApply, .groupEnd,
    ])))
    out.append(("D2", ColorPipeline(source: .rec709, ops: [
        .conversion(nil), .groupBegin, .groupMerge(count: 0), .primaries(primariesA()), .layerMix(.multiply),
        .branchEnd(layer: true, qualifier: nil, window: nil, mix: 0.5), .layerMix(.darken),
        .branchEnd(layer: true, qualifier: nil, window: nil, mix: 1), .groupEnd,
    ])))
    return out
}

// MARK: dumps

let allSpaces = SourceColorSpace.allCases
var rng = LCG(s: 20261105)

// Transfer: per space, decode / encode on 40 vectors (edges + LCG over -0.1...1.2).
for s in allSpaces {
    var inputs: [SIMD3<Float>] = [[0, 0, 0], [1, 1, 1], [0.5, 0.5, 0.5], [0.18, 0.4, 0.9], [-0.05, 0.02, 0.75]]
    for _ in 0..<35 { inputs.append(rng.rgb() * 1.3 - SIMD3(repeating: 0.1)) }
    for v in inputs {
        line("dec", "\(s)", h3(v), "->", h3(s.decode(v)))
        line("enc", "\(s)", h3(v), "->", h3(s.encode(v)))
    }
}
// Gamut rows.
let gamuts: [(String, Gamut)] = [("rec709", .rec709), ("bt2020", .bt2020), ("sGamut3Cine", .sGamut3Cine), ("vGamut", .vGamut),
    ("dGamut", .dGamut), ("cinemaGamut", .cinemaGamut), ("sqWide", .sqWide), ("displayP3", .displayP3),
    ("arriWideGamut3", .arriWideGamut3), ("arriWideGamut4", .arriWideGamut4), ("redWideGamutRGB", .redWideGamutRGB),
    ("blackmagicWideGamut", .blackmagicWideGamut), ("fGamutC", .fGamutC), ("acesAP1", .acesAP1)]
for (n, g) in gamuts {
    line("gamut", n, hm(g.rgbToXYZ), hm(g.xyzToRGB), h3(g.lumaRow), hm(g.matrix(to: .rec709)), hm(g.matrix(to: .bt2020)))
}
for (cct, duv) in [(6504.0, 0.0), (3000.0, 0.0), (9000.0, 0.01), (5000.0, -0.02), (2500.0, 0.005)] {
    let xy = WhitePoint.xy(cct: cct, duv: duv)
    line("xy", "\(cct) \(duv)", "->", hd(xy.x), hd(xy.y))
}
// White balance matrices.
for g in [Gamut.rec709, .bt2020, .sGamut3Cine] {
    for (t, n) in [(20, -10), (-60, 30), (100, 100), (0, 40), (-100, -100)] as [(Float, Float)] {
        var b = BasicCorrection(); b.temperature = t; b.tint = n
        line("wbmat", "\(t) \(n)", h3(g.lumaRow), "->", hm(PreparedBasic(b, gamut: g).wb))
    }
}
// Tone map.
let tms: [(String, ToneMapping)] = [("def", ToneMapping()), ("trim", ToneMapping(knee: 0.6, exposureStops: 1, compressesGamut: true)),
                                    ("lo", ToneMapping(knee: 0.95, exposureStops: -2, compressesGamut: false))]
for (n, tm) in tms {
    for peak in [nil, SourceColorSpace.hlgBT2020.toneMapPeak, SourceColorSpace.pqBT2020.toneMapPeak] {
        for _ in 0..<12 {
            let v = rng.rgb() * 6 - SIMD3(repeating: 0.3)
            line("tmap", n, h(peak ?? -1), h3(v), "->", h3(tm.apply(tm.trim(v), peak: peak)))
        }
    }
}
for _ in 0..<40 {
    let v = rng.rgb() * 1.6 - SIMD3(repeating: 0.5)
    line("soft", h3(v), "->", h3(SoftGamutCompression.compress(v)))
    for t in OutputTarget.allCases {
        line("outt", t.rawValue, h3(v), "->", h3(t.encode(v, working: .bt2020)))
    }
}
// LUT lookups.
func lutLines(_ name: String, _ lut: CubeLUT) {
    for _ in 0..<24 { let p = rng.rgb() * 1.2 - SIMD3(repeating: 0.1); line("lut", name, h3(p), "->", h3(lut.lookup(p))) }
}
lutLines("tetra", lutA())
lutLines("tri", lutA().with(interpolation: .trilinear))
lutLines("oned", lutB())
lutLines("video", try! CubeLUT.parse(cubeText(5, flags: "LUT_IN_VIDEO_RANGE\nLUT_OUT_VIDEO_RANGE\n")))
lutLines("domain", try! CubeLUT.parse(cubeText(5, flags: "DOMAIN_MIN -0.5 -0.5 -0.5\nDOMAIN_MAX 2 1.5 1\n")))
// Pipelines.
for (name, p) in pipelines() {
    var r = LCG(s: UInt64(name.utf8.reduce(7) { ($0 &* 31 &+ Int($1)) & 0xffff }))
    for i in 0..<20 {
        let v = i == 0 ? SIMD3<Float>(0, 0, 0) : i == 1 ? SIMD3<Float>(1, 1, 1) : r.rgb()
        let uv = SIMD2<Float>(r.next(), r.next())
        let aspect: Float = i % 2 == 0 ? 16.0 / 9 : 4.0 / 3
        line("pipe", name, h3(v), "\(h(uv.x)) \(h(uv.y))", h(aspect), "->", h3(p.process(v, uv: uv, aspect: aspect)))
    }
}
// HDR conform.
let kinds: [(String, HDRConform.Kind)] = [("hlg2sdr", .hlgToSDR), ("pq2sdr", .pqToSDR), ("sdr2hlg75", .sdrToHLG(.percent75)),
    ("sdr2hlg100", .sdrToHLG(.percent100)), ("sdr2pq", .sdrToPQ(peakNits: 1000)), ("hlg2pq", .hlgToPQ), ("pq2hlg", .pqToHLG)]
for (n, k) in kinds {
    for _ in 0..<10 { let v = rng.rgb(); line("hdr", n, h3(v), "->", h3(HDRConform.convert(v, k, toneMapping: ToneMapping(compressesGamut: true)))) }
}
// White balance solver.
for (pk, t, n) in [(SIMD3<Float>(0.4, 0.35, 0.3), Float(0), Float(0)), (SIMD3(0.2, 0.3, 0.5), 10, -5), (SIMD3(0.9, 0.2, 0.01), 90, 90),
                   (SIMD3(0.35, 0.35, 0.35), 12, -7), (SIMD3(0, 0, 0), 0, 0), (SIMD3(0.5, 0.45, 0.6), -30, 20)] {
    if let r = WhiteBalanceSolver.solve(picked: pk, temperature: t, tint: n) {
        line("wbsolve", h3(pk), "\(h(t)) \(h(n))", "->", h(r.temperature), h(r.tint))
    } else { line("wbsolve", h3(pk), "\(h(t)) \(h(n))", "->", "nil") }
}
// Auto Tone.
func autoImages() -> [[SIMD3<Float>]] {
    var r = LCG(s: 4242)
    let dark = (0..<1500).map { _ in r.rgb() * 0.35 }
    let cast = (0..<1500).map { _ -> SIMD3<Float> in let v = r.next() * 0.6; return SIMD3(v * 1.15, v, v * 0.85) }
    let mixed = (0..<1500).map { i -> SIMD3<Float> in i % 3 == 0 ? SIMD3(repeating: r.next() * 0.8) : r.rgb() }
    return [dark, cast, mixed]
}
func basicFields(_ b: BasicCorrection) -> String {
    [b.temperature, b.tint, b.exposure, b.contrast, b.highlights, b.shadows, b.whites, b.blacks, b.saturation, b.vibrance].map(h).joined(separator: " ")
}
for (i, img) in autoImages().enumerated() {
    var cur = BasicCorrection(); if i == 2 { cur.exposure = 0.4; cur.contrast = 10 }
    if let b = AutoTone.solve(linear: img, current: cur) { line("autotone", "\(i)", "->", basicFields(b)) } else { line("autotone", "\(i)", "->", "nil") }
}
// Look thumbnails.
func fnv(_ bytes: [UInt8]) -> String { var x: UInt64 = 0xcbf29ce484222325; for b in bytes { x = (x ^ UInt64(b)) &* 0x100000001b3 }; return String(x, radix: 16) }
for (n, lut, k) in [("plain", nil, Float(1)), ("lutA", lutA(), 0.8), ("lutB", lutB(), 1)] as [(String, CubeLUT?, Float)] {
    let bytes = LookThumbnail.render(lut: lut, intensity: k, width: 64, height: 36)
    line("thumb", n, fnv(bytes), bytes.map { String($0, radix: 16) }.joined(separator: ","))
}
