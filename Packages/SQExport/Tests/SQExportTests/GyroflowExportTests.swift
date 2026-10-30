import CoreVideo
import Foundation
import Metal
import Synchronization
import Testing
import SQAnalysis
import SQCore
import SQMedia
@testable import SQExport

// Gyroflow Stabilizer in export (docs/GYROFLOW.md step 5): the decoded frame goes through the engine's warp first,
// waiting for the analysis, with the frame's time in the file; the warped picture is what gets exported.

private let fd = Time(1, 30)

private func solid(_ v: UInt8, _ w: Int = 64, _ h: Int = 36) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                         kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h { for x in 0..<w { let p = base + y * CVPixelBufferGetBytesPerRow(pb!) + x * 4; p[0] = v; p[1] = v; p[2] = v; p[3] = 255 } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

/// Video frames of one gray level, frame starts on the 1/30 grid.
private struct GreyProvider: FrameProvider {
    func frame(media: UUID, at t: Time) async throws -> ProvidedFrame? {
        let start = Time(reducing: Int128(t.value) * 30 / Int128(t.timescale), 30)
        return ProvidedFrame(buffer: solid(40), info: VideoTrackInfo(width: 64, height: 36, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                                               nominalFrameDuration: fd, isVariableFrameRate: false, rotation: 0),
                             start: start, duration: fd)
    }
}

/// Records each warp and returns a white frame.
private final class FakeGyroEngine: GyroStabilizationEngine, @unchecked Sendable {
    struct Call: Equatable { let path: String; let options: GyroflowOptions; let ts: Int64; let wait: Bool }
    let calls = Mutex<[Call]>([])
    var availability: GyroEngineAvailability { .available }
    func warp(_ frame: CVPixelBuffer, path: String, options: GyroflowOptions, timestampUS: Int64, wait: Bool) -> CVPixelBuffer? {
        calls.withLock { $0.append(Call(path: path, options: options, ts: timestampUS, wait: wait)) }
        return solid(230)
    }
}

private func gyroClip(media: UUID, sourceStart: Time) throws -> Clip {
    var e = try #require(ClipEffect.make(kind: ClipEffect.stabilizeKind))
    e.parameters[ClipEffect.stabilizeMethodKey] = AnimatedProperty(Double(StabilizerMethod.gyroflow.rawValue))
    e.parameters[ClipEffect.gyroSmoothnessKey] = AnimatedProperty(70)
    return Clip(name: "v", media: media, kind: .video, source: TimeRange(start: sourceStart, duration: fd * 30), start: .zero, effects: [e])
}

private func centre(_ pb: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    return Int((b + 18 * CVPixelBufferGetBytesPerRow(pb) + 32 * 4)[1])
}

@Suite(.serialized) struct GyroflowExportTests {
    @Test func exportWarpsTheDecodedFrameWaitingWithItsFileTime() async throws {
        let media = UUID()
        let engine = FakeGyroEngine()
        let warper = GyroFrameWarper(engine: engine, path: { $0 == media ? "/clips/C2160.MP4" : nil })
        let clip = try gyroClip(media: media, sourceStart: fd * 45)
        let tl = Timeline(name: "t", format: SequenceFormat(width: 64, height: 36, frameDuration: fd), tracks: [Track(kind: .video, clips: [clip])])
        let s = try TimelineFrameSource(timeline: tl, provider: GreyProvider(), width: 64, height: 36, frameDuration: fd,
                                        frameCount: 3, gyroWarper: warper, renderAhead: false)
        let pb = try await s.frame(at: 2)
        #expect(centre(pb) > 200, "the warped (white) frame is exported, not the decoded gray")
        let calls = engine.calls.withLock { $0 }
        #expect(calls.last == .init(path: "/clips/C2160.MP4", options: clip.gyroflowOptions!, ts: 1_566_667, wait: true))  // 47/30 s
    }

    @Test func withoutAWarperOrStabilizerTheFrameIsDrawnAsDecoded() async throws {
        let media = UUID()
        var clip = try gyroClip(media: media, sourceStart: .zero)
        let tl0 = Timeline(name: "t", format: SequenceFormat(width: 64, height: 36, frameDuration: fd), tracks: [Track(kind: .video, clips: [clip])])
        let s0 = try TimelineFrameSource(timeline: tl0, provider: GreyProvider(), width: 64, height: 36, frameDuration: fd, frameCount: 1)
        #expect(centre(try await s0.frame(at: 0)) < 80)
        let engine = FakeGyroEngine()
        clip.effects = []
        let tl1 = Timeline(name: "t", format: SequenceFormat(width: 64, height: 36, frameDuration: fd), tracks: [Track(kind: .video, clips: [clip])])
        let s1 = try TimelineFrameSource(timeline: tl1, provider: GreyProvider(), width: 64, height: 36, frameDuration: fd, frameCount: 1,
                                         gyroWarper: GyroFrameWarper(engine: engine, path: { _ in "/x" }))
        #expect(centre(try await s1.frame(at: 0)) < 80)
        #expect(engine.calls.withLock { $0 }.isEmpty)
    }
}
