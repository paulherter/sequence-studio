@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQProxy

/// Alpha sources (ProRes 4444 / HEVC with alpha) must get a ProRes 4444 proxy that keeps the alpha channel and its
/// straight/premultiplied meaning; a 4:2:2 proxy would silently make the clip opaque.
@Suite(.serialized) struct AlphaProxyTests {
    struct Decoded { var mode: String?; var alpha: [Double]; var luma: [Double]; var fourCC: String; var formatAlpha: Bool }

    /// First frame decoded as y416 (A, Y', Cb, Cr): alpha and luma sampled at the pattern's three columns.
    func decode(_ url: URL) async throws -> Decoded {
        let asset = AVURLAsset(url: url)
        let v = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let f = try #require(try await v.load(.formatDescriptions).first)
        let ext = CMFormatDescriptionGetExtensions(f) as? [String: Any] ?? [:]
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: v, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_4444AYpCbCr16])
        r.add(o); r.startReading()
        let sb = try #require(o.copyNextSampleBuffer())
        let pb = try #require(CMSampleBufferGetImageBuffer(sb))
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let row = (CVPixelBufferGetBaseAddress(pb)! + (h / 2) * CVPixelBufferGetBytesPerRow(pb)).assumingMemoryBound(to: UInt16.self)
        let xs = [w / 4, w * 5 / 8, w * 7 / 8]
        let mode = (CVBufferCopyAttachment(pb, kCVImageBufferAlphaChannelModeKey, nil) as? String)
            ?? ext[kCMFormatDescriptionExtension_AlphaChannelMode as String] as? String
        let sub = CMFormatDescriptionGetMediaSubType(f)
        let cc = String(bytes: [UInt8(sub >> 24), UInt8(sub >> 16 & 255), UInt8(sub >> 8 & 255), UInt8(sub & 255)], encoding: .ascii) ?? "?"
        return Decoded(mode: mode, alpha: xs.map { Double(row[$0 * 4]) / 65535 },
                       luma: xs.map { (Double(row[$0 * 4 + 1]) - 4096) / (60160 - 4096) }, fourCC: cc,
                       formatAlpha: (ext[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool) == true)
    }

    @Test(arguments: [TestClipSpec.Codec.prores4444Alpha, .hevcAlpha])
    func alphaSourceGetsProRes4444ProxyWithAlpha(codec: TestClipSpec.Codec) async throws {
        var spec = TestClipSpec(); spec.codec = codec; spec.width = 256; spec.height = 144; spec.frameCount = 4
        let src: URL
        do { src = try await TestClipWriter.write(spec) } catch TestClipError.encoderUnavailable(let why) {
            print("SKIPPED: \(why)"); return
        }
        defer { try? FileManager.default.removeItem(at: src) }
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await decode(src)
        for kind in [ProxyKind.optimized, .proxyHalf] {
            let out = dir.appendingPathComponent("\(kind.rawValue).mov")
            _ = try await ProxyTranscoder().transcode(source: src, kind: kind, destination: out, timeRange: nil) { _ in }
            let proxy = try await decode(out)
            #expect(proxy.fourCC == "ap4h", "\(kind)")
            #expect(proxy.formatAlpha, "\(kind)")
            #expect(proxy.mode == source.mode, "\(kind) alpha mode \(String(describing: proxy.mode)) != \(String(describing: source.mode))")
            for i in 0..<3 {
                #expect(abs(proxy.alpha[i] - source.alpha[i]) < 0.02, "\(kind) alpha[\(i)] \(proxy.alpha[i]) vs \(source.alpha[i])")
                if source.alpha[i] > 0.1 {
                    #expect(abs(proxy.luma[i] - source.luma[i]) < 0.03, "\(kind) luma[\(i)] \(proxy.luma[i]) vs \(source.luma[i])")
                }
            }
            #expect(source.alpha[0] > 0.98 && abs(source.alpha[1] - 0.5) < 0.03 && source.alpha[2] < 0.02)
        }
    }

    @Test func opaqueSourceKeepsProRes422() async throws {
        var spec = TestClipSpec(); spec.codec = .h264; spec.frameCount = 4
        let src = try await TestClipWriter.write(spec); defer { try? FileManager.default.removeItem(at: src) }
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("opaque.mov")
        _ = try await ProxyTranscoder().transcode(source: src, kind: .optimized, destination: out, timeRange: nil) { _ in }
        let p = try await decode(out)
        #expect(p.fourCC == "apcn")
        #expect(!p.formatAlpha)
    }

    @Test func alphaDetectionFromFormatDescription() throws {
        func desc(_ ext: [CFString: Any]) throws -> CMFormatDescription {
            var f: CMFormatDescription?
            CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_AppleProRes4444, width: 16, height: 16,
                                           extensions: ext as CFDictionary, formatDescriptionOut: &f)
            return try #require(f)
        }
        #expect(!ProxyTranscoder.hasAlpha(try desc([:])))
        #expect(!ProxyTranscoder.hasAlpha(try desc([kCMFormatDescriptionExtension_Depth: 32])))
        #expect(ProxyTranscoder.hasAlpha(try desc([kCMFormatDescriptionExtension_ContainsAlphaChannel: true])))
        #expect(ProxyTranscoder.hasAlpha(try desc([kCMFormatDescriptionExtension_AlphaChannelMode: kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha])))
    }
}
