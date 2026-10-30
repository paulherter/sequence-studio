import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import SQCore
import Testing
@testable import SQAnalysis

extension VisionSuites {
/// Vision mask tracker: coordinate conversion, frame picking, and a real run on a written movie with a moving patch.
@Suite struct MaskTrackerTests {
    @Test func visionRectRoundTripsAndClips() throws {
        let b = MaskTrackBox(center: Vec2(0.3, 0.2), size: Vec2(0.2, 0.1))
        let r = try #require(VisionMaskTracker.visionRect(b))
        #expect(abs(r.minY - 0.75) < 1e-9 && abs(r.minX - 0.2) < 1e-9)
        let back = VisionMaskTracker.box(r)
        #expect((back.center - b.center).length < 1e-9 && (back.size - b.size).length < 1e-9)
        let half = try #require(VisionMaskTracker.visionRect(MaskTrackBox(center: Vec2(0, 0.5), size: Vec2(0.2, 0.2))))
        #expect(abs(half.width - 0.1) < 1e-9)
        #expect(VisionMaskTracker.visionRect(MaskTrackBox(center: Vec2(2, 2), size: Vec2(0.1, 0.1))) == nil)
    }

    @Test func motionsPickTheFrameShownAtEachInstant() {
        let a = MaskMotion.identity
        let b = MaskMotion(translation: Vec2(0.1, 0))
        let frames: [(pts: Double, motion: MaskMotion?)] = [(0, a), (0.04, b), (0.08, nil)]
        let got = VisionMaskTracker.motions(at: [0, 0.02, 0.04, 0.1, -1], from: frames)
        #expect(got[0] == a && got[1] == a && got[2] == b && got[3] == nil && got[4] == a)
    }

    /// 24 frames at 24 fps, 320 x 180: a textured 40 px patch moves 4 px right per frame over a flat gray picture.
    /// `firstPTS`: presentation time of frame 0; > 0 writes an empty edit before it (the first frame starts after 0).
    /// `hold`: frame `frame` stays on screen `seconds` longer (every later frame comes that much later).
    /// `patchTop`: the patch's top edge in stored rows from the top (70 = centered); `transform`: the track's
    /// preferred transform (a file shot turned).
    func writeMovie(firstPTS: CMTime = .zero, hold: (frame: Int, seconds: Double)? = nil, patchTop: Int = 70,
                    transform: CGAffineTransform = .identity) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-masktrack-\(UUID().uuidString).mov")
        let w = 320, h = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<24 {
            // At most 20 s per frame: a writer that never gets ready fails the test instead of hanging the run.
            var waited = 0
            while !input.isReadyForMoreMediaData {
                waited += 1
                if waited > 4000 || writer.status == .failed {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            let b = try #require(pb)
            CVPixelBufferLockBaseAddress(b, [])
            let ctx = try #require(CGContext(data: CVPixelBufferGetBaseAddress(b), width: w, height: h, bitsPerComponent: 8,
                                             bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            ctx.setFillColor(gray: 0.4, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let x = 60 + 4 * i, y = h - 40 - patchTop        // the context's y runs up
            for cy in 0..<4 { for cx in 0..<4 {
                ctx.setFillColor(gray: (cx + cy) % 2 == 0 ? 1 : 0, alpha: 1)
                ctx.fill(CGRect(x: x + cx * 10, y: y + cy * 10, width: 10, height: 10))
            } }
            CVPixelBufferUnlockBaseAddress(b, [])
            var t = CMTimeAdd(firstPTS, CMTime(value: CMTimeValue(i), timescale: 24))
            if let hold, i > hold.frame { t = CMTimeAdd(t, CMTime(seconds: hold.seconds, preferredTimescale: 600)) }
            adaptor.append(b, withPresentationTime: t)
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    @Test func tracksAMovingPatchForwardAndBackward() async throws {
        let url = try await writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        // The patch at frame 0: x 60...100 px of 320, y (CG y up) 70...110 of 180 -> y down 70...110 too (symmetric).
        func square(_ cx: Double) -> [Vec2] {
            [Vec2(cx - 20, 70), Vec2(cx + 20, 70), Vec2(cx + 20, 110), Vec2(cx - 20, 110)].map { Vec2($0.x / 320, $0.y / 180) }
        }
        let center = Vec2(80.0 / 320, 90.0 / 180)
        let times = (0..<12).map { Time(Int64($0), 24) }
        for (mode, chunk) in [(MaskTrackMode.scale, 1.0), (.rotation, 0.5)] {
            let tracker = VisionMaskTracker(url: url, maxDimension: 640, chunkSeconds: chunk)
            let fwd = try await tracker.track(region: square(80), mode: mode, sourceTimes: times, progress: nil)
            #expect(fwd.count == 12)
            let last = try #require(fwd[11]).apply(center)
            #expect(abs(last.x * 320 - (80 + 44)) < 6, "\(mode)")      // moved 11 x 4 px right
            #expect(abs(last.y * 180 - 90) < 6, "\(mode)")

            let back = try await tracker.track(region: square(160), mode: mode,
                                               sourceTimes: (0...20).reversed().map { Time(Int64($0), 24) }, progress: nil)
            let first = try #require(back.last ?? nil).apply(Vec2(160.0 / 320, 90.0 / 180))
            #expect(abs(first.x * 320 - 80) < 6, "\(mode)")              // back at the start position
        }
    }
}
}
