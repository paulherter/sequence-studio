import Testing
import CoreMedia
import Foundation
import Metal
import Synchronization
import simd
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

// W9.9 AutoProxy: the monitor decodes a ready proxy while scrubbing (and while playing when `proxyUse.playback` is on);
// paused frames and every export read the original. Proxy frames live under their own media key, so swapping never mixes
// the two in the cache, and the picture keeps the original's size, rotation and color pipeline.

private let fd = Time(1, 30)
private let format = SequenceFormat(width: 512, height: 288, frameDuration: fd)

/// Original (H.264, GOP 12) and proxy (ProRes 4444, intra, half size) of the same 60 frames; generated once.
private actor ProxyClips {
    static let shared = ProxyClips()
    private var urls: (URL, URL, URL)?
    func get() async throws -> (original: URL, proxy: URL, shortProxy: URL) {
        if let urls { return urls }
        var o = TestClipSpec(); o.width = 512; o.height = 288; o.frameCount = 60
        var p = TestClipSpec(); p.codec = .prores4444; p.width = 256; p.height = 144; p.frameCount = 60
        var s = p; s.frameCount = 40
        let r = (try await TestClipWriter.write(o), try await TestClipWriter.write(p), try await TestClipWriter.write(s))
        urls = r
        return r
    }
}

/// Originals plus switchable proxies (what `ProjectMediaResolver` does with the proxy cache in the app).
final class ProxyTestResolver: MediaResolver, Sendable {
    let originals: [UUID: any Demuxing]
    private let proxies = Mutex<[UUID: any Demuxing]>([:])
    let proxyAsks = Mutex(0)
    init(originals: [UUID: any Demuxing]) { self.originals = originals }
    func setProxy(_ d: (any Demuxing)?, for m: UUID) { proxies.withLock { $0[m] = d } }
    func demuxer(for media: UUID) throws -> any Demuxing {
        guard let d = originals[media] else { throw MediaResolverError.unknownMedia(media) }
        return d
    }
    func audio(for media: UUID) throws -> any AudioSource { throw MediaResolverError.unknownMedia(media) }
    func proxyDemuxer(for media: UUID) throws -> (any Demuxing)? {
        proxyAsks.withLock { $0 += 1 }
        return proxies.withLock { $0[media] }
    }
}

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

@Test func proxyUseRuleScrubPlaybackPaused() {
    let scrubOnly = ProxyUse(scrubbing: true, playback: false)
    #expect(RenderLoop.usesProxy(scrubbing: true, playing: false, use: scrubOnly))
    #expect(!RenderLoop.usesProxy(scrubbing: false, playing: true, use: scrubOnly))
    #expect(!RenderLoop.usesProxy(scrubbing: false, playing: false, use: scrubOnly))       // paused: exact original frame
    let both = ProxyUse(scrubbing: true, playback: true)
    #expect(RenderLoop.usesProxy(scrubbing: false, playing: true, use: both))
    #expect(!RenderLoop.usesProxy(scrubbing: false, playing: false, use: both))
    #expect(!RenderLoop.usesProxy(scrubbing: true, playing: false, use: .off))
    #expect(!RenderLoop.usesProxy(scrubbing: false, playing: true, use: .off))
    #expect(ProxyUse.default == scrubOnly)
}

/// A half-size proxy is already a reduced decode: the viewer's reduction is applied on top only for what remains.
@Test func proxyDecodeScaleDividesOutTheProxyReduction() {
    #expect(RenderLoop.decodeScale(.full, proxyDivisor: 2) == .full)
    #expect(RenderLoop.decodeScale(.half, proxyDivisor: 2) == .full)
    #expect(RenderLoop.decodeScale(.quarter, proxyDivisor: 2) == .half)
    #expect(RenderLoop.decodeScale(.quarter, proxyDivisor: 4) == .full)
    #expect(RenderLoop.decodeScale(.half, proxyDivisor: 4) == .full)
    #expect(RenderLoop.decodeScale(.quarter, proxyDivisor: 1) == .quarter)
    #expect(RenderLoop.proxyDivisor(originalWidth: 3840, proxyWidth: 1920) == 2)
    #expect(RenderLoop.proxyDivisor(originalWidth: 3840, proxyWidth: 960) == 4)
    #expect(RenderLoop.proxyDivisor(originalWidth: 1920, proxyWidth: 1920) == 1)
    #expect(RenderLoop.proxyDivisor(originalWidth: 100, proxyWidth: 0) == 1)
}

/// A proxy frame takes geometry and color tags (matrix, transfer, primaries) from the original, its pixel format from itself.
@Test func proxyInfoTakesTheOriginalsColourTags() throws {
    let proxy = VideoTrackInfo(width: 1920, height: 1080, codec: "apcn", bitDepth: 10, chroma: "4:2:2", nominalFrameDuration: fd,
                               isVariableFrameRate: false, colorPrimaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", rotation: 0)
    let orig = VideoTrackInfo(width: 3840, height: 2160, codec: "avc1", bitDepth: 10, chroma: "4:2:0", nominalFrameDuration: fd,
                              isVariableFrameRate: false, colorPrimaries: "ITU_R_2020", transfer: "ITU_R_2100_HLG", matrix: "ITU_R_2020", rotation: 90)
    var fmt: CMFormatDescription?
    CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 3840, height: 2160, extensions: nil, formatDescriptionOut: &fmt)
    let known = RenderLoop.proxyInfo(proxy, original: orig, originalFormat: try #require(fmt), rotation: 0)
    #expect(known.width == 3840 && known.height == 2160 && known.rotation == 90)
    #expect(known.matrix == "ITU_R_2020" && known.transfer == "ITU_R_2100_HLG" && known.colorPrimaries == "ITU_R_2020")
    #expect(known.codec == "apcn" && known.chroma == "4:2:2")
    // Original not decoded yet: tags from its format description (untagged stays untagged, not the proxy's 709).
    var tagged: CMFormatDescription?
    CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 3840, height: 2160,
                                   extensions: [kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4] as CFDictionary,
                                   formatDescriptionOut: &tagged)
    let cold = RenderLoop.proxyInfo(proxy, original: nil, originalFormat: try #require(tagged), rotation: 180)
    #expect(cold.width == 3840 && cold.height == 2160 && cold.rotation == 180)
    #expect(cold.matrix == "ITU_R_601_4" && cold.transfer == nil && cold.colorPrimaries == nil)
}

@Suite(.serialized) @MainActor struct ProxySourceEngineTests {
    @MainActor struct Rig {
        let engine: PlaybackEngine
        let resolver: ProxyTestResolver
        let media: UUID
        let device: MTLDevice
        let original: any Demuxing
        let proxy: any Demuxing
        let shortProxy: any Demuxing
        var loop: RenderLoop { engine.loop }
        var proxyID: UUID? { loop.media.existingProxyID(for: media) }
        func originalFrame(_ n: Int) -> DecodedFrame? { loop.cache.frame(FrameKey(media: media, pts: fd * Int64(n))) }
        func proxyFrame(_ n: Int) -> DecodedFrame? {
            guard let p = proxyID else { return nil }
            return loop.cache.frame(FrameKey(media: p, pts: fd * Int64(n)))
        }
        /// The original's scrub (sync) frame for frame `n`, from the cache.
        func originalScrubFrame(_ n: Int) -> DecodedFrame? {
            let idx = original.index
            let k = PrefetchPlanner.scrubFrame(for: RenderLoop.frameIndex(fd * Int64(n), in: idx), in: idx)
            return loop.cache.frame(FrameKey(media: media, pts: idx.entries[k].pts))
        }
        func settle() async {
            for _ in 0..<6 { _ = engine.tick(); await engine.waitForDecodes() }
            _ = engine.tick()
        }
    }

    func rig(proxyReady: Bool = true) async throws -> Rig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let clips = try await ProxyClips.shared.get()
        let m = UUID()
        let o = try await AVDemuxer(url: clips.original), p = try await AVDemuxer(url: clips.proxy)
        let s = try await AVDemuxer(url: clips.shortProxy)
        let resolver = ProxyTestResolver(originals: [m: o])
        if proxyReady { resolver.setProxy(p, for: m) }
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        let clip = Clip(name: "A", media: m, kind: .video, source: TimeRange(start: .zero, duration: fd * 60), start: .zero, mediaDuration: fd * 60)
        engine.setTimeline(Timeline(name: "Seq", format: format, tracks: [Track(kind: .video, clips: [clip])]))
        return Rig(engine: engine, resolver: resolver, media: m, device: device, original: o, proxy: p, shortProxy: s)
    }

    @Test func scrubDecodesTheProxyAndReleaseDecodesTheOriginal() async throws {
        let r = try await rig()
        r.engine.beginScrub()
        r.engine.scrub(to: fd * 40)
        await r.settle()
        // The exact frame 40 from the proxy (intra: no keyframe snap), nothing of the original.
        #expect(r.proxyFrame(40) != nil)
        #expect(r.originalScrubFrame(40) == nil && r.originalFrame(40) == nil)
        #expect(r.engine.lastRenderedTexture != nil)
        r.engine.endScrub()
        await r.settle()
        #expect(r.originalFrame(40) != nil, "paused frames come from the original")
    }

    @Test func pausedSeekNeverUsesTheProxy() async throws {
        let r = try await rig()
        r.engine.seek(to: fd * 20)
        await r.settle()
        #expect(r.originalFrame(20) != nil)
        #expect(r.proxyFrame(20) == nil)
    }

    @Test func playbackUsesTheProxyOnlyWhenEnabled() async throws {
        let r = try await rig()
        r.engine.play()
        await r.settle()
        #expect(r.originalFrame(0) != nil && r.proxyFrame(0) == nil)
        r.engine.pause()
        let p = try await rig()
        p.engine.proxyUse = ProxyUse(scrubbing: true, playback: true)
        p.engine.play()
        await p.settle()
        #expect(p.proxyFrame(0) != nil)
        #expect(p.originalFrame(0) == nil)
        p.engine.pause()
    }

    @Test func proxyUseOffScrubsTheOriginal() async throws {
        let r = try await rig()
        r.engine.proxyUse = .off
        r.engine.beginScrub()
        r.engine.scrub(to: fd * 40)
        await r.settle()
        #expect(r.originalScrubFrame(40) != nil, "keyframe-only scrub of the original")
        #expect(r.proxyFrame(40) == nil)
    }

    /// Frame N of the proxy sits at frame N's presentation time of the original: same key time, no shift.
    @Test func proxyFramesKeepTheOriginalTimes() async throws {
        let r = try await rig()
        #expect(r.proxy.index.count == r.original.index.count)
        r.engine.beginScrub()
        for n in [7, 23, 41, 59] {
            r.engine.scrub(to: fd * Int64(n))
            await r.settle()
            let f = try #require(r.proxyFrame(n), "frame \(n)")
            #expect(f.pts == r.original.index.entries[RenderLoop.frameIndex(fd * Int64(n), in: r.original.index)].pts)
        }
        r.engine.endScrub()
    }

    /// Review 7: on a weak Mac (reduced preview decode) a proxy is decoded at the size its frames are keyed by: a
    /// full-size proxy (divisor 1) at Full decodes at half and is keyed half (it decoded full under a half key), and a
    /// switch to Half (same key size) keeps it so.
    @Test func reducedDecodeKeysAFullSizeProxyByItsRealSize() async throws {
        let r = try await rig(proxyReady: false)
        let clips = try await ProxyClips.shared.get()
        r.resolver.setProxy(try await AVDemuxer(url: clips.original), for: r.media)       // same size as the original
        r.engine.proxiesChanged([r.media])
        r.engine.loop.setReducesFullDecode(true)
        r.engine.proxyUse = ProxyUse(scrubbing: true, playback: true)
        r.engine.play()
        await r.settle()
        r.engine.pause()
        let p = try #require(r.proxyID)
        let f = try #require(r.loop.cache.frame(FrameKey(media: p, pts: .zero, scale: .half)))
        #expect(CVPixelBufferGetWidth(f.pixelBuffer) == 256)
        #expect(r.loop.cache.frame(FrameKey(media: p, pts: .zero, scale: .full)) == nil)
        r.engine.quality = .half
        r.engine.seek(to: fd * 30)
        r.engine.play()
        await r.settle()
        r.engine.pause()
        let g = try #require(r.loop.cache.frame(FrameKey(media: p, pts: fd * 30, scale: .half)))
        #expect(CVPixelBufferGetWidth(g.pixelBuffer) == 256)
    }

    /// A proxy whose frame count differs (truncated) would shift edit points: it is not used.
    @Test func proxyWithAnotherFrameCountIsIgnored() async throws {
        let r = try await rig(proxyReady: false)
        r.resolver.setProxy(r.shortProxy, for: r.media)
        r.engine.proxiesChanged([r.media])
        r.engine.beginScrub()
        r.engine.scrub(to: fd * 20)
        await r.settle()
        #expect(r.originalScrubFrame(20) != nil)
        #expect(r.proxyFrame(20) == nil)
    }

    /// The proxy is drawn at the original's size with the original's color pipeline: the composite matches.
    @Test func proxyCompositeMatchesTheOriginal() async throws {
        let r = try await rig()
        r.engine.seek(to: fd * 24)
        await r.settle()
        let t0 = try #require(r.engine.lastRenderedTexture)
        let original = try #require(meanRGB(t0, device: r.device))
        r.engine.beginScrub()
        r.engine.scrub(to: fd * 24)
        await r.settle()
        #expect(r.proxyFrame(24) != nil)
        let t1 = try #require(r.engine.lastRenderedTexture)
        let proxied = try #require(meanRGB(t1, device: r.device))
        #expect(simd_length(original - proxied) < 0.04, "\(original) vs \(proxied)")
        r.engine.endScrub()
    }

    @Test func proxyBecomingReadySwapsAndRemovalSwapsBack() async throws {
        let r = try await rig(proxyReady: false)
        r.engine.beginScrub()
        r.engine.scrub(to: fd * 40)
        await r.settle()
        #expect(r.originalScrubFrame(40) != nil)
        // Proxy finished in the background.
        r.resolver.setProxy(r.proxy, for: r.media)
        r.engine.proxiesChanged([r.media])
        r.engine.scrub(to: fd * 44)              // a jump: a slow drag (1-2 frames) refines to the exact original frame
        await r.settle()
        #expect(r.proxyFrame(44) != nil)
        // Source changed (proxy invalid): the proxy frames go, scrubbing uses the original again.
        r.resolver.setProxy(nil, for: r.media)
        r.engine.proxiesChanged([r.media])
        #expect(r.proxyFrame(44) == nil)
        r.engine.scrub(to: fd * 50)
        await r.settle()
        #expect(r.originalScrubFrame(50) != nil)
        r.engine.endScrub()
    }

    @Test func relinkForgetsTheProxyToo() async throws {
        let r = try await rig()
        r.engine.beginScrub()
        r.engine.scrub(to: fd * 30)
        await r.settle()
        #expect(r.proxyFrame(30) != nil)
        let asked = r.resolver.proxyAsks.withLock { $0 }
        r.engine.mediaChanged([r.media])
        #expect(r.proxyFrame(30) == nil)
        r.engine.scrub(to: fd * 31)
        await r.settle()
        #expect(r.resolver.proxyAsks.withLock { $0 } > asked, "the proxy is resolved again after a relink")
        r.engine.endScrub()
    }
}
