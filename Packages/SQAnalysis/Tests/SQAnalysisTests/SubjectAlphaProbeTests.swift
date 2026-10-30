import CoreVideo
import Foundation
import SQCore
import Testing
@testable import SQAnalysis

/// Measurement only (`SQ_MASK_ALPHA_PROBE=<out file>` with `SQ_SUBJECT_MASK_MODELS`): per-pixel alpha inside the
/// model's mask after every stage (the edge steps as the leg's edger runs them), on the bench clips with a white phone
/// painted into the hand.
extension VisionSuites {
    @Suite(.serialized, .enabled(if: HeldObjectMedia.models != nil && ProcessInfo.processInfo.environment["SQ_MASK_ALPHA_PROBE"] != nil))
    struct SubjectAlphaProbeTests {
        nonisolated(unsafe) static var out = ""
        static func log(_ s: String) { out += s + "\n" }

        /// Histogram of `m` over `where`: share < 0.1, 0.1-0.5, 0.5-0.9, 0.9-0.99, >= 0.99, and the mean.
        static func hist(_ m: SubjectMatte, _ inside: [Bool]) -> String {
            var b = [0, 0, 0, 0, 0], sum = 0.0, n = 0
            for i in inside.indices where inside[i] {
                let v = m.values[i]; sum += Double(v); n += 1
                b[v < 0.1 ? 0 : v < 0.5 ? 1 : v < 0.9 ? 2 : v < 0.99 ? 3 : 4] += 1
            }
            let s = b.map { String(format: "%.3f", Double($0) / Double(max(n, 1))) }.joined(separator: " ")
            return String(format: "[%@] mean %.3f n %d", s, sum / Double(max(n, 1)), n)
        }

        /// Pixels of `m` >= 0.5 at least `r` px from its edge.
        static func interior(_ m: SubjectMatte, r: Int) throws -> [Bool] {
            let bin = m.values.map { $0 >= 0.5 ? Float(1) : 0 }
            let near = try SubjectMatteRefiner.box(bin, m.width, m.height, r)
            return near.map { $0 > 0.999 }
        }

        static func rectMask(_ r: (x0: Int, y0: Int, x1: Int, y1: Int), _ w: Int, _ h: Int) -> [Bool] {
            var out = [Bool](repeating: false, count: w * h)
            for y in (r.y0 + 2)..<(r.y1 - 2) { for x in (r.x0 + 2)..<(r.x1 - 2) { out[y * w + x] = true } }
            return out
        }

        static func paintWhite(_ pb: CVPixelBuffer, _ r: (x0: Int, y0: Int, x1: Int, y1: Int)) {
            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pb)
            let rim = max(2, (r.x1 - r.x0) / 12)
            for y in r.y0..<r.y1 {
                for x in r.x0..<r.x1 {
                    let edge = x - r.x0 < rim || r.x1 - 1 - x < rim || y - r.y0 < rim || r.y1 - 1 - y < rim
                    let p = base + y * row + x * 4
                    let v: UInt8 = edge ? 205 : 245
                    p[0] = v; p[1] = v; p[2] = v; p[3] = 255
                }
            }
        }

        @Test func probe() async throws {
            let engine = MaskBenchmarkTests.engine(try #require(HeldObjectMedia.models))
            engine.prewarm()
            for _ in 0..<60_000 where engine.status == .warming { try await Task.sleep(for: .milliseconds(5)) }
            try #require(engine.status == .ready)
            for clip in HeldObjectMedia.clips {
                let pb = try await SubjectHeldObjectModelTests.firstFrame(clip.video)
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                let labelURL = try #require(clip.labels[0])
                let truth = try #require(MaskBenchmarkTests.label(labelURL, width: w, height: h))
                let rect = try SubjectHeldObjectModelTests.paint(.phone, on: pb, truth: truth)
                Self.paintWhite(pb, rect)
                let phone = Self.rectMask(rect, w, h)
                let truthIn = try Self.interior(SubjectMatte(width: w, height: h, values: truth), r: 6)
                Self.log("== \(clip.name) \(w)x\(h)")
                // Single click on the person.
                do {
                    let lease = try #require(engine.lease())
                    let leg = try #require(SubjectTrackLeg(lease: lease, segmenter: VisionInstanceSegmenter()))
                    leg.defersEdges = true; leg.recordsDiagnostics = true
                    let points = [MagicPoint(position: clip.click, subtract: false, sourceTime: Time(0, 600))]
                    guard case .found(let raw) = try leg.step(pb, pts: 0, gap: 1.0 / 30, points: points, stored: { nil }) else { continue }
                    let inner = try Self.interior(raw, r: 6)
                    let speed = SubjectMatteCore.solid(SubjectMatteEdges.refine(raw, guide: pb), mask: raw)
                    let quality = SubjectMatteCore.solid(SubjectMatteRefiner.refine(raw, guide: pb) ?? raw, mask: raw)
                    for (name, m) in [("raw", raw), ("speed", speed), ("quality", quality)] {
                        Self.log("pick \(name): model-interior \(Self.hist(m, inner)) | truth-interior \(Self.hist(m, truthIn)) | phone \(Self.hist(m, phone))")
                    }
                    // Tracked frames on the same picture.
                    for k in 1...3 {
                        guard case .found(let t) = try leg.step(pb, pts: Double(k) / 30, gap: 1.0 / 30, points: points, stored: { nil }) else { Self.log("track \(k) lost"); continue }
                        let q = SubjectMatteCore.solid(SubjectMatteRefiner.refine(t, guide: pb) ?? t, mask: t)
                        Self.log("track \(k) raw: interior \(Self.hist(t, try Self.interior(t, r: 6))) phone \(Self.hist(t, phone)) | q phone \(Self.hist(q, phone))")
                    }
                }
                // Person click plus an add click on the phone (one pick of two points).
                do {
                    let center = Vec2((Double(rect.x0 + rect.x1) / 2) / Double(w), (Double(rect.y0 + rect.y1) / 2) / Double(h))
                    let points = [MagicPoint(position: clip.click, subtract: false, sourceTime: Time(0, 600)),
                                  MagicPoint(position: center, subtract: false, sourceTime: Time(0, 600))]
                    let frame = try VisionInstanceSegmenter().segment(pb)
                    let seen = frame.flatMap { MagicMaskTracker.pickMatte($0, pts: 0, points: points) }
                    if let f = frame { Self.log("vision label at phone \(f.labels.label(at: center)), at person \(f.labels.label(at: clip.click))") }
                    guard let seen else { Self.log("add: vision nothing"); continue }
                    let seenFull = seen.width == w ? seen : seen.resampled(width: w, height: h)
                    Self.log("add vision pick \(seen.width)x\(seen.height): phone \(Self.hist(seenFull, phone)) | truth-interior \(Self.hist(seenFull, truthIn))")
                    let lease = try #require(engine.lease())
                    let leg = try #require(SubjectTrackLeg(lease: lease, segmenter: VisionInstanceSegmenter()))
                    leg.defersEdges = true
                    guard case .found(let first) = try leg.step(pb, pts: 0, gap: 1.0 / 30, points: points, stored: { seen }) else { Self.log("add: no start"); continue }
                    let ff = first.width == w ? first : first.resampled(width: w, height: h)
                    Self.log("add leg start: phone \(Self.hist(ff, phone))")
                    for k in 1...3 {
                        guard case .found(let t) = try leg.step(pb, pts: Double(k) / 30, gap: 1.0 / 30, points: points, stored: { nil }) else { Self.log("add track \(k) lost"); continue }
                        let q = SubjectMatteCore.solid(SubjectMatteRefiner.refine(t, guide: pb) ?? t, mask: t)
                        Self.log("add track \(k) raw: phone \(Self.hist(t, phone)) | q phone \(Self.hist(q, phone)) | truth-interior q \(Self.hist(q, truthIn))")
                    }
                }
            }
            try Self.out.write(toFile: ProcessInfo.processInfo.environment["SQ_MASK_ALPHA_PROBE"]!, atomically: true, encoding: .utf8)
        }
    }
}
