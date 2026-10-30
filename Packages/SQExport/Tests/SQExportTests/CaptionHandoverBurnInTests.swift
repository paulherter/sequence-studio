import Foundation
import Metal
import Testing
import SQCore
import SQText
import SQTranscribe
@testable import SQExport

/// Maintainer bug 2026-10-08: no blank frame between two captions that touch (or sit up to two frames apart), in the
/// export burn-in exactly as in the Program monitor (`CaptionHandover`, the one rule both use).
@Suite struct CaptionHandoverBurnInTests {
    static let fd = Time(1, 30)
    let w = 540, h = 960

    static let animators: [(id: String, animator: TextAnimator)] = [
        ("handover-fade", TextAnimator(effect: .fade, unit: .word, duration: Time(3, 10), stagger: Time(1, 10))),
        ("handover-pop", TextAnimator(effect: .pop, unit: .word, easing: .overshoot, duration: Time(3, 10), stagger: Time(1, 10))),
        ("handover-slide", TextAnimator(effect: .slide, unit: .character, duration: Time(1, 5), stagger: Time(1, 30))),
        ("handover-blur", TextAnimator(effect: .blur, unit: .line, duration: Time(1, 5), stagger: Time(1, 10))),
        ("handover-typewriter", TextAnimator(effect: .typewriter, unit: .character, duration: .zero, stagger: Time(1, 30))),
    ]

    /// The built-in library plus one look per text-animator effect, and the animation ids to test.
    static func library() -> (CaptionPresetLibrary, [String]) {
        var lib = CaptionPresetLibrary.builtIn
        var ids = lib.animationIDs.filter { !$0.hasPrefix("look-") }
        for a in animators {
            lib = lib.adding(CaptionLook(style: lib.style(for: "tiktok"), animation: KeyframeTemplate(textAnimator: a.animator)), id: a.id)
            ids.append(CaptionLook.animationID(for: a.id))
        }
        return (lib, ids)
    }

    /// Caption A on frames 3..<15, caption B 12 frames long starting `gap` frames after A ends.
    static func timeline(animation: String, gap: Int64, karaoke: Bool) throws -> Timeline {
        var tl = Timeline(name: "s", format: SequenceFormat(width: 540, height: 960, frameDuration: fd), tracks: [])
        let a = TimeRange(start: fd * 3, end: fd * 15), b = TimeRange(start: fd * (15 + gap), end: fd * (27 + gap))
        let track = try tl.replaceCaptions([
            CaptionItem(lines: ["alpha beta"], range: a, styleRef: "tiktok", animationRef: animation),
            CaptionItem(lines: ["gamma delta"], range: b, styleRef: "tiktok", animationRef: animation),
        ])
        if karaoke { try tl.setCaptionKaraoke(KaraokeStyle(), track: track) }
        return tl
    }

    /// Opacity of the entering (last) caption's state at `frame`; 0 when nothing is drawn.
    static func burnInOpacity(_ tl: Timeline, _ lib: CaptionPresetLibrary, frame: Int, w: Int, h: Int) -> Double {
        guard let burn = try? burnIn(tl, lib) else { return -1 }
        return burn.states(at: fd * Int64(frame), canvasWidth: w, canvasHeight: h).last?.opacity ?? 0
    }

    static func burnIn(_ tl: Timeline, _ lib: CaptionPresetLibrary) throws -> CaptionBurnIn {
        var s = ExportSettings(); s.captions = .burnIn
        return try #require(ExportSourceBuilder.burnIn(for: tl, settings: s, library: lib))
    }

    /// Summed alpha of what the burn-in draws on frame `f` (the call the export frame source makes per frame).
    func coverage(_ burn: CaptionBurnIn, frame f: Int, device: MTLDevice, queue: MTLCommandQueue) throws -> Double {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let tex = try #require(device.makeTexture(descriptor: d))
        let cb = try #require(queue.makeCommandBuffer())
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = tex; clear.colorAttachments[0].loadAction = .clear
        clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        cb.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
        try burn.encode(at: Self.fd * Int64(f), into: tex, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var sum = 0.0
        for i in stride(from: 3, to: px.count, by: 8) { sum += Double(px[i]) }
        return sum
    }

    @Test func touchingCaptionsBurnInACaptionOnEveryFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let (lib, ids) = Self.library()
        #expect(ids.count >= 15)
        for gap in [Int64(0), 1, 2] {
            for (animation, karaoke) in ids.map({ ($0, false) }) + [("fade", true), ("pop", true), (ids[ids.count - 2], true)] {
                let burn = try Self.burnIn(try Self.timeline(animation: animation, gap: gap, karaoke: karaoke), lib)
                let last = 27 + Int(gap)
                let sums = try (0..<(last + 2)).map { try coverage(burn, frame: $0, device: device, queue: queue) }
                let rest = try #require(sums.max())
                #expect(rest > 100, "\(animation): nothing drawn at all")
                for f in 4..<last {
                    #expect(sums[f] > rest * 0.01, "\(animation) gap \(gap) karaoke \(karaoke): no caption on frame \(f)")
                }
                #expect(sums[2] == 0 && sums[last] == 0 && sums[last + 1] == 0, "\(animation): caption outside its time")
            }
        }
    }

    /// The rule in numbers: a fading neighbor cross-fades (the two opacities add up to one), a neighbor that starts at
    /// scale zero keeps the old caption for that frame only, an out look and a caption at rest need no tail, and three
    /// frames apart nothing is handed over.
    @Test func handoverStates() throws {
        let (lib, _) = Self.library()
        func states(_ animation: String, gap: Int64, frame: Int64) throws -> [CaptionDrawState] {
            try Self.burnIn(try Self.timeline(animation: animation, gap: gap, karaoke: false), lib)
                .states(at: Self.fd * frame, canvasWidth: w, canvasHeight: h)
        }
        // Fade: B's first frame is at opacity 0, A stays at 1 under it; then they cross.
        var s = try states("fade", gap: 0, frame: 15)
        #expect(s.map(\.index) == [0, 1] && s[0].opacity == 1 && s[1].opacity == 0)
        s = try states("fade", gap: 0, frame: 18)
        #expect(s.map(\.index) == [0, 1] && abs(s[0].opacity + s[1].opacity - 1) < 1e-9 && abs(s[1].opacity - 0.5) < 1e-9)
        #expect(try states("fade", gap: 0, frame: 21).map(\.index) == [1])
        // The first caption of the run and a caption three frames away keep their whole fade-in.
        #expect(try states("fade", gap: 0, frame: 3).map(\.opacity) == [0])
        #expect(try states("fade", gap: 3, frame: 18).map(\.opacity) == [0])
        #expect(try states("fade", gap: 3, frame: 16).isEmpty)
        // Pop (scale from zero): the old caption holds for the one frame the new one has no size.
        s = try states("pop", gap: 0, frame: 15)
        #expect(s.map(\.index) == [0, 1] && s[0].opacity == 1 && s[0].scale == 1 && s[1].scale == 0)
        #expect(try states("pop", gap: 0, frame: 16).map(\.index) == [1])
        // A small gap: the first caption holds through it, and its out look ends where the next caption starts.
        s = try states("fade", gap: 2, frame: 16)
        #expect(s.map(\.index) == [0] && s[0].opacity == 1)
        s = try states("fade-out", gap: 2, frame: 16)
        #expect(s.map(\.index) == [0] && s[0].opacity > 0 && s[0].opacity < 0.2)
        #expect(try states("fade-out", gap: 2, frame: 17).map(\.index) == [1])
        // Captions at rest on their first frame (out looks, the caption pop, loops) need no tail.
        for id in ["fade-out", "shrink-out", "slide-out", CaptionLook.popAnimationID, "wave", "none"] {
            #expect(try states(id, gap: 0, frame: 15).map(\.index) == [1], "\(id)")
        }
        // A word animator: the old caption holds while no word of the new one shows, then it is gone at once.
        let pop = CaptionLook.animationID(for: "handover-pop")
        #expect(try states(pop, gap: 0, frame: 15).map(\.index) == [0, 1])
        #expect(try states(pop, gap: 0, frame: 16).map(\.index) == [1])
    }

    /// The monitor's request for a frame (`Timeline.captionSlots` plus `CaptionHandover.draw`, what the render loop asks
    /// for) against the burn-in's states: same layers, same opacities, on the grid and off it, for every built-in look,
    /// every text-animator look and out-look-into-in-look pairs.
    @Test func burnInAsksWhatTheMonitorAsks() throws {
        let (lib, ids) = Self.library()
        let fd = Self.fd
        func set(_ ref: String) -> AnimationSet? { AnimationSet(single: lib.animation(for: ref)) }
        var checked = 0
        let pairs = ids.map { ($0, $0) } + ids.flatMap { out in ["fade", "pop"].map { (out, $0) } }
        for gap in [Int64(0), 1, 2] {
            for (first, second) in pairs {
                var tl = Timeline(name: "s", format: SequenceFormat(width: 540, height: 960, frameDuration: fd), tracks: [])
                _ = try tl.replaceCaptions([
                    CaptionItem(lines: ["alpha beta"], range: TimeRange(start: fd * 3, end: fd * 15), styleRef: "tiktok", animationRef: first),
                    CaptionItem(lines: ["gamma delta"], range: TimeRange(start: fd * (15 + gap), end: fd * (27 + gap)),
                                styleRef: "tiktok", animationRef: second),
                ])
                let burn = try Self.burnIn(tl, lib)
                for step in 0..<(30 + Int(gap) * 3) {
                    for off in [Time.zero, Time(1, 90)] {
                        let t = fd * Int64(step) + off
                        var expected: [Double] = []
                        for slot in tl.captionSlots(at: t) {
                            let entering = set(slot.item.animationRef)
                            var local = t - slot.item.range.start
                            if let tail = slot.tail {
                                let prev = set(tail.animationRef)
                                let d = CaptionHandover.draw(previous: prev, entering: entering, naturalClipTime: local,
                                                             frameDuration: fd) { nil }
                                local = d.clipTime
                                if d.tailOpacity > 0 {
                                    let rest = prev?.sample(clipTime: slot.tailDuration, clipDuration: slot.tailDuration).opacity ?? 1
                                    expected.append(rest * d.tailOpacity)
                                }
                            }
                            expected.append(entering?.sample(clipTime: local, clipDuration: slot.duration).opacity ?? 1)
                        }
                        let got = burn.states(at: t).map(\.opacity)
                        #expect(got.count == expected.count, "\(first) -> \(second) gap \(gap) at \(t): layers \(got) vs \(expected)")
                        for (g, e) in zip(got, expected) {
                            #expect(abs(g - e) < 1e-9, "\(first) -> \(second) gap \(gap) at \(t): \(g) vs \(e)")
                        }
                        checked += 1
                    }
                }
            }
        }
        #expect(checked > 1000)
    }

    /// An out look on the caption before and a fade-in from zero on the next, gapless: every frame across the cut draws
    /// a caption with opacity above zero (the next caption's first frame is evaluated one frame into its in look).
    @Test func outLookIntoFadeInNeverShowsAnEmptyFrame() throws {
        var lib = CaptionPresetLibrary.builtIn
        func template(_ keys: [(time: Time, value: Double, shape: SegmentShape)]) -> KeyframeTemplate {
            KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: keys)], duration: Time(1, 5))
        }
        var out = template([(.zero, 1, .linear), (Time(1, 5), 0, .linear)]); out.anchor = .end
        let fadeIn = template([(.zero, 0, .linear), (Time(1, 5), 1, .linear)])
        lib = lib.adding(CaptionLook(style: lib.style(for: "tiktok"), animation: out), id: "hand-out")
        lib = lib.adding(CaptionLook(style: lib.style(for: "tiktok"), animation: fadeIn), id: "hand-in")
        let fd = Self.fd
        var tl = Timeline(name: "s", format: SequenceFormat(width: 540, height: 960, frameDuration: fd), tracks: [])
        _ = try tl.replaceCaptions([
            CaptionItem(lines: ["alpha beta"], range: TimeRange(start: fd * 3, end: fd * 15), styleRef: "tiktok",
                        animationRef: CaptionLook.animationID(for: "hand-out")),
            CaptionItem(lines: ["gamma delta"], range: TimeRange(start: fd * 15, end: fd * 27), styleRef: "tiktok",
                        animationRef: CaptionLook.animationID(for: "hand-in")),
        ])
        let burn = try Self.burnIn(tl, lib)
        for f in 3..<27 {
            let s = burn.states(at: fd * Int64(f), canvasWidth: w, canvasHeight: h)
            #expect((s.map(\.opacity).max() ?? 0) > 0, "empty picture on frame \(f)")
        }
        // The cut frame shows the next caption one frame into its fade.
        let cut = burn.states(at: fd * 15, canvasWidth: w, canvasHeight: h)
        #expect(cut.map(\.index) == [1])
        #expect(abs(cut[0].opacity - 1.0 / 6.0) < 1e-6)
    }

    /// An in look that is still zero one frame in (it waits two frames): the cut frame steps to the first frame that
    /// draws (frame three of the look), so the picture across the cut is never empty. Three frames of waiting is the
    /// cap: that cut keeps the one-frame shift.
    @Test func delayedInLookStepsToTheFirstVisibleFrame() throws {
        let fd = Self.fd
        func look(delayFrames: Int64) -> KeyframeTemplate {
            let delay = fd * delayFrames
            return KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [
                (.zero, 0, .linear), (delay, 0, .linear), (delay + Time(1, 5), 1, .linear)])], duration: delay + Time(1, 5))
        }
        var out = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (Time(1, 5), 0, .linear)])],
                                   duration: Time(1, 5))
        out.anchor = .end
        for (delay, expectedFrames) in [(Int64(2), Int64(3)), (3, 1)] {
            var lib = CaptionPresetLibrary.builtIn
            lib = lib.adding(CaptionLook(style: lib.style(for: "tiktok"), animation: out), id: "hand-out")
            lib = lib.adding(CaptionLook(style: lib.style(for: "tiktok"), animation: look(delayFrames: delay)), id: "hand-late")
            var tl = Timeline(name: "s", format: SequenceFormat(width: 540, height: 960, frameDuration: fd), tracks: [])
            _ = try tl.replaceCaptions([
                CaptionItem(lines: ["alpha beta"], range: TimeRange(start: fd * 3, end: fd * 15), styleRef: "tiktok",
                            animationRef: CaptionLook.animationID(for: "hand-out")),
                CaptionItem(lines: ["gamma delta"], range: TimeRange(start: fd * 15, end: fd * 27), styleRef: "tiktok",
                            animationRef: CaptionLook.animationID(for: "hand-late")),
            ])
            let cut = try Self.burnIn(tl, lib).states(at: fd * 15, canvasWidth: w, canvasHeight: h)
            #expect(cut.map(\.index) == [1])
            // Linear ramp over 1/5 s after the delay, sampled `expectedFrames` frames in.
            let expected = max(0, Double(expectedFrames - delay) / 30 / 0.2)
            #expect(abs(cut[0].opacity - expected) < 1e-6, "delay \(delay): opacity \(cut[0].opacity), expected \(expected)")
            if delay == 2 {
                // Frames 0 to 2 of the in look are held at its first visible frame, so the sequence never flashes.
                let seq = (15...20).map { f in
                    Self.burnInOpacity(tl, lib, frame: f, w: w, h: h)
                }
                let sixth = 1.0 / 6.0
                for (got, want) in zip(seq, [sixth, sixth, sixth, sixth, 2 * sixth, 3 * sixth]) {
                    #expect(abs(got - want) < 1e-6, "opacity sequence \(seq)")
                }
            }
        }
    }
}
