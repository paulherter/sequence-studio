import Testing
import Foundation
import Metal
import simd
import SSCore
import SSMedia
import SSMediaTestSupport
import SSRender
@testable import SSPlayback

private let fd = Time(1, 30)
private let format = SequenceFormat(width: 320, height: 180, frameDuration: fd)

/// Wraps a static resolver and adds a `LayerColorResolver` (what `ProjectMediaResolver` does in the app).
private struct ColorResolver: MediaResolver {
    let base: StaticMediaResolver
    let colorResolver: LayerColorResolver?
    func demuxer(for media: UUID) throws -> any Demuxing { try base.demuxer(for: media) }
    func audio(for media: UUID) throws -> any AudioSource { try base.audio(for: media) }
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
        var spec = TestClipSpec()
        spec.frameCount = 20
        spec.frameDuration = TestClipSpec.fps(30)
        let url = try await TestClipWriter.write(spec)
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
