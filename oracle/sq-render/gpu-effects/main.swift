import Foundation
import SQCore

// Dumps the plan functions of the effect chain (EffectChainPlan, FilmLookPlan, MaskData, OutlineFilters) to
// golden/gpu-effects.tsv. One line per case: `tag<TAB>id...<TAB>values`. The Rust test (crates/sq-render/src/gpu_effects/golden.rs)
// builds the same cases.

var lines: [String] = []
func out(_ tag: String, _ v: [Float]) { lines.append(tag + "\t" + v.map { "\($0)" }.joined(separator: " ")) }

// MARK: Outline and Long Shadow

for reach in [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 17.0, 33.0, 100.0, 1000.0] {
    out("jump\t\(reach)", OutlineFilters.jumpSteps(reach: reach).map { Float($0) })
}
for (w, h) in [(1920, 1080), (4096, 4096), (4097, 4096), (8192, 4608), (3, 20000)] {
    let p = OutlineFilters.shadowPlaneSize(width: w, height: h)
    out("plane\t\(w)\t\(h)", [Float(p.0), Float(p.1)])
}
for length in [0.0, 0.5, 1.0, 2.0, 7.0, 10.0, 37.5, 100.0, 1234.5] {
    out("steps\t\(length)", OutlineFilters.shadowSteps(length: length).map { Float($0) })
}

// MARK: Effect chain plan

let filters: [ImageFilter?] = [
    nil, .sharpen(amount: 1), .directionalBlur(dx: 4, dy: 0), .glow(threshold: 0.5, sigma: 3, intensity: 1, color: nil),
    .mosaic(columns: 4, rows: 4, sharp: false), .flip(horizontal: true, vertical: false),
    .outline(width: 4, color: SIMD3(1, 0, 0), softness: 1, position: .outside),
    .longShadow(angle: 90, length: 30, color: SIMD3(0, 0, 0), fade: 0.2, opacity: 1),
]
for (i, f) in filters.enumerated() {
    let seg = EffectSegment(blurAfter: f == nil ? 4 : 0, filter: f)
    out("budget\t\(i)", [Float(Compositor.pixelBudget(seg) == .max ? -1 : Compositor.pixelBudget(seg)), Compositor.worksAtReducedSize(seg) ? 1 : 0])
}
let blur = { (s: Double) in EffectSegment(blurAfter: s) }
let chains: [[EffectSegment]] = [
    [blur(2), EffectSegment()], [blur(3), EffectSegment()], [blur(9), EffectSegment(filter: .sharpen(amount: 1)), EffectSegment()],
    [EffectSegment(filter: .directionalBlur(dx: 4, dy: 0)), EffectSegment()], [EffectSegment()],
    [blur(5), EffectSegment(filter: .glow(threshold: 0.5, sigma: 3, intensity: 1, color: nil)), EffectSegment()],
]
for (i, c) in chains.enumerated() {
    for display in [1, 2, 4] {
        for strong in [true, false] {
            out("chain\t\(i)\t\(display)\t\(strong ? 1 : 0)", [Float(Compositor.effectChainFactor(c, display: display, strongBlurHalves: strong))])
        }
    }
}
for (fw, fh, tw, th) in [(10.0, 6.0, 16, 12), (16.0, 12.0, 16, 12), (15.5, 11.5, 16, 12), (100.0, 50.0, 128, 64), (0.0, 0.0, 8, 8), (3.0, 3.0, 4, 4)] {
    let r = Compositor.repeatEdgeRect(frame: SIMD2(Float(fw), Float(fh)), texture: SIMD2(tw, th))
    out("edge\t\(fw)\t\(fh)\t\(tw)\t\(th)", [Float(r.lo.x), Float(r.lo.y), Float(r.hi.x), Float(r.hi.y)])
}

// MARK: Film look uniforms

func lookRow(_ id: String, _ look: FilmLook, _ w: Int, _ h: Int) {
    let u = Compositor.lookUniforms(look, width: w, height: h)
    out("look\t\(id)", [u.dims.x, u.dims.y, u.dims.z, u.dims.w] + [u.ids.x, u.ids.y, u.ids.z, u.ids.w].map { Float(bitPattern: $0) }
        + [u.grain.x, u.grain.y, u.grain.z, u.grain.w, u.scan.x, u.scan.y, u.scan.z, u.scan.w, u.chroma.x, u.chroma.y, u.chroma.z, u.chroma.w]
        + [u.track.x, u.track.y, u.track.z, u.track.w, u.aged.x, u.aged.y, u.aged.z, u.aged.w])
}
lookRow("none", .none, 1920, 1080)
var look = FilmLook.none
look.grain = FilmLook.Grain(amount: 0.3, size: 1.5, softness: 0.4, lumaWeight: 0.7, color: 0.25, seed: 1234)
lookRow("grain", look, 1920, 1080)
look.scanlines = FilmLook.Scanlines(intensity: 0.5, spacing: 4, thickness: 0.25)
look.chromaBleed = FilmLook.ChromaBleed(bleed: 0.6, shift: 2)
look.tracking = FilmLook.Tracking(amount: 0.4, bandHeight: 30, phase: 0.125, seed: 77)
look.aged = FilmLook.Aged(dust: 0.2, scratches: 0.3, flicker: 0.1, seed: 99)
lookRow("all", look, 960, 540)

// MARK: Mask data

func square(_ lo: Double, _ hi: Double) -> [Vec2] { [Vec2(lo, lo), Vec2(hi, lo), Vec2(hi, hi), Vec2(lo, hi)] }
var path = MaskShape(polygon: square(0.25, 0.75), feather: 4, expansion: -2, opacity: 0.5, inverted: true, mode: .subtract)
var plain = MaskShape(polygon: [Vec2(0.1, 0.2), Vec2(0.9, 0.3), Vec2(0.5, 0.95)])
var range = MaskShape(polygon: [])
range.source = .colorRange
range.colorRange = ColorRangeKey(red: 0.2, green: 0.4, blue: 0.6, tolerance: 0.3, softness: 0.1)
var subject = MaskShape(polygon: square(0, 1))
subject.source = .subject
var picture = MaskShape(polygon: [])
picture.source = .picture
picture.pictureChannel = .brightness
var u = Compositor.Uniforms()
u.canvas = SIMD2(1920, 1080); u.size = SIMD2(800, 600); u.position = SIMD2(40, -30); u.anchor = SIMD2(5, -7); u.scale = SIMD2(1.25, 0.75)
u.rotCos = 0.8; u.rotSin = 0.6; u.tilt = SIMD3(0.1, -0.2, 900)
let screen = Compositor.screenFromLocal(u)
let sm = [screen.row0.x, screen.row0.y, screen.row1.x, screen.row1.y, screen.translation.x, screen.translation.y, screen.canvas.x, screen.canvas.y,
          screen.tilt.x, screen.tilt.y, screen.tilt.z, screen.center.x, screen.center.y]
out("screen", sm)
let scaled = screen.scaled(0.5)
out("screenScaled", [scaled.row0.x, scaled.row0.y, scaled.row1.x, scaled.row1.y, scaled.translation.x, scaled.canvas.x, scaled.center.x])
func flat(_ e: [SIMD2<Float>]) -> [Float] { e.flatMap { [$0.x, $0.y] } }
let frame = SIMD2<Float>(200, 100)
out("masks\tpath", flat(Compositor.maskEntries([path, plain], frame: frame, edgeScale: 0.5, screen: nil, pictureSlot: [-1, -1], matteSlot: [-1, -1], hasMatte: false)))
out("masks\trange", flat(Compositor.maskEntries([range, path], frame: frame, edgeScale: 1, screen: nil, pictureSlot: [-1, -1], matteSlot: [-1, -1], hasMatte: false)))
out("masks\tmatte", flat(Compositor.maskEntries([subject, path], frame: frame, edgeScale: 1, screen: nil, pictureSlot: [-1, -1], matteSlot: [2, -1], hasMatte: true)))
out("masks\tnomatte", flat(Compositor.maskEntries([subject], frame: frame, edgeScale: 1, screen: nil, pictureSlot: [-1], matteSlot: [2], hasMatte: false)))
out("masks\tpicture", flat(Compositor.maskEntries([picture, path], frame: frame, edgeScale: 1, screen: screen, pictureSlot: [1, -1], matteSlot: [-1, -1], hasMatte: false)))
out("masks\tpicturemissing", flat(Compositor.maskEntries([picture], frame: frame, edgeScale: 1, screen: screen, pictureSlot: [-1], matteSlot: [-1], hasMatte: false)))
for m in [MaskMode.add, .subtract, .intersect, .difference] { out("mode\t\(m)", [Float(Compositor.maskModeID(m))]) }

try lines.joined(separator: "\n").appending("\n").write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print("wrote \(lines.count) rows")
