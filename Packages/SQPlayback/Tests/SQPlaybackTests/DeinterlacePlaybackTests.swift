import CoreMedia
import CoreVideo
import Foundation
import Metal
import Synchronization
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
import SQRender
@testable import SQPlayback

// The monitor decodes interlaced media through the deinterlace pass, following the media item's switch. The pass works
// on the stored picture and marks its output (`Deinterlacer.isDeinterlaced`), the decoder then brings it to the size
// its key names: the mark tells the two decoders apart here (the test clip is progressive; only the project's info
// calls it interlaced).

private let fd = Time(1, 30)
private let format = SequenceFormat(width: 512, height: 288, frameDuration: fd)

private actor FieldClips {
    static let shared = FieldClips()
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

private final class FieldInfo: Sendable {
    private let state: Mutex<MediaInfo?>
    init(_ info: MediaInfo?) { state = Mutex(info) }
    func read() -> MediaInfo? { state.withLock { $0 } }
    func set(_ info: MediaInfo?) { state.withLock { $0 = info } }
}

private final class FieldResolver: MediaResolver, Sendable {
    let id: UUID
    let original: any Demuxing
    let proxy: (any Demuxing)?
    let colorResolver: LayerColorResolver?

    init(id: UUID, original: any Demuxing, proxy: (any Demuxing)?, shared: FieldInfo) {
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

@Suite(.serialized) @MainActor struct DeinterlacePlaybackTests {
    @MainActor fileprivate struct Rig {
        let engine: PlaybackEngine
        let media: UUID
        fileprivate let shared: FieldInfo

        func pause(at n: Int64) async throws {
            engine.seek(to: fd * n)
            for _ in 0..<200 {
                _ = engine.tick()
                if let p = engine.lastTickProfile, p.time == fd * n, p.presented, p.missing == 0, p.noFrame == 0 { return }
                await engine.waitForDecodes()
            }
            Issue.record("frame \(n) never completed")
        }

        /// Stored height of the frame the monitor decoded for `key` at half quality.
        func height(_ key: UUID, at n: Int64) -> Int? {
            engine.loop.cache.frame(FrameKey(media: key, pts: fd * n, scale: .half)).map { CVPixelBufferGetHeight($0.pixelBuffer) }
        }

        /// Whether that frame went through the deinterlace pass.
        func deinterlaced(_ key: UUID, at n: Int64) -> Bool? {
            engine.loop.cache.frame(FrameKey(media: key, pts: fd * n, scale: .half)).map { Deinterlacer.isDeinterlaced($0.pixelBuffer) }
        }
    }

    static func video(_ order: FieldOrder?, off: Bool = false) -> MediaInfo {
        MediaInfo(duration: fd * 12, video: VideoTrackInfo(width: 512, height: 288, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                                           nominalFrameDuration: fd, isVariableFrameRate: false,
                                                           fieldOrder: order, deinterlaceOff: off))
    }

    fileprivate func rig(_ info: MediaInfo?, proxy: Bool = false) async throws -> Rig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let clips = try await FieldClips.shared.get()
        let m = UUID()
        let shared = FieldInfo(info)
        let p: (any Demuxing)? = proxy ? try await AVDemuxer(url: clips.proxy) : nil
        let resolver = FieldResolver(id: m, original: try await AVDemuxer(url: clips.original), proxy: p, shared: shared)
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        engine.quality = .half
        let clip = Clip(name: "A", media: m, kind: .video, source: TimeRange(start: .zero, duration: fd * 12), start: .zero, mediaDuration: fd * 12)
        engine.setTimeline(Timeline(name: "Seq", format: format, tracks: [Track(kind: .video, clips: [clip])]))
        return Rig(engine: engine, media: m, shared: shared)
    }

    @Test func progressiveMediaIsDecodedAsBefore() async throws {
        let r = try await rig(Self.video(nil))
        try await r.pause(at: 1)
        #expect(r.height(r.media, at: 1) == 144)
        #expect(r.deinterlaced(r.media, at: 1) == false)
        #expect(r.engine.loop.media.deinterlace(r.media) == nil)
    }

    @Test(arguments: [FieldOrder.topFirst, .bottomFirst])
    func interlacedMediaIsDeinterlacedAfterDecode(order: FieldOrder) async throws {
        let r = try await rig(Self.video(order))
        try await r.pause(at: 1)
        #expect(r.engine.loop.media.deinterlace(r.media) == order)
        #expect(r.deinterlaced(r.media, at: 1) == true, "the pass ran")
        #expect(r.height(r.media, at: 1) == 144, "and the frame has the size its key names")
    }

    /// The media item's switch: off shows the stored fields; `mediaChanged` (what the session calls on the change)
    /// brings the new decoder.
    @Test func theSwitchOfTheMediaItemTurnsThePassOff() async throws {
        let r = try await rig(Self.video(.topFirst, off: true))
        try await r.pause(at: 1)
        #expect(r.engine.loop.media.deinterlace(r.media) == nil)
        #expect(r.deinterlaced(r.media, at: 1) == false)
        r.shared.set(Self.video(.topFirst))
        r.engine.mediaChanged([r.media])
        try await r.pause(at: 1)
        #expect(r.deinterlaced(r.media, at: 1) == true)
        #expect(r.height(r.media, at: 1) == 144)
    }

    /// A proxy of interlaced media was written deinterlaced: its frames take no second pass. With Deinterlace off the
    /// proxy is not the picture asked for, so the original is decoded.
    @Test func proxyFramesAreNotDeinterlacedAgain() async throws {
        for off in [false, true] {
            let r = try await rig(Self.video(.topFirst, off: off), proxy: true)
            r.engine.beginScrub()
            r.engine.scrub(to: fd * 1)
            for _ in 0..<8 { _ = r.engine.tick(); await r.engine.waitForDecodes() }
            _ = r.engine.tick()
            if off {
                #expect(r.engine.loop.media.existingProxyID(for: r.media).flatMap { r.height($0, at: 1) } == nil, "no proxy frame")
                let stored = [DecodeScale.full, .half, .quarter].flatMap { scale in
                    (0..<12).compactMap { r.engine.loop.cache.frame(FrameKey(media: r.media, pts: fd * Int64($0), scale: scale)) }
                }
                #expect(!stored.isEmpty, "the original was decoded")
                #expect(stored.allSatisfy { !Deinterlacer.isDeinterlaced($0.pixelBuffer) }, "and not deinterlaced")
            } else {
                let key = try #require(r.engine.loop.media.existingProxyID(for: r.media))
                #expect(r.engine.loop.media.deinterlace(key) == nil)
                let cached = r.engine.loop.cache.frame(FrameKey(media: key, pts: fd * 1))
                    ?? r.engine.loop.cache.frame(FrameKey(media: key, pts: fd * 1, scale: .half))
                #expect(cached != nil, "the proxy was decoded")
                #expect(r.height(r.media, at: 1) == nil)
            }
            r.engine.endScrub()
        }
    }
}
