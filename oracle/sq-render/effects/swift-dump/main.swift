import Foundation
import SQCore

// Dumps the CPU references of Packages/SQRender/Sources/SQRender/Effects (and VisibleSourceRegion) to golden/effects.tsv.
// One line per case: `tag<TAB>id...<TAB>values`. The Rust test (crates/sq-render/src/effects/golden.rs) builds the same cases.

var lines: [String] = []
func out(_ tag: String, _ v: [Float]) { lines.append(tag + "\t" + v.map { "\($0)" }.joined(separator: " ")) }
func outI(_ tag: String, _ v: [Int]) { out(tag, v.map { Float($0) }) }
func v4(_ p: SIMD4<Float>) -> [Float] { [p.x, p.y, p.z, p.w] }
func v3(_ p: SIMD3<Float>) -> [Float] { [p.x, p.y, p.z] }
func v2(_ p: SIMD2<Float>) -> [Float] { [p.x, p.y] }

// MARK: shared data

let colors: [SIMD4<Float>] = [
    SIMD4(0, 0, 0, 0), SIMD4(0.25, 0.1, 0.05, 0.5), SIMD4(0.2, 0.3, 0.4, 1), SIMD4(0.9, 0.95, 0.1, 1),
    SIMD4(0.05, 0.1, 1, 1), SIMD4(0.4, 0.4, 0.4, 1), SIMD4(1.5, 0.2, 0.1, 0.8), SIMD4(0.6, 0.3, 0.7, 0.75),
]

func testPixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
    let a: Float = (x + y) % 5 == 0 ? 0.6 : 1
    let r = Float((x * 7 + y * 13) % 17) / 17, g = Float((x * 5 + y * 3) % 11) / 11, b = Float((x * 3 + y * 11) % 13) / 13
    return SIMD4(r * a, g * a, b * a, a)
}
let image = ImageFilters.Image(width: 16, height: 12) { x, y in testPixel(x, y) }
let frame = ImageFilters.Frame(center: SIMD2(8, 6), size: SIMD2(12, 8))
func imageOut(_ tag: String, _ img: ImageFilters.Image) { out(tag, img.px.flatMap { v4($0) }) }

// MARK: blend modes

for m in BlendMode.allCases {
    let id = Int(BlendModes.shaderID(m))
    for (si, s) in colors.enumerated() {
        for (di, d) in colors.enumerated() {
            out("blend\t\(id)\t\(si)\t\(di)", v4(BlendModes.blend(m, source: s, destination: d, x: 3, y: 5)))
        }
    }
}
var dis: [Float] = []
for (x, y) in [(0, 0), (1, 0), (0, 1), (7, 9), (-3, 4), (100, -200), (4095, 4095)] { dis.append(BlendModes.dissolveThreshold(x: x, y: y)) }
out("dissolve", dis)

// MARK: crop mask

let cropSize = SIMD2<Float>(50, 30)
let crops: [(CropInsets, Float, Bool, Float)] = [
    (CropInsets(), 8, false, 0), (CropInsets(left: 0.1, top: 0.05, right: 0.2, bottom: 0), 8, false, 0),
    (CropInsets(left: 0.1, top: 0.05, right: 0.2, bottom: 0), 8, true, 3), (CropInsets(left: 0.3, top: 0.3, right: 0.1, bottom: 0.1), 100, false, 2),
]
for (ci, c) in crops.enumerated() {
    var vals: [Float] = []
    for j in 0..<5 { for i in 0..<7 {
        let p = SIMD2<Float>(Float(i) * 8 - 24.5, Float(j) * 7 - 14.5)
        vals.append(CropMask.signedDistance(p, size: cropSize, crop: c.0, cornerRadius: c.1, roundFirst: c.2))
        vals.append(CropMask.coverage(p, size: cropSize, crop: c.0, cornerRadius: c.1, roundFirst: c.2, feather: c.3))
    } }
    out("crop\t\(ci)", vals)
}

// MARK: ultra key

let greenKey = ChromaKey(hue: 120, halfWidth: 36, soft: 13, spill: 0.5)
var shaped = greenKey; shaped.choke = 0.3; shaped.pedestal = 0.1
var rich = ChromaKey(hue: 200, halfWidth: 20, soft: 25, spill: 0.8, choke: -0.4, pedestal: 0.05)
rich.contrast = 0.5; rich.midpoint = 0.4; rich.keepHighlights = 0.5; rich.keepShadows = 0.3; rich.spillRange = 0.8
rich.saturation = 1.2; rich.hueShift = 20; rich.luma = 0.9
var lumaBrights = ChromaKey.luma(threshold: 0.4, softness: 0.2, brights: true); lumaBrights.contrast = 0.5; lumaBrights.choke = 0.2
var matte = greenKey; matte.output = .alpha
var source = greenKey; source.output = .source
let keySets: [[ChromaKey]] = [[greenKey], [shaped], [rich], [ChromaKey.luma(threshold: 0.4, softness: 0.2)], [lumaBrights],
                              [matte], [source, greenKey], [greenKey, rich, shaped]]
let keyColors: [SIMD3<Float>] = [SIMD3(0.05, 0.6, 0.05), SIMD3(0.7, 0.1, 0.1), SIMD3(0.4, 0.4, 0.4), SIMD3(0, 0, 0), SIMD3(0.1, 0.5, 0.367),
                                 SIMD3(0.5, 0.45, 0.1), SIMD3(0.1, 0.4, 0.8), SIMD3(0.9, 0.95, 0.85), SIMD3(0.02, 0.05, 0.01), SIMD3(1.2, 0.3, 0.2)]
for (ki, keys) in keySets.enumerated() {
    for (ci, c) in keyColors.enumerated() {
        let r = UltraKey.apply(rgb: c, alpha: 0.9, keys: keys)
        out("key\t\(ki)\t\(ci)", v3(r.rgb) + [r.alpha])
    }
}
for (ci, c) in keyColors.enumerated() { let h = UltraKey.hsv(c); out("hsv\t\(ci)", [h.h, h.s, h.v]) }
for (ki, k) in [greenKey, shaped, rich, lumaBrights].enumerated() {
    out("keyvec\t\(ki)", v4(UltraKey.matteVector(k)) + v4(UltraKey.shapeVector(k)) + v4(UltraKey.colorVector(k)) + v4(UltraKey.vector(k)))
}

// MARK: gaussian blur

for (i, s) in [Float(0.5), 1.7, 3].enumerated() { out("weights\t\(i)", GaussianBlur.weights(sigma: s)) }
let plans: [(Double, Double, Double, Double, Double?, Int, Int)] = [
    (100, 50, 4, 0, nil, 1, .max), (1000, 1000, 30, 0, nil, 1, .max), (100, 50, 1, 0, nil, 2, .max), (100, 50, 0, 0, nil, 1, .max),
    (1000, 1000, 2, 500, nil, 1, 1_500_000), (1920, 1080, 9, 40, 12, 1, .max), (20000, 100, 3, 0, nil, 1, .max),
]
for (i, p) in plans.enumerated() {
    let pl = GaussianBlur.Plan(layerWidth: p.0, layerHeight: p.1, sigma: p.2, extraMargin: p.3, extraMarginY: p.4, minFactor: p.5, maxPixels: p.6)
    out("gplan\t\(i)", [Float(pl.factor), pl.sigma, Float(pl.radius), Float(pl.textureWidth), Float(pl.textureHeight), pl.contentWidth,
                       pl.contentHeight, pl.outputWidth, pl.outputHeight])
}
imageOut("blur\t0", ImageFilters.Image(width: 16, height: 12, px: GaussianBlur.blur(image.px, width: 16, height: 12, sigma: 1.7)))
imageOut("blur\t1", ImageFilters.Image(width: 16, height: 12, px: GaussianBlur.blur(image.px, width: 16, height: 12, sigma: 2.4, repeatEdges: true)))

// MARK: image filters

for (i, d) in [SIMD2<Float>(7, 3), SIMD2(0, 8), SIMD2(40, 20), SIMD2(0, 0)].enumerated() {
    let n = ImageFilters.smearTaps(d)
    outI("smear\t\(i)", [n, ImageFilters.smearPasses(n)?.fine ?? -1, ImageFilters.smearPasses(n)?.coarse ?? -1])
}
outI("pixelrect", {
    let r = ImageFilters.pixelRect(frame, width: 16, height: 12); let q = ImageFilters.pixelRect(ImageFilters.Frame(center: SIMD2(0, 0), size: SIMD2(7.5, 9)), width: 16, height: 12)
    return [r.minX, r.minY, r.maxX, r.maxY, q.minX, q.minY, q.maxX, q.maxY]
}())
imageOut("sharpen\t0", ImageFilters.sharpen(image, amount: 1.5))
imageOut("sharpen\t1", ImageFilters.sharpen(image, amount: 1.5, frame: frame))
imageOut("unsharp\t0", ImageFilters.unsharpMask(image, sigma: 2, amount: 1.2, threshold: 0.05, frame: frame))
imageOut("unsharp\t1", ImageFilters.unsharpMask(image, sigma: 9, amount: 0.7, threshold: 0, frame: nil))
imageOut("dirblur\t0", ImageFilters.directionalBlur(image, d: SIMD2(7, 3)))
imageOut("dirblur\t1", ImageFilters.directionalBlur(image, d: SIMD2(40, 20)))
imageOut("mirror\t0", ImageFilters.mirror(image, center: SIMD2(10, 9), degrees: 33))
imageOut("mirror\t1", ImageFilters.mirror(image, center: SIMD2(8, 6), degrees: 90))
imageOut("noise\t0", ImageFilters.noise(image, amount: 0.3, color: true, clip: true, seed: 7))
imageOut("noise\t1", ImageFilters.noise(image, amount: 0.5, color: false, clip: false, seed: 99))
imageOut("glow\t0", ImageFilters.glow(image, threshold: 0.4, sigma: 2.5, intensity: 0.8, tint: nil))
imageOut("glow\t1", ImageFilters.glow(image, threshold: 0.2, sigma: 1.5, intensity: 1.3, tint: SIMD3(0.9, 0.4, 0.2)))
for (i, m) in [(4, 3, false), (5, 4, true), (3, 3, false), (16, 12, false), (30, 20, false)].enumerated() {
    imageOut("mosaic\t\(i)", ImageFilters.mosaic(image, frame: frame, columns: m.0, rows: m.1, sharp: m.2))
}
out("hash01", [ImageFilters.hash01(0, 0, 0, 0), ImageFilters.hash01(5, 9, 7, 2), ImageFilters.hash01(4_000_000_000, 123456, 99, 1)])

// MARK: style filters

let styleFilters: [(String, ImageFilter)] = [
    ("vignetteNeg", .vignette(amount: -1.5, midpoint: 0.4, roundness: 0.3, feather: 0.5)),
    ("vignetteNegSquare", .vignette(amount: -1.5, midpoint: 0.4, roundness: -0.5, feather: 0.5)),
    ("vignettePos", .vignette(amount: 0.8, midpoint: 0.5, roundness: 1, feather: 0.2)),
    ("invert0", .invert(channel: 0, blend: 1)), ("invert2", .invert(channel: 2, blend: 0.7)), ("invertAlpha", .invert(channel: 4, blend: 0.6)),
    ("posterize", .posterize(levels: 4)),
    ("tint", .tint(black: SIMD3(0.1, 0, 0.2), white: SIMD3(1, 0.9, 0.5), amount: 0.8)),
    ("brightness", .brightnessContrast(brightness: 0.3, contrast: 0.4)),
    ("strobe1", .strobe(color: SIMD3(0.5, 0.6, 0.1), blend: 0.5, op: 1, transparent: false)),
    ("strobe2", .strobe(color: SIMD3(0.5, 0.6, 0.1), blend: 0.5, op: 2, transparent: false)),
    ("strobe3", .strobe(color: SIMD3(0.5, 0.6, 0.1), blend: 0.5, op: 3, transparent: false)),
    ("strobe4", .strobe(color: SIMD3(0.5, 0.6, 0.1), blend: 0.5, op: 4, transparent: false)),
    ("strobe0", .strobe(color: SIMD3(0.5, 0.6, 0.1), blend: 0.5, op: 0, transparent: false)),
    ("strobeT", .strobe(color: SIMD3(0.5, 0.6, 0.1), blend: 0.5, op: 0, transparent: true)),
    ("alpha1", .alphaAdjust(opacity: 0.8, ignore: false, invert: true, maskOnly: false)),
    ("alpha2", .alphaAdjust(opacity: 1, ignore: true, invert: false, maskOnly: true)),
    ("flipH", .flip(horizontal: true, vertical: false)), ("flipV", .flip(horizontal: false, vertical: true)),
    ("twirl", .twirl(center: Vec2(1, -1), angle: 60, radius: 0.7)),
    ("wave0", .waveWarp(type: 0, height: 2, width: 6, direction: 20, phase: 0.3, pinning: 0)),
    ("wave1", .waveWarp(type: 1, height: 2, width: 6, direction: 20, phase: 0.3, pinning: 1)),
    ("wave2", .waveWarp(type: 2, height: 2, width: 6, direction: 110, phase: 0.1, pinning: 2)),
    ("wave3", .waveWarp(type: 3, height: 2, width: 6, direction: 70, phase: 0.6, pinning: 3)),
    ("spherizePos", .spherize(center: Vec2(0, 0), radius: 5, strength: 0.6)),
    ("spherizeNeg", .spherize(center: Vec2(1, 1), radius: 5, strength: -0.5)),
    ("stageWarp", .stageWarp(a: 0.9, b: 0.1, c: -0.1, d: 1.1, tx: 1, ty: -0.5, opacity: 0.8)),
    ("stageFillMirror", .stageFill(a: 0.9, b: 0.1, c: -0.1, d: 1.1, tx: 2, ty: -1.5, fill: .mirror)),
    ("stageFillBlur", .stageFill(a: 1.2, b: 0, c: 0, d: 1.2, tx: 3, ty: 1, fill: .blur)),
    ("rollX", .rollingShutter(shear: Vec2(0.1, -0.05), alongX: true)),
    ("rollY", .rollingShutter(shear: Vec2(0.1, -0.05), alongX: false)),
    ("stabilize", .stabilizeWarp(shear: Vec2(0.05, 0.02), alongX: false, perspective: [0.01, 0.002, 0.5, -0.3, 0.02, 0.4, 0.001, 0.0005])),
    ("stabilizeFlat", .stabilizeWarp(shear: Vec2(0.05, 0.02), alongX: true, perspective: [0, 0, 0, 0, 0, 0, 0, 0])),
    ("corner", .cornerPin(topLeft: Vec2(1, 1), topRight: Vec2(-1, 2), bottomRight: Vec2(-2, -1), bottomLeft: Vec2(0.5, 0))),
    ("cornerDegenerate", .cornerPin(topLeft: Vec2(6, 4), topRight: Vec2(-6, 4), bottomRight: Vec2(-6, -4), bottomLeft: Vec2(6, -4))),
    ("rgbSplit", .rgbSplit(dx: 2, dy: 1, radial: false, mix: 0.2)),
    ("rgbSplitRadial", .rgbSplit(dx: 3, dy: 0, radial: true, mix: 0.5)),
    ("radialSpin", .radialBlur(center: Vec2(1, 1), amount: 20, zoom: false, high: true)),
    ("radialZoom", .radialBlur(center: Vec2(0, 0), amount: 30, zoom: true, high: false)),
    ("lensBarrel", .lensDistortion(curvature: 0.5, decenter: Vec2(0.1, -0.1), fillAlpha: false, fill: SIMD3(0.2, 0.1, 0.3), autoScale: false, exactModel: true)),
    ("lensPin", .lensDistortion(curvature: -0.4, decenter: Vec2(0, 0), fillAlpha: true, fill: SIMD3(0, 0, 0), autoScale: true, exactModel: true)),
    ("lensLegacy", .lensDistortion(curvature: 0.3, decenter: Vec2(0, 0), fillAlpha: false, fill: SIMD3(0.2, 0.2, 0.2), autoScale: false, exactModel: false)),
    ("lensStrong", .lensDistortion(curvature: -1, decenter: Vec2(0, 0), fillAlpha: true, fill: SIMD3(0, 0, 0), autoScale: false, exactModel: true)),
    ("halftoneColor", .halftone(size: 3, angle: 30, softness: 0.4, color: true, blend: 1)),
    ("halftoneMono", .halftone(size: 2.5, angle: 45, softness: 0.1, color: false, blend: 0.8)),
    ("tile", .tile(columns: 2, rows: 3, offset: Vec2(0.1, 0.2), mirror: false)),
    ("tileMirror", .tile(columns: 2.5, rows: 1.5, offset: Vec2(0.1, 0.2), mirror: true)),
    ("kaleido", .kaleidoscope(center: Vec2(0, 0), segments: 6, angle: 20, zoom: 1.2)),
    ("feather", .edgeFeather(amount: 3)),
    ("glitch", .glitch(amount: 3, block: 2, split: 1, density: 0.6, seed: 5)),
    ("leak", .lightLeak(color1: SIMD3(1, 0.5, 0.2), color2: SIMD3(0.2, 0.4, 1), intensity: 0.8, center: Vec2(0.2, -0.1), size: 0.6, angle: 0.7)),
    ("gradientLinear", .gradient(color1: SIMD3(1, 0.2, 0), color2: SIMD3(0, 0.3, 1), start: Vec2(-4, -3), end: Vec2(4, 3), radial: false, blend: 0.7)),
    ("gradientRadial", .gradient(color1: SIMD3(1, 0.2, 0), color2: SIMD3(0, 0.3, 1), start: Vec2(0, 0), end: Vec2(5, 0), radial: true, blend: 1)),
    ("notStyle", .sharpen(amount: 1)),
]
for (i, f) in styleFilters.enumerated() {
    guard let (fam, u) = StyleFilters.plan(f.1, frame: frame, pf: 1.5) else { outI("style\t\(i)\tnone", []); continue }
    let famId = [StyleFilters.Family.pixel: 0, .warp: 1, .rgbSplit: 2, .radialBlur: 3, .lens: 4, .glitch: 5][fam]!
    var vals: [Float] = [Float(famId)]
    vals += v4(u.a); vals += v4(u.b); vals += v2(u.center); vals += v2(u.frame)
    vals += [Float(u.i.x), Float(u.i.y), Float(u.i.z), Float(u.i.w)]
    vals += v4(u.c); vals += v4(u.d)
    out("plan\t\(i)\t\(f.0)", vals)
    if let r = StyleFilters.reference(f.1, image, frame: frame, pf: 1.5) { imageOut("style\t\(i)\t\(f.0)", r) }
}
out("homography", StyleFilters.homography(from: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)],
                                          to: [SIMD2(0.1, 0.2), SIMD2(1.2, 0), SIMD2(0.9, 1.1), SIMD2(0, 0.8)])!.map { Float($0) })

// MARK: visible source region and work sizes

func geom(_ canvas: (Float, Float), _ pos: Vec2, _ scale: Double, _ rot: Double, _ size: (Float, Float), _ tex: (Int, Int), _ q: UInt32, tilt: Double = 0,
          anchor: Vec2 = .zero) -> (ClipTransform, SIMD2<Float>, SIMD2<Float>, (width: Int, height: Int), UInt32) {
    (ClipTransform(position: pos, scale: Vec2(scale, scale), rotation: rot, anchor: anchor, tiltX: tilt), SIMD2(canvas.0, canvas.1), SIMD2(size.0, size.1), (tex.0, tex.1), q)
}
let regionCases = [
    geom((1080, 1920), Vec2(0, 0), 1, 0, (3840, 2160), (3840, 2160), 0), geom((1080, 1920), Vec2(100, 0), 2, 0, (3840, 2160), (3840, 2160), 0),
    geom((1080, 1920), Vec2(0, 0), 1, 90, (3840, 2160), (3840, 2160), 0), geom((1080, 1920), Vec2(0, 0), 1, 0, (3840, 2160), (2160, 3840), 1),
    geom((1080, 1920), Vec2(-37, 12), 0.7, 33, (3840, 2160), (3840, 2160), 2, anchor: Vec2(20, -10)),
    geom((1080, 1920), Vec2(5, 5), 0.5, 17, (3840, 2160), (2160, 3840), 3), geom((100, 100), Vec2(5000, 0), 1, 0, (200, 200), (200, 200), 0),
    geom((100, 100), Vec2(0, 0), 1, 0, (200, 200), (200, 100), 0, tilt: 10), geom((640, 360), Vec2(0, 0), 0.5, 0, (1280, 720), (1280, 720), 0),
]
for (i, c) in regionCases.enumerated() {
    for (pad, cp) in [(0, Float(0)), (4, 0), (2, 2)] {
        let r = Compositor.visibleSourceRegion(canvas: c.1, transform: c.0, size: c.2, texture: c.3, quarter: c.4, pad: pad, canvasPad: cp)
        outI("region\t\(i)\t\(pad)\t\(Int(cp))", r.map { [1, $0.x, $0.y, $0.width, $0.height] } ?? [0])
    }
    for (tpn, onePass, strong, halves) in [(Float(1), true, false, true), (0.5, true, false, true), (1, false, true, true), (1, true, false, false)] {
        let w = Compositor.colorWork(canvas: c.1, transform: c.0, size: c.2, texture: c.3, texelsPerNativePixel: tpn, quarter: c.4, onePass: onePass,
                                     strongBlur: strong, halves: halves)
        outI("colorwork\t\(i)\t\(Int(tpn * 2))\t\(onePass ? 1 : 0)\t\(strong ? 1 : 0)\t\(halves ? 1 : 0)", [w.width, w.height] + (w.region.map { [1, $0.x, $0.y, $0.width, $0.height] } ?? [0]))
    }
    let d = Compositor.displayColorWork(canvas: c.1, transform: c.0, size: c.2, texture: c.3, texelsPerNativePixel: 1, quarter: c.4)
    outI("display\t\(i)", d.map { [1, $0.width, $0.height] + ($0.region.map { [1, $0.x, $0.y, $0.width, $0.height] } ?? [0]) } ?? [0])
    outI("effectfactor\t\(i)", [Compositor.effectWorkFactor(transform: c.0, size: c.2)])
}

try! (lines.joined(separator: "\n") + "\n").write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print("wrote \(lines.count) lines")
