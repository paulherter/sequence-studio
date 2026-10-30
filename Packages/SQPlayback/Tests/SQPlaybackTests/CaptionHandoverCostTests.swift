import Foundation
import Metal
import Testing
import SQCore
import SQText
@testable import SQPlayback

private let fd = Time(1, 30)
private func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
private func p95(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.95))] }
private func s(_ v: Double) -> String { String(format: "%.2f", v) }

/// Two gapless captions: the first ends in an out Look (built-in "fade-out"), the second comes in with a word-animator
/// fade, so the frame at the cut is evaluated one frame into the in Look (`CaptionHandover.enteringClipTime`).
@MainActor private struct HandoverCostScene {
    let engine: PlaybackEngine
    let clock: ManualClock
    let lookID: String
    /// First frame of the second caption.
    static let cut = 15
    static let frames = 30

    init(lookID: String) throws {
        self.lookID = lookID
        let device = try #require(MTLCreateSystemDefaultDevice())
        clock = ManualClock()
        engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: clock)
        let style = TextStyle(fontName: "Helvetica-Bold", size: 20, color: .white)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "i", style: style), animations: nil)
        let id = UUID()
        var clip = Clip(id: id, name: "Text", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                        start: .zero, generator: ref)
        clip.animation.position = AnimatedProperty(Vec2(5000, 5000))   // far off canvas: only gives the sequence its length
        var tl = Timeline(name: "s", format: SequenceFormat(width: 540, height: 960, frameDuration: fd), tracks: [Track(kind: .video, clips: [clip])])
        let animator = TextAnimator(effect: .fade, unit: .word, duration: Time(3, 10), stagger: Time(1, 10))
        let refs = CaptionLookRegistry.shared.register(
            CaptionLook(style: CaptionPresetLibrary.builtIn.style(for: "tiktok"), animation: KeyframeTemplate(textAnimator: animator)), id: lookID)
        _ = try tl.replaceCaptions([
            CaptionItem(lines: ["alpha beta"], range: TimeRange(start: fd * 3, end: fd * Int64(Self.cut)), styleRef: "tiktok", animationRef: "fade-out"),
            CaptionItem(lines: ["gamma delta"], range: TimeRange(start: fd * Int64(Self.cut), end: fd * 27), styleRef: "tiktok",
                        animationRef: refs.animationRef),
        ])
        engine.setTimeline(tl)
    }

    func close() { CaptionLookRegistry.shared.unregister(id: lookID) }

    struct Frame { var ms = 0.0, drawn = 0, waited = 0, syncRenders = 0, ahead = 0 }

    /// One pass in playback order, a tick per frame; the text lane is drained before every tick, as in `CaptionCostScene`.
    func pass() async throws -> [Frame] {
        engine.pause()
        engine.seek(to: .zero)
        _ = engine.tick()
        engine.play()
        var out: [Frame] = []
        let wall = ContinuousClock()
        for _ in 0..<Self.frames {
            // Static rasters are drawn on a background task: given time, whatever was asked for is there.
            try await Task.sleep(for: .milliseconds(30))
            drainTextLane()
            let tally = TextGenerator.RasterTally()
            let before = engine.stats.captionSyncRenders
            var f = Frame()
            f.ms = SQTiming.ms(wall.measure { _ = TextGenerator.$rasterTally.withValue(tally) { engine.tick() } })
            f.ahead = tally.ahead; f.drawn = tally.drawn; f.waited = tally.waited; f.syncRenders = engine.stats.captionSyncRenders - before
            out.append(f)
            clock.advance(by: fd)
        }
        return out
    }
}

@Suite(.serialized) @MainActor struct CaptionHandoverCostTests {
    /// The tick that draws the hand-over frame (a second evaluation of the entering caption plus the tail) against the
    /// ticks of the other caption frames. Printed; the bounds are loose.
    @Test func aHandoverFrameCostsLikeANormalCaptionFrame() async throws {
        TextGenerator.clearCache()
        let scene = try HandoverCostScene(lookID: "handover-cost-a")
        defer { scene.close() }
        for name in ["cold", "warm"] {
            let frames = try await scene.pass()
            let cut = frames[HandoverCostScene.cut]
            let normal = (4..<26).filter { $0 != HandoverCostScene.cut }.map { frames[$0].ms }
            print("PERF caption hand-over 540x960 \(name): cut tick \(s(cut.ms)) vs normal mean \(s(mean(normal))) p95 \(s(p95(normal))) "
                + "max \(s(normal.max() ?? 0)) | cut drawn \(cut.drawn) waited \(cut.waited) sync \(cut.syncRenders)")
            #expect(cut.ms < mean(normal) + SQTiming.budget(8), "\(name): cut tick \(cut.ms) ms vs \(mean(normal)) ms")
        }
    }

    /// Why `theFirstHandoverFrameIsACacheHit` passes even without the look-ahead's shifted-time request: a shifted or
    /// held frame is the natural time of a frame at most `maxEnteringShiftFrames` ahead, and the look-ahead reaches
    /// `animatedTextLookAhead` frames, so the natural request already warms it. The shifted request becomes load-bearing
    /// only if the cap ever grows past the look-ahead; this pins that relation so the day it flips, the cost test above
    /// has to be made to discriminate.
    @Test func theShiftCapStaysInsideTheLookAhead() {
        #expect(CaptionHandover.maxEnteringShiftFrames < Int64(RenderLoop.animatedTextLookAhead))
    }

    /// After the look-ahead the first hand-over frame is a cache hit: no raster is drawn or waited for on the render
    /// thread, and no static raster is made there. The look-ahead has to ask for the shifted time, with the units the
    /// render path uses, to warm that frame.
    @Test func theFirstHandoverFrameIsACacheHit() async throws {
        TextGenerator.clearCache()
        let scene = try HandoverCostScene(lookID: "handover-cost-b")
        defer { scene.close() }
        let before = TextGenerator.animatedRasterStats.backgroundDrawn
        let cold = try await scene.pass()
        drainTextLane()
        let drawnAhead = TextGenerator.animatedRasterStats.backgroundDrawn - before
        let cut = cold[HandoverCostScene.cut]
        #expect(cut.drawn == 0 && cut.waited == 0, "the cut tick drew \(cut.drawn) and waited for \(cut.waited) in-between frames")
        #expect(cut.syncRenders == 0, "the cut tick rastered \(cut.syncRenders) static rasters on the render thread")
        print("PERF caption hand-over in-between frames drawn ahead over the pass: \(drawnAhead)")
    }
}

/// Waits until the text lane has nothing in flight (process-wide; this suite reads process-wide statistics).
private func drainTextLane() {
    let deadline = ContinuousClock.now + .seconds(20)
    while TextGenerator.animatedWarmsInFlight > 0, ContinuousClock.now < deadline { usleep(200) }
}
