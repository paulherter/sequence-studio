import Testing
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
@testable import SQExport

/// W9.4 review: chroma siting of the YUV output passes, 16-bit quantization for ProRes 4444, seams of segmented
/// HEVC Main 10 exports.
@Suite(.serialized) struct ExportChromaSegmentSeamTests {
    /// Luma columns 0...64 red, 65... blue (an edge on an odd column, so co-sited and centered siting differ).
    struct EdgeProvider: FrameProvider {
        let width = 128, height = 64, edge = 65
        func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
            var pb: CVPixelBuffer?
            let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                          kCVPixelBufferMetalCompatibilityKey: true]
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let p = base + y * CVPixelBufferGetBytesPerRow(buf) + x * 4
                let red = x < edge
                p[0] = red ? 0 : 255; p[1] = 0; p[2] = red ? 255 : 0; p[3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            let info = VideoTrackInfo(width: width, height: height, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                      nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
            return ProvidedFrame(buffer: buf, info: info)
        }
    }

    static let mediaID = UUID()
    static func timeline() -> Timeline {
        let c = Clip(name: "edge", media: mediaID, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        return Timeline(name: "t", format: SequenceFormat(width: 128, height: 64, frameDuration: Time(1, 30)),
                        tracks: [Track(kind: .video, clips: [c])])
    }

    static func source(_ pf: ExportPixelFormat, frames: Int = 1) throws -> TimelineFrameSource {
        try TimelineFrameSource(timeline: timeline(), provider: EdgeProvider(), width: 128, height: 64, frameDuration: Time(1, 30),
                                frameCount: frames, pixelFormat: pf, makeProvider: { EdgeProvider() })
    }

    /// Cr code of chroma texel (cx, cy): 8-bit for '420v', 10-bit (high bits of 16) for 'x420' / 'x422'.
    static func crCode(_ pb: CVPixelBuffer, cx: Int, cy: Int) -> Int {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let row = CVPixelBufferGetBaseAddressOfPlane(pb, 1)! + cy * CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            return Int(row.assumingMemoryBound(to: UInt8.self)[cx * 2 + 1])
        }
        return Int(row.assumingMemoryBound(to: UInt16.self)[cx * 2 + 1] >> 6)
    }

    @Test(.serialized, arguments: [ExportPixelFormat.yuv420v, .yuv420v10, .yuv422v10])
    func chromaIsCoSitedWithEvenLumaColumns(_ pf: ExportPixelFormat) async throws {
        let pb = try await Self.source(pf).frame(at: 0)
        let tenBit = pf != .yuv420v
        func expected(redWeight w: Double) -> Int {
            let cr = w * (1 - 0.2126) / 1.5748 + (1 - w) * (-0.0722 / 1.5748)
            return Int((tenBit ? 512 + 896 * cr : 128 + 224 * cr).rounded())
        }
        let tol = tenBit ? 6 : 2
        // Chroma 32 sits on luma column 64: taps 63, 64 (red) and 65 (blue) -> 3/4 red. A box average of 64/65 gives 1/2.
        let got = (31...33).map { Self.crCode(pb, cx: $0, cy: 8) }
        let want = [expected(redWeight: 1), expected(redWeight: 0.75), expected(redWeight: 0)]
        for (g, w) in zip(got, want) { #expect(abs(g - w) <= tol, "\(pf): got \(got), want \(want)") }
        // Tagged so decoders reconstruct from the same siting.
        ExportWriter.tagRec709(pb)
        #expect(CVBufferCopyAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
                == kCVImageBufferChromaLocation_Left as String)
    }

    @Test func proRes4444SourceUsesSixteenBitCodes() async throws {
        let pb = try await Self.source(.ayuv4444).frame(at: 0)
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let row = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt16.self)
        let red = Array(UnsafeBufferPointer(start: row + 10 * 4, count: 4))   // pixel x = 10, row 0: (A, Y, Cb, Cr)
        #expect(red[0] == 65535)
        // Pure red: Y' = 0.2126, Cb = -0.2126/1.8556, Cr = 0.5 on the 16-bit video-range scale.
        #expect(abs(Int(red[1]) - Int((4096 + 56064 * 0.2126).rounded())) <= 64)
        #expect(abs(Int(red[2]) - Int((32768 - 57344 * 0.2126 / 1.8556).rounded())) <= 64)
        #expect(abs(Int(red[3]) - Int(32768 + 57344 * 0.5)) <= 64)
        // Not a 10-bit code shifted up: the low 6 bits carry precision.
        #expect(red[1...3].contains { $0 % 64 != 0 })
    }

    @Test func segmentedHevcMain10KeepsDecodeTimesIncreasingAcrossSeams() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("h10.mp4")
        var s = ExportSettings()
        s.video.codec = .hevc; s.video.profile = .main10
        s.video.width = 128; s.video.height = 64; s.video.frameDuration = Time(1, 30)
        s.video.bitrate = .average(1_000_000); s.video.keyframeInterval = 15
        s.audio.enabled = false
        let src = try Self.source(s.sourcePixelFormat, frames: 75)
        #expect(src.pixelFormat == .yuv420v10)
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, segments: 3, progress: { _ in })
        let e = try await readEncoded(url)
        let pd = try #require(hevcProfileAndDepth(e.format))
        #expect(pd.profile == 2 && pd.bitDepth == 10)
        #expect(e.times.count == 75)
        let pts = e.times.map { Int(($0.pts.seconds * 30).rounded()) }.sorted()
        #expect(pts == Array(pts[0]..<(pts[0] + 75)))
        let dts = e.times.map(\.dts)
        #expect(dts.allSatisfy { $0.isValid })
        #expect(zip(dts, dts.dropFirst()).allSatisfy { $0 < $1 }, "decode times must increase across seams")
        // (The file may present a sample before its stored decode time: MP4 negative composition offsets.)
        // Segment scratch folder lived next to the output and is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["h10.mp4"])
    }

    @Test func seamClampMovesEarlyDecodeTimesJustAfterThePreviousOne() throws {
        func t(_ v: Int64) -> CMTime { CMTime(value: v, timescale: 30) }
        // Previous segment ended decoding at frame 30; the next one starts with a two-frame reorder delay.
        var last = t(30)
        var timing = [CMSampleTimingInfo(duration: t(1), presentationTimeStamp: t(31), decodeTimeStamp: t(29)),
                      CMSampleTimingInfo(duration: t(1), presentationTimeStamp: t(34), decodeTimeStamp: t(30)),
                      CMSampleTimingInfo(duration: t(1), presentationTimeStamp: t(32), decodeTimeStamp: t(31))]
        try ExportWriter.clampDecodeTimes(&timing, after: &last)
        let d = timing.map(\.decodeTimeStamp)
        #expect(d[0] > t(30) && d[0] < t(31))
        #expect(d[1] > d[0] && d[1] < t(31))
        #expect(d[2] == t(31))
        #expect(timing.allSatisfy { $0.decodeTimeStamp <= $0.presentationTimeStamp })
        #expect(last == t(31))
        // A sample shown before it could be decoded after the seam cannot be re-timed.
        var bad = [CMSampleTimingInfo(duration: t(1), presentationTimeStamp: t(30), decodeTimeStamp: t(29))]
        var last2 = t(30)
        #expect(throws: ExportError.self) { try ExportWriter.clampDecodeTimes(&bad, after: &last2) }
    }

    @Test func proResScratchEstimateFollowsPixelRate() {
        var s = ExportSettings.proRes422HQMaster
        s.video.width = 1920; s.video.height = 1080; s.video.frameDuration = Time(1001, 30000)
        // ~30 s of ProRes 422 HQ 1080p29.97 is about 0.8 GB (Apple: 220 Mbit/s).
        let b = ExportWriter.estimatedVideoBytes(settings: s, frames: 899)
        #expect(b > 700_000_000 && b < 900_000_000)
    }
}
