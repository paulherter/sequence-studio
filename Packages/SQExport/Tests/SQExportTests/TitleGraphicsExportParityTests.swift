import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Testing
import SQCore
import SQMedia
import SQPlayback
import SQText
@testable import SQExport

private let fd = Time(1, 30)
private let canvasW = 270, canvasH = 480

private func solidStill(_ w: Int, _ h: Int, r: Double, g: Double, b: Double) throws -> StillFrame {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return StillFrame(buffer: try StillImage.pixelBuffer(from: ctx.makeImage()!), info: StillImage.trackInfo(width: w, height: h))
}

/// Export frame as 8-bit RGB (BGRA buffer), row-major.
private func exportRGB(_ pb: CVPixelBuffer) -> [Int] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    var out: [Int] = []
    out.reserveCapacity(w * h * 3)
    for y in 0..<h { for x in 0..<w { let p = base + y * bpr + x * 4; out += [Int(p[2]), Int(p[1]), Int(p[0])] } }
    return out
}

/// Playback's linear half-float texture, encoded with the Rec.709 OETF to 8-bit RGB like the export does.
private func playbackRGB(_ t: MTLTexture, device: MTLDevice) -> [Int] {
    let w = t.width, h = t.height, bpr = w * 8
    let q = device.makeCommandQueue()!, buf = device.makeBuffer(length: bpr * h, options: .storageModeShared)!
    let cb = q.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let px = UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: Float16.self), count: w * h * 4)
    var out: [Int] = []
    out.reserveCapacity(w * h * 3)
    for i in 0..<(w * h) { for c in 0..<3 { out.append(Int((oetf709(Double(px[i * 4 + c])) * 255).rounded())) } }
    return out
}

private func oetf709(_ l: Double) -> Double {
    let l = max(0, min(1, l))
    return l < 0.018053968510807 ? 4.5 * l : 1.09929682680944 * pow(l, 0.45) - 0.09929682680944
}

private struct Diff { var max = 0; var over = 0; var count = 0 }
private func diff(_ a: [Int], _ b: [Int], tolerance: Int) -> Diff {
    var d = Diff()
    d.count = a.count
    for i in 0..<min(a.count, b.count) {
        let e = abs(a[i] - b[i])
        d.max = Swift.max(d.max, e)
        if e > tolerance { d.over += 1 }
    }
    return d
}

/// TXT-25 / GFX-43: what the Program monitor shows for a title or a graphics clip is what the export writes.
@Suite(.serialized) @MainActor struct TitleGraphicsExportParityTests {
    private let background = UUID()

    private func resolver() throws -> StaticMediaResolver {
        StaticMediaResolver(stills: [background: try solidStill(canvasW, canvasH, r: 0.15, g: 0.35, b: 0.55)])
    }

    private func backgroundTrack(_ length: Time) -> Track {
        Track(kind: .video, clips: [Clip(name: "bg", media: background, kind: .video,
                                         source: TimeRange(start: .zero, duration: length), start: .zero, isStill: true)])
    }

    private func textClip(_ text: String, size: Double, y: Double, length: Time, shadow: Bool = true) throws -> Clip {
        var style = CaptionPresetLibrary.builtIn.style(for: "title")
        style.size = size
        style.weight = .heavy
        if !shadow { style.shadow = nil }
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: text, text: text, style: style), animations: nil)
        try TextGenerator.prewarm(ref: ref)      // playback never shows a cold raster; the export waits for it
        var c = Clip(name: text, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: length), start: .zero,
                     generator: ref)
        c.animation.position = AnimatedProperty(Vec2(0, y))
        return c
    }

    /// Frames of the export source and of the playback engine at each of `times`; both must agree within 8-bit encoding.
    private func compare(_ tl: Timeline, at times: [Time], resolver: StaticMediaResolver) async throws -> [(export: [Int], playback: [Int])] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try TimelineFrameSource(timeline: tl, provider: DecoderFrameProvider(resolver: resolver),
                                             width: canvasW, height: canvasH, frameDuration: fd, frameCount: 90)
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        engine.setTimeline(tl)
        var out: [(export: [Int], playback: [Int])] = []
        for t in times {
            let index = Int(t.value * Int64(fd.timescale) / (t.timescale * fd.value))
            let exported = exportRGB(try await source.frame(at: index))
            engine.seek(to: t)
            await engine.waitForDecodes()
            #expect(engine.tick())
            let tex = try #require(engine.lastRenderedTexture)
            out.append((exported, playbackRGB(tex, device: device)))
        }
        return out
    }

    private func background(_ rgb: [Int]) -> [Int] { Array(rgb.prefix(3)) }

    /// Pixels that differ from the corner (background) pixel by more than 12: the drawn title.
    private func inkCount(_ rgb: [Int]) -> Int {
        let bg = background(rgb)
        var n = 0
        for i in stride(from: 0, to: rgb.count, by: 3) {
            if abs(rgb[i] - bg[0]) + abs(rgb[i + 1] - bg[1]) + abs(rgb[i + 2] - bg[2]) > 12 { n += 1 }
        }
        return n
    }

    /// The Add Title result: two lines (Move in from the left / right with a fade, Move out at the end) and an emoji (Pop in
    /// and out), each on its own track over a picture. In the in-animation, in the hold and in the out-animation.
    @Test func addTitleResultExportEqualsPlayback() async throws {
        let length = Time(3, 1)
        var tracks = [backgroundTrack(length)]
        let parts: [(String, Double, Double, TransitionKind, Double?)] = [
            ("Line One", 22, -100, .move, 270), ("Line Two", 22, -70, .move, 90), ("🔥", 32, -140, .pop, nil),
        ]
        for p in parts {
            var track = Track(kind: .video, clips: [try textClip(p.0, size: p.1, y: p.2, length: length)])
            var tl = Timeline(name: "t", format: SequenceFormat(width: canvasW, height: canvasH, frameDuration: fd), tracks: [track])
            let id = track.clips[0].id
            let made = try tl.addElementTransitions(kind: p.3, track: track.id, clip: id, edges: [.head, .tail], duration: Time(1, 2))
            for tid in made {
                if let dir = p.4 { try tl.setTransition(tid, params: [ClipEffect.moveDirectionKey: dir, ClipEffect.moveFadeKey: 1]) }
            }
            track = tl.tracks[0]
            tracks.append(track)
        }
        let tl = Timeline(name: "t", format: SequenceFormat(width: canvasW, height: canvasH, frameDuration: fd), tracks: tracks)
        #expect(tl.tracks.dropFirst().allSatisfy { $0.transitions.count == 2 }, "head and tail animation on every title clip")

        let times = [Time(4, 30), Time(3, 2), Time(85, 30)]      // in-animation, hold, out-animation
        let frames = try await compare(tl, at: times, resolver: try resolver())
        for (i, f) in frames.enumerated() {
            let d = diff(f.export, f.playback, tolerance: 3)
            #expect(d.over == 0, "frame \(i): \(d.over) of \(d.count) channel values differ by more than 3 (max \(d.max))")
        }
        // The title is really drawn, and it is animated: the hold shows more ink than the frames inside the animations.
        let ink = frames.map { inkCount($0.export) }
        #expect(ink[1] > 200, "hold frame shows the title (ink \(ink[1]))")
        #expect(ink[0] < ink[1] && ink[2] < ink[1], "in/out animation frames show less of the title: \(ink)")
        #expect(diff(frames[0].export, frames[1].export, tolerance: 3).over > 0)
    }

    /// A Graphics clip: a pill (rectangle layer) behind a text layer with a Drop Shadow and a blend mode on the text layer.
    @Test func graphicsClipWithTextShadowAndBlendExportEqualsPlayback() async throws {
        let length = Time(3, 1)
        var pill = GraphicsLayer.shape(.rectangle, canvasWidth: canvasW, canvasHeight: canvasH)
        pill.setShapeSize(width: 200, height: 60)
        var style = CaptionPresetLibrary.builtIn.style(for: "title")
        style.size = 30
        style.weight = .heavy
        style.shadow = nil
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "Go", text: "FOLLOW", style: style), animations: nil)
        try TextGenerator.prewarm(ref: ref)
        var label = GraphicsLayer.text(ref, name: "Label")
        label.effects = [try #require(ClipEffect.make(kind: ClipEffect.dropShadowKind))]
        label.blendMode = .difference
        var plain = label                      // the same graphic without shadow and blend: must look different
        plain.effects = []
        plain.blendMode = .normal

        func timeline(_ text: GraphicsLayer) -> Timeline {
            var g = Clip(name: "Graphic", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: length), start: .zero,
                         generator: .graphicsClip)
            g.graphics = GraphicsDocument(layers: [pill, text])
            return Timeline(name: "t", format: SequenceFormat(width: canvasW, height: canvasH, frameDuration: fd),
                            tracks: [backgroundTrack(length), Track(kind: .video, clips: [g])])
        }
        let res = try resolver()
        let times = [Time(1, 30), Time(3, 2)]
        let frames = try await compare(timeline(label), at: times, resolver: res)
        for (i, f) in frames.enumerated() {
            let d = diff(f.export, f.playback, tolerance: 3)
            #expect(d.over == 0, "frame \(i): \(d.over) of \(d.count) channel values differ by more than 3 (max \(d.max))")
        }
        #expect(inkCount(frames[1].export) > 300, "the graphic is drawn")
        let reference = try await compare(timeline(plain), at: [times[1]], resolver: res)
        var shadowOnly = plain
        shadowOnly.effects = label.effects
        var blendOnly = plain
        blendOnly.blendMode = .difference
        let shadow = try await compare(timeline(shadowOnly), at: [times[1]], resolver: res)
        let blend = try await compare(timeline(blendOnly), at: [times[1]], resolver: res)
        let dShadow = diff(shadow[0].export, reference[0].export, tolerance: 3), dBlend = diff(blend[0].export, reference[0].export, tolerance: 3)
        #expect(dShadow.over > 0, "Drop Shadow changes the picture (max \(dShadow.max))")
        #expect(dBlend.over > 0, "Difference blend changes the picture (max \(dBlend.max))")
        // Each of them is itself the same in playback and export.
        for f in [shadow[0], blend[0]] { #expect(diff(f.export, f.playback, tolerance: 3).over == 0) }
    }

    /// Item lanes: a ranged text item (with an In and an Out animation, which run on the range) and a ranged shape item
    /// are the same rendered picture in the monitor and in the export on the frame before the range, on its first and its
    /// last frame and on the frame after it; outside the range neither draws the item.
    @Test func aRangedItemExportEqualsPlaybackAroundItsRange() async throws {
        let length = Time(3, 1)
        var style = CaptionPresetLibrary.builtIn.style(for: "title")
        style.size = 30
        style.weight = .heavy
        let third = Time(1, 3)
        let animations = AnimationSet(
            in: KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (third, 1, .linear)])],
                                 duration: third),
            out: KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (third, 0, .linear)])],
                                  duration: third))
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "R", text: "RANGE", style: style), animations: animations)
        try TextGenerator.prewarm(ref: ref)
        var label = GraphicsLayer.text(ref, name: "Label")
        label.range = TimeRange(start: Time(1, 1), end: Time(2, 1))
        var pill = GraphicsLayer.shape(.rectangle, canvasWidth: canvasW, canvasHeight: canvasH)
        pill.setShapeSize(width: 120, height: 30)
        pill.animation.position = AnimatedProperty(Vec2(0, 150))
        pill.range = label.range
        var g = Clip(name: "Graphic", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: length), start: .zero,
                     generator: .graphicsClip)
        g.graphics = GraphicsDocument(layers: [pill, label])
        let tl = Timeline(name: "t", format: SequenceFormat(width: canvasW, height: canvasH, frameDuration: fd),
                          tracks: [backgroundTrack(length), Track(kind: .video, clips: [g])])

        // Before the range, its first frame, the middle, its last frame, after the range.
        let times = [Time(29, 30), Time(30, 30), Time(45, 30), Time(59, 30), Time(60, 30)]
        let frames = try await compare(tl, at: times, resolver: try resolver())
        for (i, f) in frames.enumerated() {
            let d = diff(f.export, f.playback, tolerance: 3)
            #expect(d.over == 0, "frame \(i): \(d.over) of \(d.count) channel values differ by more than 3 (max \(d.max))")
        }
        let ink = frames.map { (export: inkCount($0.export), playback: inkCount($0.playback)) }
        #expect(ink[0].export == 0 && ink[0].playback == 0, "nothing before the range: \(ink[0])")
        #expect(ink[4].export == 0 && ink[4].playback == 0, "nothing after the range: \(ink[4])")
        for i in 1...3 { #expect(ink[i].export > 300 && ink[i].playback > 300, "the items are drawn inside the range: \(ink[i])") }
        // The text fades in at the range's start (the animation runs on the range, not on the clip, where 1 s would be
        // long past a fade of a third of a second): the middle shows more of it than the first frame, in both.
        #expect(ink[2].export > ink[1].export, "export ink \(ink.map(\.export))")
        #expect(ink[2].playback > ink[1].playback, "playback ink \(ink.map(\.playback))")
    }
}
