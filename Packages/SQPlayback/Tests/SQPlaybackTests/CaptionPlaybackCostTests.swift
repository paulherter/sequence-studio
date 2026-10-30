import CoreMedia
import Foundation
import Metal
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
import SQText
@testable import SQPlayback

// Playback cost of animated captions over a keyframed video clip (ENGINE-NOTES "Animated captions"): one tick per frame
// with and without the captions, per animation kind, and the split of the caption work (lookup, plan, frame, layout,
// raster, new textures, GPU).

private let fd = Time(1, 30)

private actor CostClip {
    static let shared = CostClip()
    private var url: URL?
    func get() async throws -> URL {
        if let url { return url }
        var spec = TestClipSpec(); spec.frameCount = 90
        let u = try await TestClipWriter.write(spec)
        url = u
        return u
    }
}

enum CaptionCostKind: String, CaseIterable, Sendable {
    case none, still, pop, wave, karaokePop, wordAnimator, characterAnimator, karaokeWordAnimator, wordAnimatorOut, custom

    /// A Custom intro as the Controls rows write it: Opacity, Scale, Position and Rotation keyed by hand over 8 frames.
    static let customIntro: KeyframeTemplate = {
        let d = Time(15, 30), end = Time(8, 30)
        var set = AnimationSet(in: .customStart(.intro), out: nil)
        set.edit(.opacity, side: .intro, clipDuration: d) { p in
            if let last = p.track.keys.last?.id { p.track.move(last, to: end) }
        }
        set.edit(.scale, side: .intro, clipDuration: d) { p in
            p.track.insert(Keyframe(time: .zero, value: 0.8, interpolation: .bezier))
            p.track.insert(Keyframe(time: end, value: 1))
        }
        set.edit(.rotation, side: .intro, clipDuration: d) { p in
            p.track.insert(Keyframe(time: .zero, value: -6, interpolation: .bezier))
            p.track.insert(Keyframe(time: end, value: 0))
        }
        set.editPosition(side: .intro, clipDuration: d) { p in
            p.track.insert(Keyframe(time: .zero, value: Vec2(0, 60), interpolation: .bezier))
            p.track.insert(Keyframe(time: end, value: .zero))
        }
        return set.animationIn ?? .none
    }()

    var karaoke: Bool { self == .karaokePop || self == .karaokeWordAnimator }
    /// A text animator: every frame of it is a raster of its own (the other kinds move one raster on the GPU).
    var animated: Bool { [.wordAnimator, .characterAnimator, .karaokeWordAnimator, .wordAnimatorOut].contains(self) }

    var animation: KeyframeTemplate {
        let word = TextAnimator(effect: .pop, unit: .word, easing: .overshoot, duration: Time(1, 5), stagger: Time(1, 10))
        switch self {
        case .none, .still: return .none
        case .pop, .karaokePop: return .captionPop
        case .wave: return CaptionPresetLibrary.builtIn.animation(for: "wave")
        case .custom: return Self.customIntro
        case .wordAnimator, .karaokeWordAnimator: return KeyframeTemplate(textAnimator: word)
        case .characterAnimator:
            return KeyframeTemplate(textAnimator: TextAnimator(effect: .slide, unit: .character, duration: Time(1, 5), stagger: Time(1, 60)))
        case .wordAnimatorOut:
            return KeyframeTemplate(textAnimator: TextAnimator(effect: .blur, unit: .word, duration: Time(1, 5), stagger: Time(1, 15)),
                                    anchor: .end)
        }
    }
}

/// A 90-frame sequence: one video clip with keyframed Scale and, for every kind but `.none`, six captions of three
/// words (15 frames each) in a registered look whose size follows the canvas.
@MainActor struct CaptionCostScene {
    let engine: PlaybackEngine
    let clock: ManualClock
    let timeline: Timeline
    let lookID: String
    static let frames = 90

    /// `animation`: the look's animation instead of the kind's.
    init(kind: CaptionCostKind, width: Int, height: Int, text: GeneratorRef? = nil, animation: KeyframeTemplate? = nil) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let media = UUID()
        let resolver = StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: try await CostClip.shared.get())], audio: [:])
        clock = ManualClock()
        engine = try PlaybackEngine(device: device, media: resolver, clock: clock)
        engine.quality = .full
        engine.waitsForStartFrame = false
        var clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 90), start: .zero)
        let fill = Double(max(width, height)) / 320
        clip.animation.scale = AnimatedProperty(Vec2(fill, fill), track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(fill, fill)), Keyframe(time: fd * 45, value: Vec2(fill * 1.3, fill * 1.3)),
            Keyframe(time: fd * 90, value: Vec2(fill, fill)),
        ]))
        var tracks = [Track(kind: .video, clips: [clip])]
        if let text {
            let id = UUID()
            tracks.append(Track(kind: .video, clips: [Clip(id: id, name: "Text", media: id, kind: .video,
                                                           source: TimeRange(start: .zero, duration: fd * 90), start: .zero, generator: text)]))
        }
        var tl = Timeline(name: "cost", format: SequenceFormat(width: width, height: height, frameDuration: fd), tracks: tracks)
        lookID = "cost-\(kind.rawValue)-\(width)"
        if kind != .none {
            var style = CaptionPresetLibrary.builtIn.style(for: "tiktok")
            style.size *= Double(max(width, height)) / 1920
            let refs = CaptionLookRegistry.shared.register(CaptionLook(style: style, animation: animation ?? kind.animation), id: lookID)
            let texts = [["these", "are", "words"], ["spoken", "over", "video"], ["with", "a", "look"],
                         ["that", "moves", "in"], ["word", "by", "word"], ["until", "the", "end"]]
            var items: [CaptionItem] = []
            for (i, w) in texts.enumerated() {
                let start = fd * Int64(i * 15)
                let words = w.enumerated().map { CaptionWord(text: $1, range: TimeRange(start: start + fd * Int64($0 * 5), duration: fd * 5)) }
                items.append(CaptionItem(lines: [w.joined(separator: " ")], range: TimeRange(start: start, duration: fd * 15),
                                         styleRef: refs.styleRef, animationRef: refs.animationRef, words: words))
            }
            let track = try tl.replaceCaptions(items)
            if kind.karaoke { try tl.setCaptionKaraoke(KaraokeStyle(), track: track) }
        }
        timeline = tl
        engine.setTimeline(tl)
        engine.seek(to: .zero)
        for _ in 0..<200 {
            _ = engine.tick()
            await engine.waitForDecodes()
            if let p = engine.lastTickProfile, p.presented, p.missing == 0, p.noFrame == 0 { break }
        }
    }

    func close() { CaptionLookRegistry.shared.unregister(id: lookID) }

    struct Pass {
        var tick: [Double] = [], build: [Double] = [], encode: [Double] = [], gpu: [Double] = []
        var textures = 0
        /// In-between frames the ticks drew themselves, waited for, and the ones drawn ahead on the text lane meanwhile.
        var drawn = 0, waited = 0, ahead = 0
    }

    /// `ticks` paused ticks, each followed by the end of the rasters it asked for (static layouts and the text lane):
    /// this scene's own work (`RasterTally.drain`), whatever other suites have in flight.
    func settle(ticks: Int = 20) async {
        let tally = TextGenerator.RasterTally()
        for _ in 0..<ticks {
            TextGenerator.$rasterTally.withValue(tally) { _ = engine.tick() }
            #expect(await tally.drained(), "rasters asked for by a paused tick did not end")
        }
    }

    /// One pass in playback order (one tick per frame); `each` sees every presented frame. `drained`: a tick starts when
    /// the text lane has finished the frames the tick before started ahead, so the counts do not depend on the load of
    /// the machine: what the look-ahead did not start is the tick's own work and is counted, and nothing is in flight to
    /// wait for. `reverse`: from the last frame backwards (`each` still counts ticks from 0).
    /// The counts are this pass's own (`RasterTally`: what its ticks drew, waited for and started ahead), never the
    /// process-wide statistics, which other suites running in parallel move too; the drain waits for the rasters this
    /// pass's ticks asked for (woken by the last one), not for a process-wide count.
    func pass(drained: Bool = false, reverse: Bool = false, _ each: ((Int, MTLTexture) throws -> Void)? = nil) async throws -> Pass {
        engine.pause()
        engine.seek(to: reverse ? fd * Int64(Self.frames - 1) : .zero)
        for _ in 0..<50 {
            _ = engine.tick()
            await engine.waitForDecodes()
            if let p = engine.lastTickProfile, p.presented, p.missing == 0, p.noFrame == 0 { break }
        }
        engine.play(reverse ? .reverse : .forward)
        var out = Pass()
        let wall = ContinuousClock()
        let before = engine.loop.planeTextureCounts()
        let tally = TextGenerator.RasterTally()
        for f in 0..<Self.frames {
            await engine.waitForDecodes()
            _ = engine.loop.planeTextureCounts()   // the warm of the last tick is done
            if drained { #expect(await tally.drained(), "frame \(f): the rasters of the tick before did not end") }
            var shown = false
            out.tick.append(SQTiming.ms(wall.measure { shown = TextGenerator.$rasterTally.withValue(tally) { engine.tick() } }))
            if let p = engine.lastTickProfile, shown {
                out.build.append(SQTiming.ms(p.build)); out.encode.append(SQTiming.ms(p.encode))
            }
            if shown, let each, let tex = engine.lastRenderedTexture { try each(f, tex) }
            // The GPU time of this frame arrives with its completion handler.
            let deadline = ContinuousClock.now + .milliseconds(200)
            while engine.lastTickProfile?.gpu == nil, ContinuousClock.now < deadline { usleep(200) }
            if let g = engine.lastTickProfile?.gpu { out.gpu.append(SQTiming.ms(g)) }
            clock.advance(by: fd)
        }
        let after = engine.loop.planeTextureCounts()
        out.textures = after.drawn + after.warmed - before.drawn - before.warmed
        if drained { #expect(await tally.drained(), "the rasters of the pass did not end") }   // a frame started ahead counts when it is drawn
        out.drawn = tally.drawn; out.waited = tally.waited; out.ahead = tally.ahead
        return out
    }
}

private func costPixels(_ t: MTLTexture, device: MTLDevice) -> [Float16] {
    let w = t.width, h = t.height, bpr = w * 8
    let q = device.makeCommandQueue()!, buf = device.makeBuffer(length: bpr * h, options: .storageModeShared)!
    let cb = q.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: Float16.self), count: w * h * 4))
}

private func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
private func p95(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.95))] }
private func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
private func s(_ v: Double) -> String { String(format: "%.2f", v) }

@Suite(.serialized) @MainActor struct CaptionPlaybackCostTests {
    /// Prints the per-frame cost per animation kind (first pass on a cold animated cache = what playback pays, then a
    /// second pass) and the split of the caption work. The bounds are loose: the numbers are the result.
    @Test(arguments: [[1080, 1920], [3840, 2160]])
    func animatedCaptionFrameCost(_ size: [Int]) async throws {
        let w = size[0], h = size[1]
        var lines: [String] = []
        var baseline = 0.0
        for kind in CaptionCostKind.allCases {
            TextGenerator.clearCache()
            let scene = try await CaptionCostScene(kind: kind, width: w, height: h)
            defer { scene.close() }
            let first = try await scene.pass(drained: true), second = try await scene.pass(drained: true)
            if kind == .none { baseline = mean(first.tick) }
            // "PERF " lines are what scripts/test.sh prints of a passing run (200 characters each).
            lines.append("PERF captions \(w)x\(h) \(kind.rawValue): p1 tick \(s(mean(first.tick))) p95 \(s(p95(first.tick))) "
                + "max \(s(first.tick.max() ?? 0)) build \(s(mean(first.build))) gpu \(s(median(first.gpu))) tex \(first.textures) "
                + "drawn \(first.drawn) waited \(first.waited) ahead \(first.ahead) | p2 tick \(s(mean(second.tick))) "
                + "tex \(second.textures) drawn \(second.drawn + second.waited) ahead \(second.ahead)")
            if kind != .none {
                // An animated caption may cost a little over the plain picture, never a re-raster per frame: on the cold
                // first pass the in-between frames come from the look-ahead (without it the ticks draw every one of them).
                // That is asserted on the counts below, which do not move with the load of the machine; the time is the
                // printed line, bounded only against a tick that is slower by an order of magnitude.
                #expect(mean(second.tick) < baseline + SQTiming.budget(40), "\(kind.rawValue): \(mean(second.tick)) ms vs \(baseline) ms")
                // A look without a text animator moves one raster on the GPU: no in-between frame at all.
                if !kind.animated {
                    #expect(first.drawn + first.ahead + second.drawn + second.ahead == 0, "\(kind.rawValue) drew in-between frames")
                }
                // What the bounded cache dropped during pass 1 (4K) comes back from the look-ahead.
                #expect(second.drawn <= 2, "\(kind.rawValue): pass 2 drew \(second.drawn)")
                // The lane is drained before every tick: nothing is in flight that a tick could wait for.
                #expect(first.waited == 0 && second.waited == 0, "\(kind.rawValue): waited \(first.waited), \(second.waited)")
            }
            if kind.animated {
                #expect(first.ahead > 0, "\(kind.rawValue): nothing was drawn ahead")
                #expect(first.drawn <= max(2, first.ahead / 8),
                        "\(kind.rawValue): the ticks drew \(first.drawn) of \(first.ahead) frames drawn ahead")
            }
        }
        print(lines.joined(separator: "\n"))   // ms per frame over 90 frames
    }

    /// Captions with a word-animator out Look hand over to each other every 15 frames, so the earlier caption's tail is
    /// drawn under the next one. Once the cache is warm, no tick draws or waits for any in-between frame, tail included.
    @Test func theTailOfAHeldCaptionNeverRastersOnTheRenderThread() async throws {
        TextGenerator.clearCache()
        let scene = try await CaptionCostScene(kind: .wordAnimatorOut, width: 1080, height: 1920)
        defer { scene.close() }
        _ = try await scene.pass(drained: true)
        let second = try await scene.pass(drained: true)
        #expect(second.drawn == 0, "a tick drew \(second.drawn) in-between frames itself")
        #expect(second.waited == 0, "a tick waited for \(second.waited) in-between frames")
    }

    /// An animated text clip whose box is the whole 4K canvas: its in-between frames are cropped and drawn ahead like a
    /// caption's, so the ticks stay near the plain picture.
    @Test func animatedTextClipFrameCostAt4K() async throws {
        TextGenerator.clearCache()
        let plain = try await CaptionCostScene(kind: .none, width: 3840, height: 2160)
        let baseline = mean(try await plain.pass(drained: true).tick)
        plain.close()
        let style = TextStyle(fontName: "Helvetica-Bold", size: 260, color: .white, stroke: TextStroke(color: .black, width: 12),
                              shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.8), offsetX: 10, offsetY: 16, blur: 24))
        let animator = TextAnimator(effect: .slide, unit: .character, duration: Time(1, 2), stagger: Time(1, 15))
        let ref = try TextGenerator.makeRef(
            template: TextTemplate(name: "t", text: "Big words fill the whole frame", style: style, box: TextBox(width: 3840, height: 2160)),
            animations: AnimationSet(in: KeyframeTemplate(textAnimator: animator), out: nil))
        let scene = try await CaptionCostScene(kind: .none, width: 3840, height: 2160, text: ref)
        defer { scene.close() }
        let first = try await scene.pass(drained: true)
        print("PERF text clip 3840x2160 character slide: tick mean \(s(mean(first.tick))) p95 \(s(p95(first.tick))) "
            + "max \(s(first.tick.max() ?? 0)) drawn \(first.drawn) waited \(first.waited) ahead \(first.ahead) | plain \(s(baseline))")
        // Counts, not time: they do not move with the load of the machine (the time is the printed line).
        #expect(first.ahead > 0, "nothing was drawn ahead")
        #expect(first.drawn <= max(2, first.ahead / 8), "the ticks drew \(first.drawn) of \(first.ahead) frames drawn ahead")
        #expect(first.waited == 0)

        // Played backwards the frames are drawn ahead in that direction.
        TextGenerator.clearCache()
        _ = scene.engine.tick()   // the static raster again (its layout is what the states are made from)
        let back = try await scene.pass(drained: true, reverse: true)
        print("PERF text clip 3840x2160 character slide, reverse: tick mean \(s(mean(back.tick))) max \(s(back.tick.max() ?? 0)) "
            + "drawn \(back.drawn) waited \(back.waited) ahead \(back.ahead)")
        #expect(back.ahead > 0, "reverse: nothing was drawn ahead")
        #expect(back.drawn <= max(2, back.ahead / 8), "reverse: the ticks drew \(back.drawn) of \(back.ahead) frames drawn ahead")
        #expect(back.waited == 0)

        // The same clip with something that reads its whole rectangle (a blend mode, a blur, a corner radius): the same
        // cropped frames drawn ahead, which the compositor reads as a part of the whole picture (`contentPart`), in
        // place. The "whole picture first" numbers are the switch off: the part copied into a cleared whole box.
        // Before those, every tick drew a whole-box frame itself (the last line: the loop told to do that again).
        for what in ["blend mode", "blur", "corner radius"] {
            var changed = scene.timeline
            var clip = changed.tracks[1].clips[0]
            switch what {
            case "blend mode": clip.blendMode = .screen
            case "blur":
                var e = try #require(ClipEffect.make(kind: ClipEffect.gaussianBlurKind))
                e.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(12.0)
                clip.effects = [e]
            default: clip.roundedCorners = .roundedCorners(radius: 120)
            }
            changed.tracks[1] = Track(kind: .video, clips: [clip])
            scene.engine.setTimeline(changed)
            TextGenerator.clearCache()
            _ = scene.engine.tick()
            let loop = scene.engine.loop
            let fills = loop.partialContentFills, draws = loop.partialContentDraws
            let p = try await scene.pass(drained: true)
            let cold = loop.partialContentDraws - draws
            print("PERF text clip 3840x2160 with a \(what): tick mean \(s(mean(p.tick))) p95 \(s(p95(p.tick))) max \(s(p.tick.max() ?? 0)) "
                + "encode \(s(mean(p.encode))) gpu \(s(median(p.gpu))) drawn \(p.drawn) waited \(p.waited) ahead \(p.ahead) "
                + "parts \(cold)")
            #expect(cold > 0, "\(what): no frame was drawn as a part of its box")
            #expect(loop.partialContentFills == fills, "\(what): playback made a whole picture of a part")
            #expect(p.ahead > 0, "\(what): nothing was drawn ahead")
            #expect(p.drawn <= max(2, p.ahead / 8), "\(what): the ticks drew \(p.drawn) of \(p.ahead) frames drawn ahead")
            #expect(p.waited == 0)
            // Against the switch off (`Compositor.drawsContentPartsDirectly`): a clear and a copy of the whole box per
            // frame. Both on the warm cache, so the two passes show the same frames.
            let warmDraws = loop.partialContentDraws
            let r = try await scene.pass(drained: true)
            let inPlace = loop.partialContentDraws - warmDraws
            loop.setDrawsContentPartsDirectly(false)
            let q = try await scene.pass(drained: true)
            loop.setDrawsContentPartsDirectly(true)
            let filled = loop.partialContentFills - fills
            print("PERF text clip 3840x2160 with a \(what), warm: in place tick \(s(mean(r.tick))) encode \(s(mean(r.encode))) "
                + "gpu \(s(median(r.gpu))) | whole picture first (switch off) tick \(s(mean(q.tick))) "
                + "encode \(s(mean(q.encode))) gpu \(s(median(q.gpu))) fills \(filled)")
            #expect(filled > 0 && filled == inPlace, "\(what): \(filled) whole pictures for \(inPlace) parts read in place")
            #expect(loop.partialContentDraws - warmDraws == inPlace, "\(what): the whole-picture pass read a part in place")
            if what == "blend mode" {
                scene.engine.loop.cropsTextClips.withLock { $0 = false }
                defer { scene.engine.loop.cropsTextClips.withLock { $0 = true } }
                TextGenerator.clearCache()
                _ = scene.engine.tick()
                let whole = try await scene.pass(drained: true)
                print("PERF text clip 3840x2160 with a blend mode, whole-box frames (before): tick mean \(s(mean(whole.tick))) "
                    + "drawn \(whole.drawn) ahead \(whole.ahead)")
                #expect(whole.ahead == 0 && whole.drawn > 0)
            }
        }
    }

    /// A text clip left-aligned in a box (the painted part far from the box center), moved by whole pixels and under
    /// scale, rotation, position and anchor: the composited picture with cropped in-between frames is the picture with
    /// whole-box frames (what the export rasters), bit for bit.
    @Test func croppedTextClipFramesCompositeToTheSamePicture() async throws {
        TextGenerator.clearCache()
        let device = try #require(MTLCreateSystemDefaultDevice())
        var style = TextStyle(fontName: "Helvetica-Bold", size: 44, color: .white, stroke: TextStroke(color: .black, width: 5),
                              shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.8), offsetX: 5, offsetY: 7, blur: 6))
        style.alignment = .left
        let animator = TextAnimator(effect: .pop, unit: .word, easing: .overshoot, duration: Time(1, 2), stagger: Time(1, 6))
        let ref = try TextGenerator.makeRef(
            template: TextTemplate(name: "t", text: "same picture\neither way", style: style, box: TextBox(width: 560, height: 300)),
            animations: AnimationSet(in: KeyframeTemplate(textAnimator: animator), out: nil))
        let scene = try await CaptionCostScene(kind: .none, width: 640, height: 360, text: ref)
        defer { scene.close() }
        let frames: Set<Int> = [1, 3, 6, 10, 15, 22, 40]
        func shots() async throws -> ([Int: [Float16]], ahead: Int) {
            var out: [Int: [Float16]] = [:]
            let p = try await scene.pass(drained: true) { f, tex in if frames.contains(f) { out[f] = costPixels(tex, device: device) } }
            return (out, p.ahead)
        }
        // The part is drawn with the whole box's quad and read at the whole picture's texel coordinates, so the sampler
        // filters with the same weights as for a whole-box frame. (Drawn as a layer of its own size it was up to 0.005
        // off under scale and rotation: 8-bit filter weights from other texture coordinates.)
        let loop = scene.engine.loop
        for (aligned, tolerance) in [(true, Float(0)), (false, Float(0))] {
            var tl = scene.timeline
            var clip = tl.tracks[1].clips[0]
            clip.animation.position = AnimatedProperty(aligned ? Vec2(23, -11) : Vec2(23.5, -11.25))
            if !aligned {
                clip.animation.scale = AnimatedProperty(Vec2(1.3, 0.85))
                clip.animation.rotation = AnimatedProperty(19.0)
                clip.animation.anchor = AnimatedProperty(Vec2(14, -6))
            }
            tl.tracks[1] = Track(kind: .video, clips: [clip])
            scene.engine.setTimeline(tl)
            scene.engine.loop.cropsTextClips.withLock { $0 = true }
            TextGenerator.clearCache()
            let (fills, draws) = (loop.partialContentFills, loop.partialContentDraws)
            let (cut, cutAhead) = try await shots()
            #expect(cutAhead > 0, "the clip was not shown with cropped frames")
            #expect(loop.partialContentDraws > draws && loop.partialContentFills == fills, "the frames were not read in place")
            scene.engine.loop.cropsTextClips.withLock { $0 = false }
            TextGenerator.clearCache()
            let (whole, wholeAhead) = try await shots()
            scene.engine.loop.cropsTextClips.withLock { $0 = true }
            #expect(wholeAhead == 0, "the whole-box pass drew cropped frames")
            #expect(cut.count == frames.count && whole.count == frames.count)
            var worstOfAll: Float = 0
            for f in frames.sorted() {
                let a = try #require(cut[f]), b = try #require(whole[f])
                #expect(a.count == b.count)
                var worst: Float = 0, lit = false
                for i in a.indices where a[i] != b[i] { worst = max(worst, abs(Float(a[i]) - Float(b[i]))) }
                for i in stride(from: 0, to: a.count, by: 4) where a[i] > 0.9 && a[i + 1] > 0.9 && a[i + 2] > 0.9 { lit = true; break }
                #expect(worst <= tolerance, "frame \(f) aligned \(aligned): cropped and whole differ by \(worst)")
                #expect(lit, "frame \(f) shows no text")
                worstOfAll = max(worstOfAll, worst)
            }
            print("PERF text clip cropped vs whole box, \(aligned ? "on whole pixels" : "scaled and rotated"): max difference \(worstOfAll)")
        }
    }

    /// A text clip with something that reads its whole rectangle (blur, crop, corner radius, blend mode, a mask, less
    /// opacity), scaled and rotated off the pixel grid: the monitor draws the cropped in-between frames as a part of the
    /// whole box (`RenderLayer.contentPart`, read in place), and the picture is bit for bit the one of whole-box frames
    /// (what the export rasters), with no tolerance. The part copied into a whole picture first (the switch off) is
    /// compared too.
    @Test func textClipFramesDrawnAsAPartOfTheirBoxAreTheWholeBoxPicture() async throws {
        TextGenerator.clearCache()
        let device = try #require(MTLCreateSystemDefaultDevice())
        var style = TextStyle(fontName: "Helvetica-Bold", size: 44, color: .white, stroke: TextStroke(color: .black, width: 5),
                              shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.8), offsetX: 5, offsetY: 7, blur: 6))
        style.alignment = .left
        let animator = TextAnimator(effect: .pop, unit: .word, easing: .overshoot, duration: Time(1, 2), stagger: Time(1, 6))
        let ref = try TextGenerator.makeRef(
            template: TextTemplate(name: "t", text: "same picture\neither way", style: style, box: TextBox(width: 560, height: 300)),
            animations: AnimationSet(in: KeyframeTemplate(textAnimator: animator), out: nil))
        let scene = try await CaptionCostScene(kind: .none, width: 640, height: 360, text: ref)
        defer { scene.close() }
        let frames: Set<Int> = [1, 3, 6, 10, 15, 22]
        func effect(_ kind: String, _ values: [String: Double]) throws -> ClipEffect {
            var e = try #require(ClipEffect.make(kind: kind))
            for (k, v) in values { e.parameters[k] = AnimatedProperty(v) }
            return e
        }
        let cases: [(String, (inout Clip) throws -> Void)] = [
            ("blend mode", { $0.blendMode = .screen }),
            ("corner radius", { $0.roundedCorners = .roundedCorners(radius: 60) }),
            ("blur", { $0.effects = [try effect(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 9])] }),
            ("crop", { $0.effects = [try effect(ClipEffect.cropKind, [ClipEffect.cropLeftKey: 12, ClipEffect.cropTopKey: 30])] }),
            ("blur, corner radius and blend mode", {
                $0.effects = [try effect(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 5])]
                $0.roundedCorners = .roundedCorners(radius: 40); $0.blendMode = .overlay
            }),
            ("mask", {
                var m = ClipMask.make(.rectangle, name: "m")
                m.path = AnimatedProperty(MaskPath.rectangle(Vec2(0.02, 0.1), Vec2(0.45, 0.9)))
                $0.masks = [m]
            }),
            ("blend mode and opacity", { $0.blendMode = .multiply; $0.animation.opacity = AnimatedProperty(0.6) }),
        ]
        for (name, change) in cases {
            var tl = scene.timeline
            var clip = tl.tracks[1].clips[0]
            clip.animation.position = AnimatedProperty(Vec2(23.5, -11.25))
            clip.animation.scale = AnimatedProperty(Vec2(1.3, 0.85))
            clip.animation.rotation = AnimatedProperty(19.0)
            clip.animation.anchor = AnimatedProperty(Vec2(14, -6))
            try change(&clip)
            tl.tracks[1] = Track(kind: .video, clips: [clip])
            scene.engine.setTimeline(tl)
            func shots() async throws -> ([Int: [Float16]], CaptionCostScene.Pass) {
                TextGenerator.clearCache()
                var out: [Int: [Float16]] = [:]
                let p = try await scene.pass(drained: true) { f, tex in if frames.contains(f) { out[f] = costPixels(tex, device: device) } }
                return (out, p)
            }
            let loop = scene.engine.loop
            let fills = loop.partialContentFills, draws = loop.partialContentDraws
            // Playback as it is: the part read in place.
            let (cut, cutPass) = try await shots()
            #expect(cutPass.ahead > 0, "\(name): no frame was drawn ahead")
            #expect(loop.partialContentDraws > draws, "\(name): no frame was drawn as a part of its box")
            #expect(loop.partialContentFills == fills, "\(name): playback made a whole picture of a part")
            // The switch off: the part copied into a cleared whole picture.
            let before = loop.partialContentDraws
            loop.setDrawsContentPartsDirectly(false)
            let (filled, _) = try await shots()
            loop.setDrawsContentPartsDirectly(true)
            #expect(loop.partialContentFills > fills && loop.partialContentDraws == before, "\(name): the compare pass made no whole picture")
            loop.cropsTextClips.withLock { $0 = false }
            let between = (loop.partialContentFills, loop.partialContentDraws)
            let (whole, wholePass) = try await shots()
            loop.cropsTextClips.withLock { $0 = true }
            #expect(wholePass.ahead == 0 && (loop.partialContentFills, loop.partialContentDraws) == between,
                    "\(name): the whole-box pass was not one")
            #expect(cut.count == frames.count && whole.count == frames.count && filled.count == frames.count)
            for f in frames.sorted() {
                let a = try #require(cut[f]), b = try #require(whole[f]), c = try #require(filled[f])
                var lit = false
                for i in stride(from: 0, to: a.count, by: 4) where a[i] > 0.5 && a[i + 1] > 0.5 && a[i + 2] > 0.5 { lit = true; break }
                #expect(a == b, "\(name), frame \(f): a part drawn as the whole box differs from the whole-box frame")
                #expect(a == c, "\(name), frame \(f): a part read in place differs from the whole picture made first")
                #expect(lit, "\(name), frame \(f) shows no text")
            }
        }
    }

    /// Captions whose look scales, turns and moves the block while a text animator pops the words in: the monitor draws
    /// the cropped in-between frames as a part of the whole caption raster (`RenderLayer.contentPart`, read in place),
    /// and the picture is bit for bit the one of whole-raster frames (what the export rasters), with no tolerance. The
    /// part copied into a whole picture first (the switch off) is compared too.
    @Test func captionFramesDrawnAsAPartOfTheirRasterAreTheWholeRasterPicture() async throws {
        TextGenerator.clearCache()
        let device = try #require(MTLCreateSystemDefaultDevice())
        var look = CaptionCostKind.customIntro
        look.textAnimator = TextAnimator(effect: .pop, unit: .word, easing: .overshoot, duration: Time(1, 5), stagger: Time(1, 10))
        let scene = try await CaptionCostScene(kind: .custom, width: 1280, height: 720, animation: look)
        defer { scene.close() }
        // In-between frames of four captions, most of them while Scale and Rotation are still on their way.
        let frames: Set<Int> = [1, 2, 4, 7, 10, 16, 19, 33, 47, 62]
        func shots() async throws -> [Int: [Float16]] {
            TextGenerator.clearCache()
            var out: [Int: [Float16]] = [:]
            _ = try await scene.pass(drained: true) { f, tex in if frames.contains(f) { out[f] = costPixels(tex, device: device) } }
            return out
        }
        let loop = scene.engine.loop
        let fills = loop.partialContentFills, draws = loop.partialContentDraws
        // Playback as it is: the part read in place.
        let cut = try await shots()
        #expect(loop.partialContentDraws > draws, "no caption frame was drawn as a part of its raster")
        #expect(loop.partialContentFills == fills, "playback made a whole picture of a part")
        // The switch off: the part copied into a cleared whole picture.
        let before = loop.partialContentDraws
        loop.setDrawsContentPartsDirectly(false)
        let filled = try await shots()
        loop.setDrawsContentPartsDirectly(true)
        #expect(loop.partialContentFills > fills && loop.partialContentDraws == before, "the compare pass made no whole picture")
        // Whole-raster frames: no parts at all.
        loop.cropsTextClips.withLock { $0 = false }
        let between = (loop.partialContentFills, loop.partialContentDraws)
        let whole = try await shots()
        loop.cropsTextClips.withLock { $0 = true }
        #expect((loop.partialContentFills, loop.partialContentDraws) == between, "the whole-raster pass drew a part")
        #expect(cut.count == frames.count && whole.count == frames.count && filled.count == frames.count)
        var worst: Float = 0, differing = 0
        for f in frames.sorted() {
            let a = try #require(cut[f]), b = try #require(whole[f]), c = try #require(filled[f])
            for i in a.indices where a[i] != b[i] { worst = max(worst, abs(Float(a[i]) - Float(b[i]))); differing += 1 }
            #expect(a == b, "frame \(f): a part drawn as the whole raster differs from the whole-raster frame")
            #expect(a == c, "frame \(f): a part read in place differs from the whole picture made first")
        }
        print("PERF caption in-between frames, cropped vs whole raster, look with scale and rotation, \(frames.count) frames: "
            + "\(differing) values differ, max \(worst)")
        // The captions are in the picture at all, and they move: two frames of one caption differ.
        #expect(cut[2] != cut[7])
    }

    /// Captions with a text animator, played backwards: their in-between frames come from the look-ahead too.
    @Test func animatedCaptionsPlayedBackwardsAreDrawnAhead() async throws {
        TextGenerator.clearCache()
        let scene = try await CaptionCostScene(kind: .wordAnimator, width: 1080, height: 1920)
        defer { scene.close() }
        let p = try await scene.pass(drained: true, reverse: true)
        print("PERF captions 1080x1920 wordAnimator, reverse: tick mean \(s(mean(p.tick))) max \(s(p.tick.max() ?? 0)) "
            + "drawn \(p.drawn) waited \(p.waited) ahead \(p.ahead)")
        #expect(p.ahead > 0, "nothing was drawn ahead")
        #expect(p.drawn <= max(2, p.ahead / 8), "the ticks drew \(p.drawn) of \(p.ahead) frames drawn ahead")
    }

    /// Played backwards, the first frame shown of a caption is the last time on the frame grid before its end, which
    /// is later than a frame before the end when the end is off the grid: the word lit there is the one prepared.
    @Test func aCaptionEndingOffTheFrameGridIsPreparedForItsFirstFrameInReverse() async throws {
        TextGenerator.clearCache()
        let scene = try await CaptionCostScene(kind: .karaokePop, width: 540, height: 960)
        defer { scene.close() }
        var tl = scene.timeline
        let track = try #require(tl.captionTracks.first), own = try #require(track.items.first)
        // Ends at frame 30.5; "last" is lit from 29.8 on: at frame 30 (shown first), not at 29.5 (a frame before the end).
        let start = fd * 15, boundary = Time(298, 300), end = Time(305, 300)
        let item = CaptionItem(lines: ["first last"], range: TimeRange(start: start, end: end), styleRef: own.styleRef,
                               animationRef: own.animationRef, words: [
                                   CaptionWord(text: "first", range: TimeRange(start: start, end: boundary)),
                                   CaptionWord(text: "last", range: TimeRange(start: boundary, end: end)),
                               ])
        _ = try tl.replaceCaptions([item], track: track.id)
        #expect(tl.captionTracks.first?.karaoke != nil)
        let engine = scene.engine
        engine.setTimeline(tl)
        engine.pause()
        engine.seek(to: fd * 40)
        for _ in 0..<50 {
            _ = engine.tick()
            await engine.waitForDecodes()
            if let p = engine.lastTickProfile, p.presented, p.missing == 0, p.noFrame == 0 { break }
        }
        TextGenerator.clearCache()
        engine.play(.reverse)
        var atFirstFrame: Int?
        for f in stride(from: 40, through: 30, by: -1) {
            await engine.waitForDecodes()
            if f == 40 { _ = engine.tick() }   // starts the rasters of the caption ahead
            // Static rasters are drawn on a background task: given time, whatever was asked for is there.
            if f > 30 { try await Task.sleep(for: .milliseconds(60)) }
            let before = engine.stats.captionSyncRenders
            _ = engine.tick()
            if f == 30 { atFirstFrame = engine.stats.captionSyncRenders - before }
            scene.clock.advance(by: fd)
        }
        #expect(atFirstFrame == 0, "the caption's first frame in reverse drew \(atFirstFrame ?? -1) rasters on the render thread")
    }

    /// A Look hover preview draws other rasters (they are keyed by what is drawn): the look-ahead draws the previewed
    /// ones, highlight included, and when the preview ends the picture is the one from before, never a frame of the
    /// other Look that was drawn ahead.
    @Test func aLookPreviewIsDrawnAheadAndLeavesNothingBehind() async throws {
        TextGenerator.clearCache()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let frames: Set<Int> = [2, 7, 16, 21, 33]
        func shots(_ scene: CaptionCostScene) async throws -> ([Int: [Float16]], CaptionCostScene.Pass) {
            var out: [Int: [Float16]] = [:]
            let p = try await scene.pass(drained: true) { f, tex in if frames.contains(f) { out[f] = costPixels(tex, device: device) } }
            return (out, p)
        }
        // Captions with an animated look of their own, previewed in another animated look with a highlight.
        let captions = try await CaptionCostScene(kind: .wordAnimator, width: 540, height: 960)
        defer { captions.close() }
        var other = CaptionPresetLibrary.builtIn.style(for: "tiktok")
        other.size *= 0.4; other.color = RGBAColor(red: 1, green: 0.2, blue: 0.1, alpha: 1)
        let preview = LookPreview.captions(style: other, animation: CaptionCostKind.characterAnimator.animation, karaoke: KaraokeStyle())
        // A text clip previewed in another animated look.
        let style = TextStyle(fontName: "Helvetica-Bold", size: 60, color: .white)
        let template = TextTemplate(name: "t", text: "one look or another", style: style, box: TextBox(width: 500, height: 300))
        var otherTemplate = template
        otherTemplate.style.color = RGBAColor(red: 0.1, green: 0.9, blue: 0.3, alpha: 1)
        let own = try TextGenerator.makeRef(template: template, animations: AnimationSet(
            in: KeyframeTemplate(textAnimator: TextAnimator(effect: .pop, unit: .word, duration: Time(1, 2), stagger: Time(1, 6))), out: nil))
        let to = try TextGenerator.makeRef(template: otherTemplate, animations: AnimationSet(
            in: KeyframeTemplate(textAnimator: TextAnimator(effect: .slide, unit: .character, duration: Time(1, 2), stagger: Time(1, 15))), out: nil))
        let text = try await CaptionCostScene(kind: .none, width: 640, height: 360, text: own)
        defer { text.close() }
        let clip = text.timeline.tracks[1].clips[0].id
        for (name, scene, look) in [("captions", captions, preview),
                                    ("text clip", text, LookPreview.text(container: clip, layer: clip, from: own, to: to))] {
            let (before, _) = try await shots(scene)
            scene.engine.setLookPreview(look)
            await scene.settle()   // the previewed static rasters
            let (during, p) = try await shots(scene)
            #expect(p.ahead > 0, "\(name): no previewed frame was drawn ahead")
            #expect(p.drawn <= max(2, p.ahead / 8), "\(name): the ticks drew \(p.drawn) of \(p.ahead) previewed frames drawn ahead")
            scene.engine.setLookPreview(nil)
            await scene.settle()
            let (after, _) = try await shots(scene)   // nothing cleared: whatever was drawn ahead is still cached
            #expect(before.count == frames.count && during.count == frames.count && after.count == frames.count)
            for f in frames.sorted() {
                #expect(before[f] != during[f], "\(name), frame \(f): the preview shows the clip's own look")
                #expect(before[f] == after[f], "\(name), frame \(f): the picture after the preview is not the one before it")
            }
        }
    }

    /// The split of the caption work on the render thread for one frame of a word-animated karaoke caption.
    @Test(arguments: [[1080, 1920], [3840, 2160]])
    func captionWorkSplit(_ size: [Int]) async throws {
        let w = size[0], h = size[1]
        TextGenerator.clearCache()
        let scene = try await CaptionCostScene(kind: .karaokeWordAnimator, width: w, height: h)
        defer { scene.close() }
        let tl = scene.timeline, library = CaptionPresetLibrary.builtIn
        let t = fd * 3
        let item = try #require(tl.captions(at: t).first?.item)
        let karaoke = tl.captionTracks.first?.karaoke
        // Lookup over a long caption track (2000 captions, the playhead near the end).
        var long = tl
        let many = (0..<2000).map { i in
            CaptionItem(lines: ["w\(i)"], range: TimeRange(start: fd * Int64(i * 5), duration: fd * 5))
        }
        _ = try long.replaceCaptions(many)
        let late = fd * 9900
        let lookup = SQTiming.bestPerIterationMs(iterations: 50) { _ = long.captions(at: late) }
        // What playback asks instead: one prepared lookup per timeline change, then per tick the slot with its hand-over
        // for its frame and four frames of look-ahead.
        let prepare = SQTiming.bestPerIterationMs(iterations: 50) { _ = CaptionSlotLookup(long) }
        let prepared = CaptionSlotLookup(long)
        let slots = SQTiming.bestPerIterationMs(iterations: 50) {
            for k in 0..<5 { _ = prepared.slots(at: late + fd * Int64(k)) }
        }
        let plan = SQTiming.bestPerIterationMs(iterations: 50) {
            _ = try? CaptionPreview.plan(for: item, karaoke: karaoke, canvas: tl.format, at: t, library: library)
        }
        let p = try CaptionPreview.plan(for: item, karaoke: karaoke, canvas: tl.format, at: t, library: library)
        let (template, _) = try TextGenerator.decode(p.plain)
        let layout = SQTiming.bestPerIterationMs(iterations: 20) {
            _ = TextLayout.layout(text: template.text, style: template.style, maxWidth: template.box?.width, boxHeight: template.box?.height)
        }
        let raster = SQTiming.bestMs {
            _ = try? TextRenderer.render(text: template.text, style: template.style, maxWidth: template.box?.width,
                                         boxHeight: template.box?.height)
        }
        let still = try #require(try TextRenderer.render(text: template.text, style: template.style, maxWidth: template.box?.width,
                                                         boxHeight: template.box?.height))
        let anims = try #require(CaptionPreview.animations(for: item, library: library))
        let states = try #require(anims.characterStates(units: TextUnits.segment(still.layout), clipTime: t, clipDuration: item.range.duration))
        let animated = SQTiming.bestMs {
            _ = try? TextRenderer.render(text: template.text, style: template.style, maxWidth: template.box?.width,
                                         boxHeight: template.box?.height, characterStates: states)
        }
        _ = try TextGenerator.frame(ref: p.plain, localTime: t, clipDuration: item.range.duration, canvas: tl.format, scale: 1)
        let frame = SQTiming.bestPerIterationMs(iterations: 50) {
            _ = try? TextGenerator.frame(ref: p.plain, localTime: t, clipDuration: item.range.duration, canvas: tl.format, scale: 1)
        }
        let tight = SQTiming.bestMs {
            _ = try? TextRenderer.render(text: template.text, style: template.style, maxWidth: template.box?.width,
                                         boxHeight: template.box?.height, characterStates: states, tight: true)
        }
        print("PERF caption split \(w)x\(h) ms: lookup/2000 \(s(lookup)) prepare/2000 \(s(prepare)) slots/tick \(s(slots)) plan \(s(plan)) cached frame \(s(frame)) layout \(s(layout)) "
            + "static raster \(s(raster)) (\(still.pixelWidth)x\(still.pixelHeight)) animator raster \(s(animated)) tight \(s(tight))")
        // The lookup is a linear scan (about 20 µs in a release build); printed, not bounded. The plan and the cached
        // frame are well under 0.1 ms: bounded only against work that does not belong on a tick at all (a raster).
        #expect(plan < SQTiming.budget(10))
        #expect(frame < SQTiming.budget(10))
    }

    /// Played backwards through a 20-word karaoke caption: the word reached next is the one before, and that is the
    /// one prepared, so after the first frame no tick draws a raster on the render thread.
    @Test func aKaraokeCaptionPlayedBackwardsPreparesTheWordBefore() async throws {
        TextGenerator.clearCache()
        let scene = try await CaptionCostScene(kind: .karaokePop, width: 540, height: 960)
        defer { scene.close() }
        var tl = scene.timeline
        let track = try #require(tl.captionTracks.first), own = try #require(track.items.first)
        // Frames 5 to 85, one word every four frames (word times count from the caption's start).
        let texts = (0..<20).map { "w\($0)" }
        let words = texts.enumerated().map { CaptionWord(text: $1, range: TimeRange(start: fd * Int64($0 * 4), duration: fd * 4)) }
        let lines = stride(from: 0, to: 20, by: 5).map { texts[$0..<$0 + 5].joined(separator: " ") }
        let item = CaptionItem(lines: lines, range: TimeRange(start: fd * 5, duration: fd * 80), styleRef: own.styleRef,
                               animationRef: own.animationRef, words: words)
        _ = try tl.replaceCaptions([item], track: track.id)
        #expect(tl.captionTracks.first?.karaoke != nil)
        let engine = scene.engine
        func run(forward: Bool) async throws -> (sync: Int, lit: Int) {
            engine.setTimeline(tl)
            engine.pause()
            let from = forward ? 5 : 84
            engine.seek(to: fd * Int64(from))
            for _ in 0..<50 {
                _ = engine.tick()
                await engine.waitForDecodes()
                if let p = engine.lastTickProfile, p.presented, p.missing == 0, p.noFrame == 0 { break }
            }
            TextGenerator.clearCache()
            engine.play(forward ? .forward : .reverse)
            let tally = TextGenerator.RasterTally()
            var sync = 0, lit = Set<GeneratorRef>()
            for k in 0..<80 {
                await engine.waitForDecodes()
                let f = forward ? from + k : from - k
                let before = engine.stats.captionSyncRenders
                TextGenerator.$rasterTally.withValue(tally) { _ = engine.tick() }
                // The first frame draws what it shows (cold cache); every later one finds its rasters prepared.
                if k > 0 { sync += engine.stats.captionSyncRenders - before }
                if let l = try CaptionPreview.plan(for: item, karaoke: tl.captionTracks.first?.karaoke, canvas: tl.format,
                                                   at: fd * Int64(f)).lit { lit.insert(l) }
                #expect(await tally.drained(), "frame \(f): the rasters this tick asked for did not end")   // not a sleep
                scene.clock.advance(by: fd)
            }
            engine.pause()
            return (sync, lit.count)
        }
        let back = try await run(forward: false), ahead = try await run(forward: true)
        print("PERF karaoke caption, 20 words: rasters on the render thread after the first frame, reverse \(back.sync), "
            + "forward \(ahead.sync)")
        #expect(back.lit == 20 && ahead.lit == 20, "the pass did not light every word")
        #expect(back.sync == 0, "played backwards, \(back.sync) rasters were drawn on the render thread")
        #expect(ahead.sync == 0, "played forwards, \(ahead.sync) rasters were drawn on the render thread")
    }
}
