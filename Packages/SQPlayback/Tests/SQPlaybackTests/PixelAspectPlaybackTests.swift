import CoreMedia
import Foundation
import Metal
import Synchronization
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
import SQRender
@testable import SQPlayback

// F7.3: a decoded video layer (and its proxy) is drawn with the pixel aspect the project holds for the media item.
// The clip is 512x288 in a 1024x288 sequence; its frame stamp puts a white block top-left in frame 1 (bit 0) and black
// blocks right of it. Read as square pixels the picture sits in the middle (x 256...768); read 2:1 it fills the canvas.

private let fd = Time(1, 30)
private let format = SequenceFormat(width: 1024, height: 288, frameDuration: fd)

private actor ShapeClips {
    static let shared = ShapeClips()
    private var urls: (URL, URL)?
    func get() async throws -> (original: URL, proxy: URL) {
        if let urls { return urls }
        var o = TestClipSpec(); o.width = 512; o.height = 288; o.frameCount = 12
        var p = TestClipSpec(); p.codec = .prores4444; p.width = 256; p.height = 144; p.frameCount = 12
        let r = (try await TestClipWriter.write(o), try await TestClipWriter.write(p))
        urls = r
        return r
    }
}

private final class ShapeResolver: MediaResolver, Sendable {
    let id: UUID
    let original: any Demuxing
    let proxy: (any Demuxing)?
    let colorResolver: LayerColorResolver?

    init(id: UUID, original: any Demuxing, proxy: (any Demuxing)?, shared: SharedInfo) {
        self.id = id; self.original = original; self.proxy = proxy
        colorResolver = LayerColorResolver(lutProvider: nil) { [shared] m in m == id ? shared.read() : nil }
    }

    func demuxer(for media: UUID) throws -> any Demuxing {
        guard media == id else { throw MediaResolverError.unknownMedia(media) }
        return original
    }
    func audio(for media: UUID) throws -> any AudioSource { throw MediaResolverError.unknownMedia(media) }
    func proxyDemuxer(for media: UUID) throws -> (any Demuxing)? { media == id ? proxy : nil }
}

/// The project's info of the one media item, changeable like an edit; counts how often it is read.
private final class SharedInfo: Sendable {
    private let state: Mutex<(info: MediaInfo?, reads: Int)>
    init(_ info: MediaInfo?) { state = Mutex((info, 0)) }
    func read() -> MediaInfo? { state.withLock { $0.reads += 1; return $0.info } }
    func set(_ info: MediaInfo?) { state.withLock { $0.info = info } }
    var reads: Int { state.withLock { $0.reads } }
}

private func red(_ t: MTLTexture, x: Double, y: Double, device: MTLDevice) -> Float {
    let w = t.width, h = t.height, bpr = w * 8
    let q = device.makeCommandQueue()!, buf = device.makeBuffer(length: bpr * h, options: .storageModeShared)!
    let cb = q.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let px = min(w - 1, Int(x * Double(w))), py = min(h - 1, Int(y * Double(h)))
    return Float(buf.contents().assumingMemoryBound(to: Float16.self)[(py * w + px) * 4])
}

@Suite(.serialized) @MainActor struct PixelAspectPlaybackTests {
    @MainActor fileprivate struct Rig {
        let engine: PlaybackEngine
        let media: UUID
        fileprivate let shared: SharedInfo
        let device: MTLDevice

        /// The first stamp block where a canvas-wide picture has it, and where a picture in the middle has it.
        func blocks() throws -> (left: Float, middle: Float) {
            let t = try #require(engine.lastRenderedTexture)
            return (red(t, x: 8.0 / 1024, y: 8.0 / 288, device: device), red(t, x: 264.0 / 1024, y: 8.0 / 288, device: device))
        }

        func pause(at n: Int64) async throws {
            engine.seek(to: fd * n)
            for _ in 0..<200 {
                _ = engine.tick()
                if let p = engine.lastTickProfile, p.time == fd * n, p.presented, p.missing == 0, p.noFrame == 0 { return }
                await engine.waitForDecodes()
            }
            Issue.record("frame \(n) never completed")
        }
    }

    static func video(_ override: PixelAspect?, tag: PixelAspect = .square) -> MediaInfo {
        MediaInfo(duration: fd * 12, video: VideoTrackInfo(width: 512, height: 288, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                                           nominalFrameDuration: fd, isVariableFrameRate: false,
                                                           pixelAspect: tag, pixelAspectOverride: override))
    }

    fileprivate func rig(_ info: MediaInfo?, proxy: Bool = false) async throws -> Rig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let clips = try await ShapeClips.shared.get()
        let m = UUID()
        let shared = SharedInfo(info)
        let p: (any Demuxing)? = proxy ? try await AVDemuxer(url: clips.proxy) : nil
        let resolver = ShapeResolver(id: m, original: try await AVDemuxer(url: clips.original), proxy: p, shared: shared)
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        engine.quality = .full
        let clip = Clip(name: "A", media: m, kind: .video, source: TimeRange(start: .zero, duration: fd * 12), start: .zero, mediaDuration: fd * 12)
        engine.setTimeline(Timeline(name: "Seq", format: format, tracks: [Track(kind: .video, clips: [clip])]))
        return Rig(engine: engine, media: m, shared: shared, device: device)
    }

    @Test func squareVideoSitsInTheMiddle() async throws {
        let r = try await rig(Self.video(nil))
        try await r.pause(at: 1)
        let b = try r.blocks()
        #expect(b.left < 0.05 && b.middle > 0.5)
    }

    @Test func chosenPixelAspectWidensTheVideoLayer() async throws {
        let r = try await rig(Self.video(PixelAspect(2, 1)!))
        try await r.pause(at: 1)
        let b = try r.blocks()
        #expect(b.left > 0.5 && b.middle < 0.05)
    }

    /// A file whose own tag says 2:1 (no override) is drawn wide; an override back to square wins over the tag.
    @Test func taggedVideoIsDrawnWideAndAnOverrideWins() async throws {
        let tagged = try await rig(Self.video(nil, tag: PixelAspect(2, 1)!))
        try await tagged.pause(at: 1)
        var b = try tagged.blocks()
        #expect(b.left > 0.5 && b.middle < 0.05)
        let overridden = try await rig(Self.video(.square, tag: PixelAspect(2, 1)!))
        try await overridden.pause(at: 1)
        b = try overridden.blocks()
        #expect(b.left < 0.05 && b.middle > 0.5)
    }

    /// Media the project has no info for (a legacy item, a file not probed yet) is drawn as stored.
    @Test func mediaUnknownToTheProjectIsSquare() async throws {
        let r = try await rig(nil)
        try await r.pause(at: 1)
        let b = try r.blocks()
        #expect(b.left < 0.05 && b.middle > 0.5)
    }

    /// The shape is read with the resolve, not per layer per tick; `mediaChanged` (what the session calls when the
    /// pixel aspect of an item changes) drops it with the frames and the monitor shows the new shape.
    @Test func shapeIsCachedUntilTheMediaChanges() async throws {
        let r = try await rig(Self.video(nil))
        try await r.pause(at: 1)
        let reads = r.shared.reads
        for _ in 0..<20 { r.engine.redraw(); _ = r.engine.tick() }
        // The color pipeline asks for the info once per layer per tick; the shape adds nothing to that.
        #expect(r.shared.reads - reads <= 20)
        r.shared.set(Self.video(PixelAspect(2, 1)!))
        r.engine.mediaChanged([r.media])
        try await r.pause(at: 1)
        let b = try r.blocks()
        #expect(b.left > 0.5 && b.middle < 0.05)
    }

    /// A proxy is a smaller picture of the same frame: it takes the original's size and the item's shape, once.
    @Test func proxyFramesAreDrawnInTheSameShape() async throws {
        for (aspect, wide) in [(PixelAspect?.none, false), (PixelAspect(2, 1), true)] {
            let r = try await rig(Self.video(aspect), proxy: true)
            r.engine.beginScrub()
            r.engine.scrub(to: fd * 1)
            for _ in 0..<8 { _ = r.engine.tick(); await r.engine.waitForDecodes() }
            _ = r.engine.tick()
            let key = try #require(r.engine.loop.media.existingProxyID(for: r.media))
            #expect(r.engine.loop.cache.frame(FrameKey(media: key, pts: fd * 1)) != nil, "the proxy was decoded")
            #expect(r.engine.loop.cache.frame(FrameKey(media: r.media, pts: fd * 1)) == nil)
            let b = try r.blocks()
            if wide { #expect(b.left > 0.5 && b.middle < 0.05) } else { #expect(b.left < 0.05 && b.middle > 0.5) }
            r.engine.endScrub()
        }
    }
}
