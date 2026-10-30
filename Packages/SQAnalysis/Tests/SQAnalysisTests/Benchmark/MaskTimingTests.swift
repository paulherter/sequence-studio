import Foundation
import SQCore
import Testing
@testable import SQAnalysis

/// The app's subject mask path end to end, timed: the tool is chosen (prewarm), a frame is segmented (hover), clicked
/// (pick) and tracked for `SQ_MASK_TIMING_SECONDS` (default 2) with the real model, first on a cold engine, then again
/// on the warm one. With `SQ_MASK_TIMING=1` every stage is logged (`SubjectMaskTiming`).
///
/// Opt-in: `SQ_MASK_TIMING_BENCH=1 SQ_MASK_TIMING=1 SQ_SUBJECT_MASK_MODELS=<parts> SQ_TEST_FILTER=MaskTiming
/// scripts/test.sh SQAnalysis`. `SQ_MASK_TIMING_CLIP` (default the bench's walking clip) and `SQ_MASK_TIMING_POINT`
/// ("x,y" as frame fractions) choose the footage.
extension VisionSuites {
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["SQ_MASK_TIMING_BENCH"] == "1"))
    struct MaskTimingTests {
        static let env = ProcessInfo.processInfo.environment

        static func seconds(since began: ContinuousClock.Instant) -> Double {
            let d = ContinuousClock.now - began
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }

        @Test func pickAndTrackTwoSeconds() async throws {
            let models = try #require(Self.env[SubjectMaskLocator.environmentKey], "SQ_SUBJECT_MASK_MODELS is not set")
            let clip = URL(fileURLWithPath: Self.env["SQ_MASK_TIMING_CLIP"]
                ?? MaskBenchmarkTests.root.appendingPathComponent("walking/clip.mp4").path)
            let xy = (Self.env["SQ_MASK_TIMING_POINT"] ?? "0.6329,0.6656").split(separator: ",").compactMap { Double($0) }
            let click = Vec2(xy.first ?? 0.5, xy.last ?? 0.5)
            let length = Double(Self.env["SQ_MASK_TIMING_SECONDS"] ?? "") ?? 2
            let qualities: [SubjectMaskQuality] = Self.env["SQ_MASK_TIMING_QUALITY"].flatMap(SubjectMaskQuality.init(rawValue:)).map { [$0] }
                ?? [.quality, .speed]
            let engine = MaskBenchmarkTests.engine(models)
            var lines: [String] = []
            // Without the model (`vision`): what the app does when it finds no model parts.
            var passes = qualities.flatMap { q in (q == qualities[0] ? ["cold", "warm"] : ["warm"]).map { ($0, q) } }
            if Self.env["SQ_MASK_TIMING_VISION"] != "0" { passes.append(("vision", .speed)) }
            for (pass, quality) in passes {
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sq-mask-timing-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let store = MagicMatteStore(directory: directory)
                    // engine nil with the system's segmenter: the app's engine, which finds no models in a test run.
                    var tracker = MagicMaskTracker(url: clip, segmenter: VisionInstanceSegmenter(), engine: pass == "vision" ? nil : engine)
                    tracker.decide(quality)
                    let began = ContinuousClock.now
                    if pass != "vision" { engine.prewarm() }   // the tool is chosen
                    let seen = try #require(try await tracker.segment(at: 0), "nothing segmented on the first frame")
                    let segmented = Self.seconds(since: began)
                    let points = [MagicPoint(position: click, subtract: false, sourceTime: MaskBenchmarkTests.time(seen.pts))]
                    #expect(MagicMaskTracker.pick(seen.frame, pts: seen.pts, key: "m", points: points, store: store))
                    let picked = Self.seconds(since: began)
                    let tracked = ContinuousClock.now
                    let result = try await tracker.track(key: "m", points: points, from: seen.pts, to: seen.pts + length, store: store)
                    let track = Self.seconds(since: tracked)
                    let line = String(format: "%@ %@: segment %.2f s, pick %.2f s, track %.2f s (%d frames, %.0f ms/frame), total %.2f s",
                                      pass, quality.rawValue, segmented, picked - segmented, track, result.frames,
                                      track * 1000 / Double(max(result.frames, 1)), Self.seconds(since: began))
                    print("[MaskTiming] \(line)")
                    lines.append(line)
                    #expect(result.frames > 0)
                }
            }
            print("[MaskTiming] summary (\(clip.lastPathComponent)):\n" + lines.joined(separator: "\n"))
        }
    }
}
