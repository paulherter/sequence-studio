import Testing
import Foundation
import CoreVideo
import Metal
import SQCore
import SQText
import SQTranscribe
@testable import SQExport

/// Solid-colour BGRA frames per media id; nil for unknown ids (offline).
struct SolidProvider: FrameProvider {
    var colors: [UUID: (b: UInt8, g: UInt8, r: UInt8)]
    var width: Int, height: Int

    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        guard let c = colors[media] else { return nil }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                      kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height { for x in 0..<width {
            let p = base + y * stride + x * 4
            p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        let info = VideoTrackInfo(width: width, height: height, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        return ProvidedFrame(buffer: buf, info: info)
    }
}

private func bgra(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let p = base + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
    return (Int(p[0]), Int(p[1]), Int(p[2]))
}

private func tag(_ pb: CVPixelBuffer, _ k: CFString) -> String? { CVBufferCopyAttachment(pb, k, nil) as? String }

private let fd = Time(1, 30)
private let redID = UUID(), greenID = UUID()

private func twoLayerTimeline() -> Timeline {
    let src = TimeRange(start: .zero, duration: Time(2, 1))
    let bottom = Clip(name: "red", media: redID, kind: .video, source: src, start: .zero)
    var top = Clip(name: "green", media: greenID, kind: .video, source: src, start: .zero)
    top.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
    return Timeline(name: "t", format: SequenceFormat(width: 128, height: 64, frameDuration: fd),
                    tracks: [Track(kind: .video, clips: [bottom]), Track(kind: .video, clips: [top])])
}

private let solids = SolidProvider(colors: [redID: (0, 0, 255), greenID: (0, 255, 0)], width: 128, height: 64)

@Suite struct TimelineFrameSourceTests {
    @Test func twoLayersCompositeBottomToTop() async throws {
        let src = try TimelineFrameSource(timeline: twoLayerTimeline(), provider: solids, width: 128, height: 64,
                                          frameDuration: fd, frameCount: 10)
        let pb = try await src.frame(at: 3)
        #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA)
        let corner = bgra(pb, 4, 4), center = bgra(pb, 64, 32)
        #expect(abs(corner.r - 255) <= 3 && corner.g <= 3 && corner.b <= 3)
        #expect(center.r <= 3 && abs(center.g - 255) <= 3 && center.b <= 3)
        // Half-scale top layer: 64x32 centred, so x=40 is inside, x=20 is outside.
        #expect(bgra(pb, 40, 32).g > 250)
        #expect(bgra(pb, 20, 32).r > 250)
    }

    @Test func outputCarriesRec709Tags() async throws {
        let src = try TimelineFrameSource(timeline: twoLayerTimeline(), provider: solids, width: 128, height: 64,
                                          frameDuration: fd, frameCount: 2)
        let pb = try await src.frame(at: 0)
        let p = tag(pb, kCVImageBufferColorPrimariesKey), t = tag(pb, kCVImageBufferTransferFunctionKey)
        let m = tag(pb, kCVImageBufferYCbCrMatrixKey)
        #expect(p == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String))
        #expect(t == (kCVImageBufferTransferFunction_ITU_R_709_2 as String))
        #expect(m == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String))
    }

    @Test func offlineMediaDrawsPlaceholder() async throws {
        let empty = SolidProvider(colors: [:], width: 128, height: 64)
        let src = try TimelineFrameSource(timeline: twoLayerTimeline(), provider: empty, width: 128, height: 64,
                                          frameDuration: fd, frameCount: 1)
        let c = bgra(try await src.frame(at: 0), 4, 4)
        #expect(c.r > c.g && c.r > c.b && c.r > 50)   // offline = dark red
    }

    @Test func yuv420vOutput() async throws {
        let src = try TimelineFrameSource(timeline: twoLayerTimeline(), provider: solids, width: 128, height: 64,
                                          frameDuration: fd, frameCount: 1, pixelFormat: .yuv420v)
        let pb = try await src.frame(at: 0)
        #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        // Corner = red: Y' = 16 + 219*0.2126 = 62.6, Cb < 128, Cr = 240.
        #expect(abs(Int(y[4 * ys + 4]) - 63) <= 2)
        #expect(Int(c[2 * cs + 4]) < 120 && abs(Int(c[2 * cs + 5]) - 240) <= 2)
        // Centre = green: Y' = 16 + 219*0.7152 = 172.6.
        #expect(abs(Int(y[32 * ys + 64]) - 173) <= 2)
        let m = tag(pb, kCVImageBufferYCbCrMatrixKey)
        #expect(m == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String))
    }

    @Test func cancellationIsHonoured() async throws {
        let src = try TimelineFrameSource(timeline: twoLayerTimeline(), provider: solids, width: 128, height: 64,
                                          frameDuration: fd, frameCount: 4)
        let task = Task { try await Task.sleep(for: .seconds(5)); _ = try await src.frame(at: 0) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func indexOutOfRangeThrows() async throws {
        let src = try TimelineFrameSource(timeline: twoLayerTimeline(), provider: solids, width: 128, height: 64,
                                          frameDuration: fd, frameCount: 2)
        await #expect(throws: FrameSourceError.self) { _ = try await src.frame(at: 2) }
    }

    @Test func oddSizeRejectedFor420() {
        #expect(throws: TimelineFrameSourceError.oddDimensionsFor420) {
            _ = try TimelineFrameSource(timeline: twoLayerTimeline(), provider: solids, width: 127, height: 64,
                                        frameDuration: fd, frameCount: 1, pixelFormat: .yuv420v)
        }
    }
}

@Suite struct CaptionBurnInTests {
    private func captions(animation: String = "none") -> [Caption] {
        let t = Transcript(language: "en-US", words: [
            TranscriptWord(text: "Hello", range: TimeRange(start: Time(1, 1), end: Time(2, 1)))])
        var p = CaptionPreset.standard
        p.animationRef = animation
        return CaptionSegmenter.segment(t, preset: p)
    }

    @Test func stateOnlyInsideRangeAndAnimated() {
        let b = CaptionBurnIn(captions: captions(animation: "fade"), library: .builtIn)
        #expect(b.state(at: Time(1, 2)) == nil)
        #expect(b.state(at: Time(2, 1)) == nil)              // end exclusive
        #expect(b.state(at: Time(1, 1))?.opacity == 0)       // fade-in starts at 0
        #expect(b.state(at: Time(6, 5))?.opacity == 1)       // 0.2 s later fully in
        let mid = b.state(at: Time(11, 10))!.opacity
        #expect(mid > 0.4 && mid < 0.6)
        let pop = CaptionBurnIn(captions: captions(animation: "pop-in"), library: .builtIn)
        #expect(abs(pop.state(at: Time(1, 1))!.scale - 0.8) < 1e-9)
    }

    @Test func captionPixelsOnlyWithinRange() async throws {
        let tl = Timeline(name: "c", format: SequenceFormat(width: 320, height: 180, frameDuration: fd), tracks: [])
        let burn = CaptionBurnIn(captions: captions(), library: .builtIn)
        let src = try TimelineFrameSource(timeline: tl, provider: solids, width: 320, height: 180,
                                          frameDuration: fd, frameCount: 90, captions: burn)
        func brightPixels(_ pb: CVPixelBuffer, rows: Range<Int>) -> Int {
            var n = 0
            for y in rows { for x in 0..<320 where bgra(pb, x, y).g > 128 { n += 1 } }
            return n
        }
        let before = try await src.frame(at: 15)   // 0.5 s
        let during = try await src.frame(at: 45)   // 1.5 s
        let after = try await src.frame(at: 75)    // 2.5 s
        #expect(brightPixels(before, rows: 0..<180) == 0)
        #expect(brightPixels(after, rows: 0..<180) == 0)
        #expect(brightPixels(during, rows: 90..<180) > 50)
        #expect(brightPixels(during, rows: 0..<90) == 0)   // bottom placement
    }

    @Test func fadeScalesOpacityInOutput() async throws {
        let tl = Timeline(name: "c", format: SequenceFormat(width: 320, height: 180, frameDuration: fd), tracks: [])
        let burn = CaptionBurnIn(captions: captions(animation: "fade"), library: .builtIn)
        let src = try TimelineFrameSource(timeline: tl, provider: solids, width: 320, height: 180,
                                          frameDuration: fd, frameCount: 90, captions: burn)
        func peak(_ pb: CVPixelBuffer) -> Int {
            var m = 0
            for y in 90..<180 { for x in 0..<320 { m = max(m, bgra(pb, x, y).g) } }
            return m
        }
        let start = try await src.frame(at: 30)    // opacity 0
        let half = try await src.frame(at: 33)     // 0.1 s -> 0.5
        let full = try await src.frame(at: 45)
        #expect(peak(start) == 0)
        #expect(peak(half) > 40 && peak(half) < peak(full))
    }
}
