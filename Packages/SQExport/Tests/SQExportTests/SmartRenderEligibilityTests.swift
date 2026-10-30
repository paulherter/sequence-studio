import Testing
import Foundation
import SQCore
@testable import SQExport

/// Smart render eligibility (pure): which output frames could be copied from the source without re-encoding.
/// Conservative: anything in doubt is re-encoded.
@Suite struct SmartRenderEligibilityTests {
    static let fd = Time(1, 30)
    static let media = UUID()

    /// 1080x1920 H.264 8-bit 4:2:0 30 fps Rec.709-tagged source, a closed GOP every 30 frames, 10 Mbit/s.
    static func source(gop: Int = 30, frames: Int = 600, codec: String = "avc1", width: Int = 1080, height: Int = 1920,
                       bitDepth: Int = 8, chroma: String = "4:2:0", colorSpace: ColorSpaceID? = .rec709,
                       tagged: Bool = true, closedGOP: Bool = true, bitrate: Int? = 10_000_000, rotation: Int = 0) -> SmartRenderSource {
        let tag: String? = tagged ? "ITU_R_709_2" : nil
        let info = VideoTrackInfo(width: width, height: height, codec: codec, bitDepth: bitDepth, chroma: chroma,
                                  nominalFrameDuration: fd, isVariableFrameRate: false,
                                  colorPrimaries: tag, transfer: tag, matrix: tag, rotation: rotation)
        return SmartRenderSource(info: info, colorSpace: colorSpace,
                                 syncSampleTimes: stride(from: 0, to: frames, by: gop).map { fd * Int64($0) },
                                 closedGOP: closedGOP, averageBitsPerSecond: bitrate)
    }

    static var target: SmartRenderTarget {
        var s = ExportSettings()
        s.video.codec = .h264; s.video.width = 1080; s.video.height = 1920; s.video.frameDuration = fd
        s.video.bitrate = .average(12_000_000)
        return SmartRenderTarget(settings: s)
    }

    /// One clip at timeline 0 showing source frames `from..<from+count`.
    static func clip(from: Int = 10, count: Int = 100, media: UUID = media) -> Clip {
        Clip(name: "c", media: media, kind: .video, source: TimeRange(start: fd * Int64(from), duration: fd * Int64(count)), start: .zero)
    }

    static func timeline(_ clips: [Clip]...) -> Timeline {
        Timeline(name: "t", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd),
                 tracks: clips.map { Track(kind: .video, clips: $0) })
    }

    static func plan(_ tl: Timeline, sources: [UUID: SmartRenderSource] = [media: source()],
                     target: SmartRenderTarget = target, minimum: Int = 30) -> SmartRenderPlan {
        SmartRender.plan(timeline: tl, sources: sources, target: target, minimumPassthroughFrames: minimum)
    }

    /// Deinterlaced media is exported as the progressive picture: its stored (woven) samples cannot be copied. With
    /// Deinterlace off the stored frames are what the export shows.
    @Test func deinterlacedMediaIsReencoded() {
        var fields = Self.source()
        fields.info.fieldOrder = .topFirst
        #expect(Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: fields]).reasons[.sourceFormat] == 100)
        fields.info.deinterlaceOff = true
        #expect(Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: fields]).reasons[.sourceFormat] == nil)
    }

    /// F7.3: non-square pixels are desqueezed by the compositor, so the stored frames cannot be copied.
    @Test func nonSquarePixelsAreReencoded() {
        var tagged = Self.source()
        tagged.info.pixelAspect = PixelAspect(4, 3)!
        #expect(Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: tagged]).reasons[.sourceFormat] == 100)
        var chosen = Self.source()
        chosen.info.pixelAspectOverride = PixelAspect(2, 1)
        #expect(Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: chosen]).reasons[.sourceFormat] == 100)
    }

    @Test func plainMatchingClipPassesThroughWholeGOPsOnly() {
        let p = Self.plan(Self.timeline([Self.clip()]))
        #expect(p.totalFrames == 100)
        #expect(p.eligibleFrames == 100)
        #expect(p.runs.map(\.frames) == [0..<100])
        // Source 10..<110, sync samples every 30: whole GOPs 30..<60, 60..<90 -> output 20..<80.
        #expect(p.passthrough.map(\.frames) == [20..<80])
        #expect(p.passthrough.first?.sourceStart == Self.fd * 30)
        #expect(p.passthroughFrames == 60)
        #expect(p.reasons.isEmpty)
    }

    @Test func scaledClipIsReencoded() {
        var c = Self.clip()
        c.animation.scale = AnimatedProperty(Vec2(1.2, 1.2))
        let p = Self.plan(Self.timeline([c]))
        #expect(p.eligibleFrames == 0)
        #expect(p.reasons[.transform] == 100)
    }

    @Test func typicalCameraSourceDoesNotMatchTheSocialTarget() {
        // Sony 4K XAVC: 3840x2160 rotated, 10-bit 4:2:2, no color tags.
        let sony = Self.source(width: 3840, height: 2160, bitDepth: 10, chroma: "4:2:2", tagged: false, bitrate: 140_000_000, rotation: 90)
        let p = Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: sony])
        #expect(p.eligibleFrames == 0)
        #expect(p.reasons[.sourceFormat] == 100)
    }

    @Test func codecMismatchIsReencoded() {
        let p = Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: Self.source(codec: "hvc1")])
        #expect(p.eligibleFrames == 0)
        #expect(p.reasons[.sourceFormat] == 100)
    }

    @Test func twoVisibleLayersAreReencoded() {
        let other = UUID()
        let p = Self.plan(Self.timeline([Self.clip()], [Self.clip(media: other)]),
                          sources: [Self.media: Self.source(), other: Self.source()])
        #expect(p.eligibleFrames == 0)
        #expect(p.reasons[.composite] == 100)
    }

    @Test func gapsAreReencoded() {
        var c = Self.clip(count: 60)
        c.start = Self.fd * 40
        let p = Self.plan(Self.timeline([c]))
        #expect(p.totalFrames == 100)
        #expect(p.reasons[.gap] == 40)
        #expect(p.eligibleFrames == 60)
    }

    @Test func retimedClipIsReencoded() {
        var c = Self.clip()
        c.speed = ClipSpeed(num: 2, den: 1)
        let p = Self.plan(Self.timeline([c]))
        #expect(p.eligibleFrames == 0)
        #expect(p.reasons[.retimed] == p.totalFrames)
    }

    @Test func clipWithAnyEffectIsReencoded() {
        var c = Self.clip()
        c.effects = [ClipEffect(kind: "gaussianBlur")]
        let p = Self.plan(Self.timeline([c]))
        #expect(p.eligibleFrames == 0)
        #expect(p.reasons[.effects] == 100)
    }

    @Test func gradedLayerIsReencoded() {
        let c = Self.clip()
        var color = ClipColor.default
        color.effects[0].basic.exposure = 1
        let p = SmartRender.plan(frameCount: 100, startTime: .zero, frameDuration: Self.fd,
                                 layers: { t in [LayerRequest(clip: c.id, media: Self.media, track: UUID(),
                                                              sourceTime: c.source.start + t, color: color)] },
                                 clips: [c.id: c], sources: [Self.media: Self.source()], target: Self.target,
                                 minimumPassthroughFrames: 30)
        #expect(p.eligibleFrames == 0)
        #expect(p.reasons[.color] == 100)
    }

    @Test func transitionFramesAreReencodedTheRestStays() {
        let c = Self.clip()
        let p = SmartRender.plan(frameCount: 100, startTime: .zero, frameDuration: Self.fd,
                                 layers: { t in
                                     var l = LayerRequest(clip: c.id, media: Self.media, track: UUID(), sourceTime: c.source.start + t)
                                     l.inTransition = t >= Self.fd * 90
                                     return [l]
                                 },
                                 clips: [c.id: c], sources: [Self.media: Self.source()], target: Self.target,
                                 minimumPassthroughFrames: 30)
        #expect(p.reasons[.transition] == 10)
        #expect(p.eligibleFrames == 90)
        #expect(p.passthrough.map(\.frames) == [20..<80])
    }

    @Test func burnedInCaptionsAreReencoded() {
        let p = SmartRender.plan(timeline: Self.timeline([Self.clip()]), sources: [Self.media: Self.source()], target: Self.target,
                                 burnIn: { $0 < Self.fd * 50 }, minimumPassthroughFrames: 30)
        #expect(p.reasons[.captions] == 50)
        #expect(p.eligibleFrames == 50)
        // Output 50..<100 = source 60..<110: one whole GOP 60..<90 -> output 50..<80.
        #expect(p.passthrough.map(\.frames) == [50..<80])
    }

    @Test func openGOPSourceIsNeverPassedThrough() {
        let p = Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: Self.source(closedGOP: false)])
        #expect(p.eligibleFrames == 100)
        #expect(p.passthroughFrames == 0)
    }

    @Test func shortRunsAreNotWorthASeam() {
        let p = Self.plan(Self.timeline([Self.clip()]), minimum: 90)
        #expect(p.eligibleFrames == 100)
        #expect(p.passthrough.isEmpty)
    }

    @Test func untaggedOrLogSourceIsReencoded() {
        let untagged = Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: Self.source(tagged: false)])
        #expect(untagged.reasons[.sourceColor] == 100)
        let undetected = Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: Self.source(colorSpace: nil)])
        #expect(undetected.reasons[.sourceColor] == 100)
        let log = Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: Self.source(colorSpace: .sLog3SGamut3Cine)])
        #expect(log.reasons[.sourceColor] == 100)
    }

    @Test func sourceAboveTheTargetBitrateIsReencoded() {
        let p = Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: Self.source(bitrate: 50_000_000)])
        #expect(p.reasons[.bitrate] == 100)
        let unknown = Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: Self.source(bitrate: nil)])
        #expect(unknown.reasons[.bitrate] == 100)
    }

    @Test func unknownMediaIsReencoded() {
        let p = Self.plan(Self.timeline([Self.clip()]), sources: [:])
        #expect(p.reasons[.unknownSource] == 100)
    }

    @Test func offGridSourceTimeIsReencoded() {
        var c = Self.clip()
        c.source.start = Self.fd * 10 + Time(1, 1000)
        let p = Self.plan(Self.timeline([c]))
        #expect(p.eligibleFrames == 0)
        #expect(p.reasons[.frameGrid] == 100)
    }

    @Test func cutBetweenTwoClipsOfOneMediaSplitsRuns() {
        // Two clips back to back from one file, the second jumps ahead in the source: two runs, never one.
        var a = Self.clip(from: 0, count: 60)
        var b = Self.clip(from: 300, count: 90)
        a.start = .zero; b.start = Self.fd * 60
        let p = Self.plan(Self.timeline([a, b]))
        #expect(p.runs.map(\.frames) == [0..<60, 60..<150])
        // a: source 0..<60 -> GOPs 0..<30, 30..<60 = output 0..<60. b: source 300..<390 -> output 60..<150.
        #expect(p.passthrough.map(\.frames) == [0..<60, 60..<150])
    }

    @Test func proResTargetMatchesProResSourceFrameByFrame() {
        var s = ExportSettings()
        s.video.codec = .prores422; s.video.width = 1080; s.video.height = 1920; s.video.frameDuration = Self.fd
        let src = Self.source(gop: 1, codec: "apcn", bitDepth: 10, chroma: "4:2:2", bitrate: 120_000_000)
        let p = Self.plan(Self.timeline([Self.clip()]), sources: [Self.media: src], target: SmartRenderTarget(settings: s))
        #expect(p.passthrough.map(\.frames) == [0..<100])
    }
}
