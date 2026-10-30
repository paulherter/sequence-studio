import CoreVideo
import Foundation
import SQCore
import Testing
@testable import SQExport

// Temporal filters (Trails, Denoise) in export read only frames inside the clip's source range, never material cut away.

private let fd = Time(1, 30)

/// Solid frames with their exact frame start and duration; records every source time asked for.
private final class FramedProvider: FrameProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [Time] = []
    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        lock.withLock { asked.append(sourceTime) }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let info = VideoTrackInfo(width: 32, height: 32, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: fd, isVariableFrameRate: false)
        let i = sourceTime.frameIndex(frameDuration: fd)
        return ProvidedFrame(buffer: pb!, info: info, start: fd * i, duration: fd, sampleIndex: Int(i))
    }
    var times: [Time] { lock.withLock { asked } }
}

@Suite struct TemporalSourceRangeExportTests {
    private func run(reversed: Bool, extra: String? = nil) async throws -> [Time] {
        let m = UUID()
        // Source 2 s ..< 3 s of a 10 s media.
        var c = Clip(name: "v", media: m, kind: .video, source: TimeRange(start: Time(2, 1), duration: Time(1, 1)), start: .zero,
                     mediaDuration: Time(10, 1), reversed: reversed)
        c.effects = [ClipEffect.make(kind: ClipEffect.trailsKind)!]
        if let extra { c.effects.append(ClipEffect.make(kind: extra)!) }
        let tl = Timeline(name: "t", format: SequenceFormat(width: 32, height: 32, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [c])])
        let p = FramedProvider()
        let src = try TimelineFrameSource(timeline: tl, provider: p, width: 32, height: 32, frameDuration: fd, frameCount: 30)
        for i in [0, 1, 15, 28, 29] { _ = try await src.frame(at: i) }
        return p.times
    }

    @Test func trailsAndDenoiseStayInsideTheSourceRange() async throws {
        for reversed in [false, true] {
            let times = try await run(reversed: reversed, extra: ClipEffect.videoDenoiseKind)
            #expect(!times.isEmpty)
            #expect(times.allSatisfy { $0 >= Time(2, 1) && $0 < Time(3, 1) }, "reversed \(reversed): \(times.filter { $0 < Time(2, 1) || $0 >= Time(3, 1) })")
        }
    }

    /// A reversed clip trails from the frames after the shown one (in source order): the ones already seen.
    @Test func reversedClipAsksForLaterSourceFrames() async throws {
        let fwd = try await run(reversed: false), back = try await run(reversed: true)
        // Forward, timeline frame 15 shows source frame 75: echoes at 73, 71, ... (spacing 2). Reversed, frame 15 shows 74:
        // echoes at 76, 78, ...
        #expect(fwd.contains(fd * 73) && !fwd.contains(fd * 77))
        #expect(back.contains(fd * 76) && back.contains(fd * 82))
    }
}
