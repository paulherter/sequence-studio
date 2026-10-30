@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQProxy

private let sonyFile = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Videos/iOS 27 Features #2/C2160.MP4")

private struct Probe {
    var fourCC: String, width: Int, height: Int, seconds: Double
    var primaries: String?, transfer: String?, matrix: String?
    var audioTracks: Int, audioChannels: Int
    var frames: Int, firstPTS: Double, pts: [Int64]
}

private func fourCC(_ c: FourCharCode) -> String {
    String(bytes: [UInt8(c >> 24), UInt8(c >> 16 & 255), UInt8(c >> 8 & 255), UInt8(c & 255)], encoding: .ascii) ?? "?"
}

private func probe(_ url: URL, range: CMTimeRange? = nil) async throws -> Probe {
    let a = AVURLAsset(url: url)
    let v = try #require(try await a.loadTracks(withMediaType: .video).first)
    let f = try #require(try await v.load(.formatDescriptions).first)
    let dims = CMVideoFormatDescriptionGetDimensions(f)
    let ext = CMFormatDescriptionGetExtensions(f) as? [String: Any] ?? [:]
    let audio = try await a.loadTracks(withMediaType: .audio)
    var ch = 0
    if let af = try await audio.first?.load(.formatDescriptions).first,
       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(af) { ch = Int(asbd.pointee.mChannelsPerFrame) }
    let r = try AVAssetReader(asset: a)
    if let range { r.timeRange = range }
    let o = AVAssetReaderTrackOutput(track: v, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10])
    o.alwaysCopiesSampleData = false
    r.add(o); r.startReading()
    var n = 0; var first = -1.0; var stamps: [Int64] = []
    while let sb = o.copyNextSampleBuffer() {
        if first < 0 { first = CMSampleBufferGetPresentationTimeStamp(sb).seconds }
        n += 1
        stamps.append(CMSampleBufferGetPresentationTimeStamp(sb).convertScale(1_000_000, method: .roundHalfAwayFromZero).value)
    }
    return Probe(fourCC: fourCC(CMFormatDescriptionGetMediaSubType(f)), width: Int(dims.width), height: Int(dims.height),
                 seconds: try await a.load(.duration).seconds,
                 primaries: ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
                 transfer: ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
                 matrix: ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String,
                 audioTracks: audio.count, audioChannels: ch, frames: n, firstPTS: first, pts: stamps.sorted())
}

private func size(_ u: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? NSNumber)?.int64Value ?? 0
}

@Suite(.serialized) struct IntegrationTests {
    let five = TimeRange(start: .zero, duration: Time(5, 1))
    let fiveCM = CMTimeRange(start: .zero, duration: CMTime(value: 5, timescale: 1))

    @Test func sonyClipOptimizedAndQuarter() async throws {
        guard FileManager.default.fileExists(atPath: sonyFile.path) else {
            print("SKIPPED: \(sonyFile.path) not found"); return
        }
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await probe(sonyFile, range: fiveCM)
        print("SOURCE: \(src.fourCC) \(src.width)x\(src.height) frames=\(src.frames) primaries=\(String(describing: src.primaries))")
        let transcoder = ProxyTranscoder()
        for kind in [ProxyKind.optimized, .proxyQuarter] {
            let out = dir.appendingPathComponent("\(kind.rawValue).mov")
            let t0 = Date()
            let res = try await transcoder.transcode(source: sonyFile, kind: kind, destination: out, timeRange: five) { _ in }
            let wall = Date().timeIntervalSince(t0)
            let p = try await probe(out)
            print("RESULT \(kind): wall \(String(format: "%.2f", wall)) s, realtime x\(String(format: "%.2f", 5 / wall)), " +
                  "size \(size(out) / 1_000_000) MB, \(p.fourCC) \(p.width)x\(p.height) frames=\(p.frames) \(String(describing: p.primaries))")
            #expect(p.fourCC == kind.codecFourCC)
            let expected = ProxyDimensions(width: src.width, height: src.height).scaled(divisor: kind.scaleDivisor)
            #expect(p.width == expected.width && p.height == expected.height)
            #expect(res.dimensions == expected)
            #expect(abs(p.seconds - 5) < 0.1)

            if src.primaries != nil {
                #expect(p.primaries == src.primaries && p.transfer == src.transfer && p.matrix == src.matrix)
            } else {
                // Untagged source: the ProRes encoder tags the output BT.709 (AVFoundation's implicit default for HD/UHD).
                #expect(p.primaries == "ITU_R_709_2" && p.transfer == "ITU_R_709_2" && p.matrix == "ITU_R_709_2")
            }
            // timing: identical presentation times (within 1 us), so frame rate / VFR is preserved
            #expect(p.pts.count == src.pts.count)
            #expect(zip(p.pts, src.pts).allSatisfy { abs($0 - $1) <= 1 })
            #expect(p.frames == src.frames)
            #expect(p.audioChannels == src.audioChannels && p.audioTracks == src.audioTracks)
        }
    }

    @Test func sonyIsLongGOPAndProxyIsNot() async throws {
        guard FileManager.default.fileExists(atPath: sonyFile.path) else {
            print("SKIPPED: \(sonyFile.path) not found"); return
        }
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let prober = AVSourceSeekProber(), policy = ProxyPolicy()
        let srcInfo = try await prober.probe(sonyFile)
        print("SONY PROBE: \(srcInfo)")
        #expect(policy.decide(srcInfo) == .needsProxy(.proxyHalf))
        let out = dir.appendingPathComponent("half.mov")
        _ = try await ProxyTranscoder().transcode(source: sonyFile, kind: .proxyHalf, destination: out,
                                                  timeRange: TimeRange(start: .zero, duration: Time(2, 1))) { _ in }
        let proxyInfo = try await prober.probe(out)
        print("PROXY PROBE: \(proxyInfo)")
        #expect(policy.decide(proxyInfo) == .skip(.intraOnlyCodec))
    }

    @Test func cancelLeavesNoFile() async throws {
        guard FileManager.default.fileExists(atPath: sonyFile.path) else {
            print("SKIPPED: \(sonyFile.path) not found"); return
        }
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("cancel.mov.partial")
        let transcoder = ProxyTranscoder()
        let task = Task {
            try await transcoder.transcode(source: sonyFile, kind: .optimized, destination: out,
                                           timeRange: TimeRange(start: .zero, duration: Time(60, 1))) { _ in }
        }
        try await Task.sleep(for: .milliseconds(800))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    /// W9.9: a proxy swap must not move edit points. Every proxy frame sits at the source frame's presentation time
    /// (NTSC rate, non-zero start), and the frame count is the same (no media needed).
    @Test(arguments: [ProxyKind.proxyHalf, .proxyQuarter])
    func proxyKeepsEveryFrameTime(kind: ProxyKind) async throws {
        var spec = TestClipSpec(); spec.width = 512; spec.height = 288; spec.frameCount = 45
        spec.frameDuration = TestClipSpec.fps(30000, 1001); spec.startOffset = CMTime(value: 3003, timescale: 30000)
        let src = try await TestClipWriter.write(spec)
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("p.mov")
        _ = try await ProxyTranscoder().transcode(source: src, kind: kind, destination: out, timeRange: nil) { _ in }
        let a = try await probe(src), b = try await probe(out)
        #expect(b.frames == a.frames)
        #expect(b.pts == a.pts)
        #expect(b.width == 512 / kind.scaleDivisor && b.height == 288 / kind.scaleDivisor)
    }
}
