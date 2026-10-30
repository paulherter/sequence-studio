import Testing
import Foundation
import Metal
import simd
import SQCore
import SQMedia
import SQMediaTestSupport
import SQRender
@testable import SQPlayback

private let fd = Time(1, 30)
private let format = SequenceFormat(width: 320, height: 180, frameDuration: fd)

/// Wraps a static resolver and adds a `LayerColorResolver` (what `ProjectMediaResolver` does in the app).
private struct ColorResolver: MediaResolver {
    let base: StaticMediaResolver
    let colorResolver: LayerColorResolver?
    func demuxer(for media: UUID) throws -> any Demuxing { try base.demuxer(for: media) }
    func audio(for media: UUID) throws -> any AudioSource { try base.audio(for: media) }
}

/// One generated clip for all tests here: separate encodes are not bit-identical, which made the comparisons flaky.
private actor SharedColorClip {
    static let shared = SharedColorClip()
    private var url: URL?
    func get() async throws -> URL {
        if let url { return url }
        var spec = TestClipSpec()
        spec.frameCount = 20
        spec.frameDuration = TestClipSpec.fps(30)
        let u = try await TestClipWriter.write(spec)
        url = u
        return u
    }
}

/// Mean RGB of an rgba16Float texture.
private func meanRGB(_ texture: MTLTexture, device: MTLDevice) -> SIMD3<Double>? {
    let w = texture.width, h = texture.height, bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let px = buf.contents().assumingMemoryBound(to: Float16.self)
    var s = SIMD3<Double>(repeating: 0)
    for i in 0..<(w * h) { s += SIMD3(Double(px[i * 4]), Double(px[i * 4 + 1]), Double(px[i * 4 + 2])) }
    return s / Double(w * h)
}

@Suite(.serialized) @MainActor struct ColorPipelineEngineTests {
    /// Renders frame 10 of a generated clip whose media is tagged `space`, with `clipColor` on the clip.
    func render(space: ColorSpaceID, clipColor: ClipColor = .default, withResolver: Bool = true) async throws -> SIMD3<Double> {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await SharedColorClip.shared.get()
        let media = UUID()
        let info = MediaInfo(duration: fd * 20, detectedColorSpace: space)
        let resolver = withResolver ? LayerColorResolver(lutProvider: nil) { $0 == media ? info : nil } : nil
        let res = ColorResolver(base: StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)]), colorResolver: resolver)
        let engine = try PlaybackEngine(device: device, media: res, clock: ManualClock())
        var clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 20),
                        start: .zero, mediaDuration: fd * 20)
        clip.color = clipColor
        engine.setTimeline(Timeline(name: "Seq", format: format, tracks: [Track(kind: .video, clips: [clip])]))
        engine.seek(to: fd * 10)
        _ = engine.tick()
        await engine.waitForDecodes()
        #expect(engine.tick())
        let tex = try #require(engine.lastRenderedTexture)
        return try #require(meanRGB(tex, device: device))
    }

    @Test func slog3LayerDiffersFromRec709() async throws {
        let rec709 = try await render(space: .rec709)
        let slog = try await render(space: .sLog3SGamut3Cine)
        #expect(simd_length(rec709 - slog) > 0.01, "S-Log3 pipeline must change the picture: \(rec709) vs \(slog)")
    }

    @Test func rec709IdentityMatchesNoResolver() async throws {
        let plain = try await render(space: .rec709, withResolver: false)
        let withResolver = try await render(space: .rec709)
        #expect(simd_length(plain - withResolver) < 1e-6)
    }

    @Test func sourceOverrideChangesRec709Media() async throws {
        var c = ClipColor.default
        c.source = .sLog3SGamut3Cine
        let plain = try await render(space: .rec709)
        let overridden = try await render(space: .rec709, clipColor: c)
        #expect(simd_length(plain - overridden) > 0.01)
    }
}

/// Review finding (W5.2): the warm-up must see every LUT a keyframed grade uses, not only the one at the clip's start.
@Test func colorWarmUpCoversKeyedSectionToggles() throws {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
    var g = ClipColor.default
    g.effects[0].creative.look = .file("/look.cube"); g.effects[0].creative.intensity = 50
    c.color = g
    guard let i = c.effects.firstIndex(where: { $0.isColor }) else { Issue.record("no Color effect"); return }
    var on = AnimatedProperty(0.0)
    on.track.insert(Keyframe(time: .zero, value: 0, interpolation: .hold))
    on.track.insert(Keyframe(time: Time(2, 1), value: 1, interpolation: .hold))
    c.effects[i].parameters[ClipEffect.colorCreativeOnKey] = on
    let tl = Timeline(name: "S", format: format, tracks: [Track(kind: .video, clips: [c])])
    let layers = RenderLoop.colorLayers(tl, sequences: [:])
    #expect(layers.contains { !$0.color.effects[0].isEnabled(.creative) })
    #expect(layers.contains { $0.color.effects[0].isEnabled(.creative) && $0.color.effects[0].creative.look == .file("/look.cube") })
}

/// Review finding (COLOR-GRADE-LINKS): the warm-up must see a range grade's own look, which starts after the clip start.
@Test func colorWarmUpCoversRangeGrades() throws {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
    var e = ColorEffect(id: 2)
    e.creative.look = .file("/range.cube"); e.creative.intensity = 50
    var fx = ClipEffect.colorGrade(e)
    fx.colorRange = TimeRange(start: Time(1, 1), duration: Time(1, 1))
    c.effects = [ClipEffect.colorGrade(ColorEffect(id: 1, inputLUT: .automatic)), fx]
    let tl = Timeline(name: "S", format: format, tracks: [Track(kind: .video, clips: [c])])
    let layers = RenderLoop.colorLayers(tl, sequences: [:])
    #expect(layers.contains { $0.color.effects.count == 2 && $0.color.effects[1].creative.look == .file("/range.cube") })
}

/// Review finding: a Before toggle warms the bypassed clips' ungraded pipelines (log conversion) up front.
@Test func bypassWarmUpListsTheUngradedColourOfBypassedClipsOnly() {
    var a = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
    var g = ClipColor.default
    g.source = .sLog3SGamut3Cine
    g.effects[0].basic.exposure = 1
    a.color = g
    let b = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: Time(4, 1))
    let tl = Timeline(name: "S", format: format, tracks: [Track(kind: .video, clips: [a, b])])
    let out = RenderLoop.ungradedColors([tl], bypass: ColorBypass(clips: [a.id], mode: .before))
    #expect(out.count == 1)
    #expect(out.first?.media == a.media && out.first?.color == g.ungraded)
}

/// Mean RGB of the columns `columns` of an rgba16Float texture.
private func meanRGB(_ texture: MTLTexture, device: MTLDevice, columns: Range<Int>) -> SIMD3<Double>? {
    let w = texture.width, h = texture.height, bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let px = buf.contents().assumingMemoryBound(to: Float16.self)
    var s = SIMD3<Double>(repeating: 0)
    for y in 0..<h { for x in columns { let i = y * w + x; s += SIMD3(Double(px[i * 4]), Double(px[i * 4 + 1]), Double(px[i * 4 + 2])) } }
    return s / Double(h * columns.count)
}

/// Color page Before / After / Split (redesign round 2 follow-up): a monitor-only grade bypass.
@Suite(.serialized) @MainActor struct ColorBypassEngineTests {
    struct Halves { var left: SIMD3<Double>; var right: SIMD3<Double> }

    /// Renders frame 10 of a Rec.709 clip graded +2 stops, then applies `bypass` to the clip (nil = graded). The bypass is
    /// set after the first composite, so the paused frame must redraw for it. `then` runs before the texture is read.
    func render(nested: Bool = false, _ bypass: ((Clip.ID) -> ColorBypass)?,
                then: ((PlaybackEngine) -> Void)? = nil) async throws -> Halves {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await SharedColorClip.shared.get()
        let media = UUID()
        let info = MediaInfo(duration: fd * 20, detectedColorSpace: .rec709)
        let resolver = LayerColorResolver(lutProvider: nil) { $0 == media ? info : nil }
        let res = ColorResolver(base: StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)]), colorResolver: resolver)
        let engine = try PlaybackEngine(device: device, media: res, clock: ManualClock())
        var clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 20),
                        start: .zero, mediaDuration: fd * 20)
        var graded = ClipColor.default
        graded.effects[0].basic.exposure = 2
        clip.color = graded
        let inner = Timeline(name: "Seq", format: format, tracks: [Track(kind: .video, clips: [clip])])
        if nested {
            // The graded clip plays inside a nested sequence: the outer clip has no grade of its own.
            let outer = Clip(name: "Nest", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: fd * 20),
                             start: .zero, sequence: inner.id)
            engine.setTimeline(Timeline(name: "Outer", format: format, tracks: [Track(kind: .video, clips: [outer])]),
                               sequences: [inner.id: inner])
        } else {
            engine.setTimeline(inner)
        }
        engine.seek(to: fd * 10)
        _ = engine.tick()
        await engine.waitForDecodes()
        #expect(engine.tick())
        if let bypass {
            engine.setColorBypass(bypass(clip.id))
            #expect(engine.tick(), "a bypass change redraws the paused frame")
        }
        then?(engine)
        let tex = try #require(engine.lastRenderedTexture)
        let half = tex.width / 2
        return Halves(left: try #require(meanRGB(tex, device: device, columns: 0..<half)),
                      right: try #require(meanRGB(tex, device: device, columns: half..<tex.width)))
    }

    @Test func beforeShowsTheClipUngradedAndSplitShowsBothHalves() async throws {
        let after = try await render(nil)
        let before = try await render { ColorBypass(clips: [$0], mode: .before) }
        let split = try await render { ColorBypass(clips: [$0], mode: .split) }
        #expect(simd_length(after.left - before.left) > 0.05, "the grade must change the picture: \(after.left) vs \(before.left)")
        #expect(simd_length(after.right - before.right) > 0.05)
        #expect(simd_length(split.left - before.left) < 1e-3, "split: left half ungraded")
        #expect(simd_length(split.right - after.right) < 1e-3, "split: right half graded")
    }

    /// Follow-up (a): a clip graded inside a nested sequence is bypassed too (Before and Split).
    @Test func clipInsideANestedSequenceIsBypassed() async throws {
        let after = try await render(nested: true, nil)
        let before = try await render(nested: true) { ColorBypass(clips: [$0], mode: .before) }
        let split = try await render(nested: true) { ColorBypass(clips: [$0], mode: .split) }
        #expect(simd_length(after.left - before.left) > 0.05, "nested: Before must drop the grade: \(after.left) vs \(before.left)")
        #expect(simd_length(split.left - before.left) < 1e-3, "nested split: left half ungraded")
        #expect(simd_length(split.right - after.right) < 1e-3, "nested split: right half graded")
    }

    @Test func bypassOfAnotherClipLeavesTheGrade() async throws {
        let after = try await render(nil)
        let other = try await render { _ in ColorBypass(clips: [UUID()], mode: .before) }
        #expect(simd_length(after.left - other.left) < 1e-3 && simd_length(after.right - other.right) < 1e-3)
    }

    @Test func clearingTheBypassRestoresTheGrade() async throws {
        let after = try await render(nil)
        let back = try await render({ ColorBypass(clips: [$0], mode: .before) }) { engine in
            engine.setColorBypass(nil)
            #expect(engine.tick())
        }
        #expect(simd_length(after.left - back.left) < 1e-3 && simd_length(after.right - back.right) < 1e-3)
    }
}
