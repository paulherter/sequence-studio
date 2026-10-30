import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SQCore
import Testing
@testable import SQAnalysis

/// Gate G0 of the mask tracking plan (docs/research/mask-tracking/REPORT.md section 5): J, F and J&F of the real EdgeTAM
/// path (`SubjectTrackLeg`, the leg the app tracks with) on labeled clips, with scripted prompts, per variant.
///
/// Opt-in: `SQ_MASK_BENCH=1 SQ_SUBJECT_MASK_MODELS=<folder with the model parts> scripts/test.sh SQAnalysis` with
/// `SQ_TEST_FILTER=MaskBenchmark`. Writes `build/mask-bench.md` (override: `SQ_MASK_BENCH_OUT`).
///
/// Clips live outside the repo, one folder each under `SQ_MASK_BENCH_DIR` (default `~/Documents/SequenceStudio/TestMedia/MaskBench`):
///   `<clip>/clip.(mp4|mov)`  the video
///   `<clip>/prompt.json`     `{"x": 0.5, "y": 0.4}`  the positive click on frame 0, as frame fractions
///   `<clip>/labels/<frame>.png`  ground truth, any name that is the frame index (`0.png`, `00010.png`, ...): white (> 127) is the subject
/// A clip folder missing any of these is skipped with a message. No tracker code is changed by this harness.
extension VisionSuites {
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["SQ_MASK_BENCH"] == "1"))
    struct MaskBenchmarkTests {
        enum Variant: String, CaseIterable {
            /// The app's path: person box and the system's segmentation as the gate on the click.
            case baseline
            /// The system's segmentation returns nothing: the click is answered by the model alone (no agreement gate).
            case visionGateOff = "vision gate off"
            /// Baseline plus scripted corrections: after the first labeled frame under `failIoU`, the ground-truth mask is
            /// given as the stored matte (what drawn strokes become today) at the next labeled frames, `correctionGap` apart.
            case strokesAsPrompts = "strokes as prompts"
            /// Baseline plus one extra positive click at the middle labeled frame, taken from the ground-truth mask's eroded
            /// interior and answered the way the app answers a click on a tracked frame (the system's pick, corrected on the
            /// tracked matte, stored for that frame). Scenario of docs/research/mask-tracking/BENCH-MIDCLIP.md.
            case midClipClick = "mid-clip click"
            /// Baseline plus one click where the tracked mask is wrong at the middle labeled frame: positive at the deepest
            /// part of the subject the previous answer misses, else negative at the deepest part it covers wrongly
            /// (no click when both errors are under 0.5% of the frame). Answered like the mid-clip click.
            case midClipFix = "mid-clip fix"
            /// Baseline with `occlusionLength` frames in the middle replaced by a gray rectangle over the subject.
            case occlusionBox = "occlusion box"
            /// Baseline with `occlusionLength` frames in the middle replaced by a flat gray picture.
            case occlusionBlank = "occlusion blank"
            /// The subject leaves the frame and comes back: over the `occlusionLength` frames in the middle the picture (and
            /// the ground truth) slides sideways until the subject is out (first third), stays out, and slides back (last
            /// third). Gray fills what slides in. Scenario of docs/research/mask-tracking/BENCH-RECOVERY.md.
            case exitReturn = "exit and return"
            /// Flat gray for `occlusionLength` frames, then the rest of the clip shifted sideways (0.3 of the width toward
            /// the roomier side, `MaskBenchScenarios.moveDistance`): the subject is hidden and comes back somewhere else.
            case occlusionMoved = "occlusion moved"
            /// The subject moves twice as fast: every second frame is fed (the same clip at half the frame rate, played
            /// at the full one). With the baseline's slow and moderate clips this covers 0.5-3 subject widths per second.
            case fastMotion = "fast motion"
            /// Five times as fast: every fifth frame, so every step is a labeled one.
            case veryFastMotion = "very fast motion"

            /// The scenarios are opt-in (`SQ_MASK_BENCH_RECOVERY=1` or named in `SQ_MASK_BENCH_VARIANTS`): the G0 run stays as it was.
            var isScenario: Bool { self != .baseline && self != .visionGateOff && self != .strokesAsPrompts }
            /// Frames per tracker step: the motion scenarios skip frames.
            var stride: Int { self == .fastMotion ? 2 : self == .veryFastMotion ? 5 : 1 }
            /// Not tied to the clip's middle (`Plan`).
            var needsPlan: Bool { isScenario && stride == 1 }
            var occludes: Bool { self == .occlusionBox || self == .occlusionBlank || self == .occlusionMoved }
            /// The scenarios with a gap in the middle (`Plan.start..<Plan.end`), reported in the occlusion tables.
            var hasGap: Bool { occludes || self == .exitReturn }
        }

        static let occlusionLength = 15

        /// Where a clip's scenarios happen: the labeled frame nearest the middle (mid-clip click) and the occlusion
        /// `start..<end`, aligned to the 5-frame label grid. Nil when the clip is too short for an occlusion with a frame after it.
        struct Plan {
            let mid: Int
            let start: Int
            var end: Int { start + MaskBenchmarkTests.occlusionLength }
        }

        static func plan(_ clip: Clip) -> Plan? {
            let last = clip.labels.keys.max() ?? 0
            guard let mid = clip.labels.keys.min(by: { abs($0 - last / 2) < abs($1 - last / 2) }) else { return nil }
            let start = max(5, last / 2 / 5 * 5)
            guard last >= start + occlusionLength else { return nil }
            return Plan(mid: mid, start: start)
        }

        /// A copy of the frame with gray painted over `box` (fractions x0,y0,x1,y1) or over everything when nil.
        static func grayed(_ pb: CVPixelBuffer, box: (x0: Double, y0: Double, x1: Double, y1: Double)?) -> CVPixelBuffer? {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            var copy: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &copy)
            guard let copy else { return nil }
            CVPixelBufferLockBaseAddress(pb, .readOnly); CVPixelBufferLockBaseAddress(copy, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly); CVPixelBufferUnlockBaseAddress(copy, []) }
            guard let src = CVPixelBufferGetBaseAddress(pb), let dst = CVPixelBufferGetBaseAddress(copy) else { return nil }
            let sRow = CVPixelBufferGetBytesPerRow(pb), dRow = CVPixelBufferGetBytesPerRow(copy)
            let x0 = box.map { max(0, Int($0.x0 * Double(w))) } ?? 0, x1 = box.map { min(w, Int($0.x1 * Double(w))) } ?? w
            let y0 = box.map { max(0, Int($0.y0 * Double(h))) } ?? 0, y1 = box.map { min(h, Int($0.y1 * Double(h))) } ?? h
            for y in 0..<h {
                let d = dst.advanced(by: y * dRow)
                memcpy(d, src.advanced(by: y * sRow), min(sRow, dRow))
                if y >= y0 && y < y1 && x1 > x0 { memset(d.advanced(by: x0 * 4), 128, (x1 - x0) * 4) }
            }
            return copy
        }

        /// A copy of the frame moved right by `dx` pixels (left when negative), gray where nothing slides in.
        static func shiftedPicture(_ pb: CVPixelBuffer, dx: Int) -> CVPixelBuffer? {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            var copy: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &copy)
            guard let copy else { return nil }
            CVPixelBufferLockBaseAddress(pb, .readOnly); CVPixelBufferLockBaseAddress(copy, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly); CVPixelBufferUnlockBaseAddress(copy, []) }
            guard let src = CVPixelBufferGetBaseAddress(pb), let dst = CVPixelBufferGetBaseAddress(copy) else { return nil }
            let sRow = CVPixelBufferGetBytesPerRow(pb), dRow = CVPixelBufferGetBytesPerRow(copy)
            let keep = max(0, w - abs(dx))
            for y in 0..<h {
                let d = dst.advanced(by: y * dRow), s = src.advanced(by: y * sRow)
                memset(d, 128, w * 4)
                if keep > 0 { memcpy(d.advanced(by: max(dx, 0) * 4), s.advanced(by: max(-dx, 0) * 4), keep * 4) }
            }
            return copy
        }

        /// Box (fractions x0, y0, x1, y1) of the ground truth at the labeled frame nearest `frame`.
        static func truthBox(_ clip: Clip, near frame: Int, width w: Int, height h: Int) -> (x0: Double, y0: Double, x1: Double, y1: Double)? {
            guard let near = clip.labels.keys.min(by: { abs($0 - frame) < abs($1 - frame) }),
                  let t = label(clip.labels[near]!, width: w, height: h) else { return nil }
            let g = MaskMetrics.downscaled(t, width: w, height: h)
            return MaskBenchScenarios.grownBox(g.mask, width: g.width, height: g.height, margin: 0).map {
                (Double($0.x0) / Double(g.width), Double($0.y0) / Double(g.height), Double($0.x1) / Double(g.width), Double($0.y1) / Double(g.height))
            }
        }

        /// Horizontal shift (fraction of the width) of picture and ground truth at `frame` for the moving scenarios.
        static func shift(_ variant: Variant, frame: Int, plan: Plan, distance: Double) -> Double {
            switch variant {
            case .exitReturn: return MaskBenchScenarios.exitShift(frame: frame, start: plan.start, length: occlusionLength, distance: distance)
            case .occlusionMoved: return frame >= plan.end ? distance : 0
            default: return 0
            }
        }

        /// The first frame the subject is back in view: where re-acquisition is counted from.
        static func returnFrame(_ variant: Variant, plan: Plan) -> Int {
            variant == .exitReturn ? MaskBenchScenarios.exitReturn(start: plan.start, length: occlusionLength) : plan.end
        }

        struct NoSegmenter: InstanceSegmenting {
            func segment(_ frame: CVPixelBuffer) throws -> InstanceFrame? { nil }
        }

        static let failIoU = 0.5
        static let correctionGap = 30

        static var root: URL {
            URL(fileURLWithPath: ProcessInfo.processInfo.environment["SQ_MASK_BENCH_DIR"]
                ?? NSHomeDirectory() + "/Documents/SequenceStudio/TestMedia/MaskBench", isDirectory: true)
        }

        static var out: URL {
            if let p = ProcessInfo.processInfo.environment["SQ_MASK_BENCH_OUT"] { return URL(fileURLWithPath: p) }
            // .../Packages/SQAnalysis/Tests/SQAnalysisTests/Benchmark/<this file>: six path components up is the repo root.
            var url = URL(fileURLWithPath: #filePath)
            for _ in 0..<6 { url.deleteLastPathComponent() }
            return url.appendingPathComponent("build/mask-bench.md")
        }

        struct Clip {
            let name: String
            let video: URL
            let click: Vec2
            let labels: [Int: URL]
        }

        static func clips() -> (found: [Clip], skipped: [String]) {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: root.path).sorted() else {
                return ([], ["no folder at \(root.path)"])
            }
            var found: [Clip] = [], skipped: [String] = []
            for name in names where !name.hasPrefix(".") {
                let dir = root.appendingPathComponent(name, isDirectory: true)
                guard let video = ["mp4", "mov"].map({ dir.appendingPathComponent("clip.\($0)") }).first(where: { fm.fileExists(atPath: $0.path) }),
                      let data = try? Data(contentsOf: dir.appendingPathComponent("prompt.json")),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
                      let x = json["x"], let y = json["y"] else { skipped.append("\(name): needs clip.mp4|mov and prompt.json"); continue }
                var labels: [Int: URL] = [:]
                for file in (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("labels").path)) ?? [] where file.hasSuffix(".png") {
                    if let n = Int(file.dropLast(4)) { labels[n] = dir.appendingPathComponent("labels/\(file)") }
                }
                guard labels[0] != nil || !labels.isEmpty else { skipped.append("\(name): no labels/<frame>.png"); continue }
                found.append(Clip(name: name, video: video, click: Vec2(x, y), labels: labels))
            }
            return (found, skipped)
        }

        /// Ground truth at the frame's size: white (> 127) is the subject.
        static func label(_ url: URL, width: Int, height: Int) -> [Float]? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return (0..<(width * height)).map { base[$0] > 127 ? 1 : 0 }
        }

        static func engine(_ models: String) -> SubjectMaskEngine {
            let environment = [SubjectMaskLocator.environmentKey: models]
            let compute = SubjectTrackCompute(rawValue: ProcessInfo.processInfo.environment["SQ_SUBJECT_MASK_COMPUTE"] ?? "") ?? .gpu
            return SubjectMaskEngine(locate: { SubjectMaskLocator.locate(environment: environment, bundle: nil, support: nil) },
                                     compute: compute, loader: EdgeTAMLoader(), personBox: SubjectPersonBox.find)
        }

        static func time(_ seconds: Double) -> Time { Time(Int64((seconds * 60_000).rounded()), 60_000) }

        /// `SQ_MASK_BENCH_EDGES=1`: the baseline leg reports the model's mask without an edge step, and every edge step
        /// below is scored on that same mask (the edge step never feeds the model's memory, so one run serves all).
        static let sweepsEdges = ProcessInfo.processInfo.environment["SQ_MASK_BENCH_EDGES"] == "1"

        /// The Quality edge steps of the sweep, in table order (the model's mask and the quick step come first).
        static let edgeSteps: [(name: String, settings: SubjectMatteRefiner.Settings)] = {
            typealias S = SubjectMatteRefiner.Settings
            func with(_ change: (inout S) -> Void) -> S { var s = S(); change(&s); return s }
            return [
                ("quality", S()),
                ("q without keep", with { $0.keepRadius = 0 }),
                ("q radius 2", with { $0.radius = 2 }),
                ("q strands", S.strands),
                ("q strands mix 0.5", { var s = S.strands; s.colorMix = 0.5; return s }()),
                ("q color r10 both ways", with { $0.colorRadius = 10 }),
            ]
        }()

        /// Mean scores of each edge step over every clip's scored frames.
        final class EdgeSweep {
            var scores: [String: MaskBenchScore] = [:]
            var seconds: [String: Double] = [:]

            func table() -> String {
                var s = "\n## Edge sweep (one tracking run, every edge step on the same model mask; all clips' scored frames)\n\n| edge step | J | F | J&F | F2px | band err | ms/frame | frames |\n|---|---|---|---|---|---|---|---|\n"
                for name in ["model", "speed"] + MaskBenchmarkTests.edgeSteps.map(\.name) {
                    guard let r = scores[name] else { continue }
                    s += "| \(name) | \(String(format: "%.4f | %.4f | %.4f | %.4f | %.4f | %.1f", r.j, r.f, r.jf, r.f2, r.bandError, (seconds[name] ?? 0) * 1000 / Double(max(r.scored, 1)))) | \(r.scored) |\n"
                }
                return s
            }

            /// Scores every edge step of `matte` against `truth` (frame size `w` x `h`).
            func score(_ matte: SubjectMatte, frame pb: CVPixelBuffer, truth: [Float], width w: Int, height h: Int, picture: SubjectMatteRefiner.Picture) {
                func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
                var made: [(String, SubjectMatte, Double)] = [("model", matte, 0)]
                var t = now()
                made.append(("speed", SubjectMatteEdges.refine(matte, guide: pb), Double(now() - t) / 1e9))
                if picture.load(pb, longEdge: SubjectMatteRefiner.Settings().longEdge) {
                    for step in MaskBenchmarkTests.edgeSteps {
                        t = now()
                        if let m = try? SubjectMatteRefiner.refine(matte, picture: picture, settings: step.settings) {
                            made.append((step.name, m, Double(now() - t) / 1e9))
                        }
                    }
                }
                let g = MaskMetrics.downscaled(truth, width: w, height: h)
                let hard = truth.map { $0 >= 0.5 }
                for (name, m, took) in made where m.width == w && m.height == h {
                    let p = MaskMetrics.downscaled(m.values, width: w, height: h)
                    scores[name, default: MaskBenchScore()].add(
                        j: MaskMetrics.jaccard(p.mask, g.mask), f: MaskMetrics.boundaryF(p.mask, g.mask, width: g.width, height: g.height),
                        f2: MaskMetrics.boundaryF(m.values.map { $0 >= 0.5 }, hard, width: w, height: h, pixels: 2),
                        bandError: MaskMetrics.bandError(alpha: m.values, truth: truth, width: w, height: h))
                    seconds[name, default: 0] += took
                }
            }
        }

        /// One variant over one clip: frames are decoded once per run and streamed through a fresh leg.
        static func run(_ clip: Clip, _ variant: Variant, engine: SubjectMaskEngine, sweep: EdgeSweep? = nil) async throws -> MaskBenchScore? {
            guard let lease = engine.lease() else { return nil }
            let segmenter: any InstanceSegmenting = variant == .visionGateOff ? NoSegmenter() : VisionInstanceSegmenter()
            let leg = try #require(SubjectTrackLeg(lease: lease, segmenter: segmenter))
            // SQ_MASK_BENCH_QUALITY=1: the app's Quality edge step (color-guided matte) instead of the quick one.
            if ProcessInfo.processInfo.environment["SQ_MASK_BENCH_QUALITY"] == "1" { leg.quality = .quality }
            if sweep != nil { leg.refinesEdges = false }
            let sweepPicture = SubjectMatteRefiner.Picture()
            leg.recordsDiagnostics = ProcessInfo.processInfo.environment["SQ_MASK_BENCH_VERBOSE"] == "1"
            let asset = AVURLAsset(url: clip.video)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let fps = Double(try await track.load(.nominalFrameRate))
            let gap = 1 / max(fps, 1)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { return nil }
            defer { reader.cancelReading() }

            var score = MaskBenchScore()
            score.fps = fps
            let verbose = ProcessInfo.processInfo.environment["SQ_MASK_BENCH_VERBOSE"] == "1"
            var points: [MagicPoint] = []
            var failed = false
            var lastCorrection = -correctionGap
            var frame = 0
            let lastLabel = clip.labels.keys.max() ?? 0
            let plan = Self.plan(clip)
            if variant.needsPlan && plan == nil { return nil }
            // The moving scenarios' distance, from the subject's box where it starts to move.
            var distance = 0.0
            var lastMatte: SubjectMatte?
            var shapes: [(predicted: [Bool], truth: [Bool])] = []
            var boxes: [Int: (x0: Double, y0: Double, x1: Double, y1: Double)] = [:]
            while frame <= lastLabel, let sample = output.copyNextSampleBuffer() {
                defer { frame += 1 }
                if frame % variant.stride != 0 { continue }
                guard let shown = CMSampleBufferGetImageBuffer(sample) else { continue }
                var pb = shown
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                if frame == 0 { points = [MagicPoint(position: clip.click, subtract: false, sourceTime: time(pts))] }
                if frame == 0, let plan, variant == .exitReturn || variant == .occlusionMoved {
                    guard let b = truthBox(clip, near: variant == .exitReturn ? plan.start : plan.end, width: w, height: h) else { return nil }
                    distance = variant == .exitReturn ? MaskBenchScenarios.exitDistance(x0: b.x0, x1: b.x1) : MaskBenchScenarios.moveDistance(x0: b.x0, x1: b.x1)
                    score.notes.append("\(variant.rawValue): shift \(String(format: "%+.2f", distance)) of the width")
                }
                var truth = clip.labels[frame].flatMap { label($0, width: w, height: h) }
                let dx = plan.map { Int((Self.shift(variant, frame: frame, plan: $0, distance: distance) * Double(w)).rounded()) } ?? 0
                if dx != 0 {
                    if let moved = Self.shiftedPicture(shown, dx: dx) { pb = moved }
                    truth = truth.map { MaskBenchScenarios.shifted($0, width: w, height: h, by: dx, fill: 0) }
                }
                var correction: SubjectMatte?
                if let plan, variant.occludes, frame >= plan.start, frame < plan.end {
                    var box: (x0: Double, y0: Double, x1: Double, y1: Double)?
                    if variant == .occlusionBox, let near = clip.labels.keys.min(by: { abs($0 - frame) < abs($1 - frame) }) {
                        if boxes[near] == nil, let t = label(clip.labels[near]!, width: w, height: h) {
                            let g = MaskMetrics.downscaled(t, width: w, height: h)
                            boxes[near] = MaskBenchScenarios.grownBox(g.mask, width: g.width, height: g.height, margin: 0.3).map {
                                (Double($0.x0) / Double(g.width), Double($0.y0) / Double(g.height), Double($0.x1) / Double(g.width), Double($0.y1) / Double(g.height))
                            }
                        }
                        box = boxes[near]
                    }
                    if variant == .occlusionBlank || variant == .occlusionMoved || box != nil, let gray = Self.grayed(shown, box: box) { pb = gray }
                }
                if let plan, variant == .midClipClick || variant == .midClipFix, frame == plan.mid, frame > 0, let truth {
                    let g = MaskMetrics.downscaled(truth, width: w, height: h)
                    var target = g.mask, subtract = false
                    if variant == .midClipFix {
                        // The previous frame's answer sampled on the truth grid: what it misses, what it covers too much.
                        let had = (0..<g.mask.count).map { i -> Bool in
                            guard let m = lastMatte else { return false }
                            let x = min(m.width - 1, (i % g.width) * m.width / g.width), y = min(m.height - 1, (i / g.width) * m.height / g.height)
                            return m.values[y * m.width + x] >= 0.5
                        }
                        let missed = zip(g.mask, had).map { $0 && !$1 }, extra = zip(g.mask, had).map { !$0 && $1 }
                        let nm = missed.filter { $0 }.count, ne = extra.filter { $0 }.count
                        if max(nm, ne) < g.mask.count / 200 { target = [] } else if nm >= ne { target = missed } else { target = extra; subtract = true }
                    }
                    if !target.isEmpty, let c = MaskBenchScenarios.interiorClick(target, width: g.width, height: g.height) {
                        let click = Vec2((c.x + 0.5) / Double(g.width), (c.y + 0.5) / Double(g.height))
                        if subtract { score.notes.append("mid-clip fix is a removing click") }
                        points.append(MagicPoint(position: click, subtract: subtract, sourceTime: time(pts)))
                        if let seen = try? segmenter.segment(pb) {
                            correction = MagicMaskTracker.pickMatte(seen, pts: pts, points: points, start: lastMatte, span: gap)
                        }
                        score.notes.append("mid-clip click at frame \(frame): (\(String(format: "%.3f, %.3f", click.x, click.y))), stored matte \(correction == nil ? "none (tracker unchanged)" : "yes")")
                    }
                }
                if variant == .strokesAsPrompts, failed, frame > 0, frame - lastCorrection >= correctionGap, let truth {
                    correction = SubjectMatte(width: w, height: h, values: truth)
                    points.append(MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: time(pts)))
                    lastCorrection = frame
                    score.corrections += 1
                }
                let answer: SubjectTrackLeg.Answer
                let began = DispatchTime.now().uptimeNanoseconds
                do {
                    answer = try leg.step(pb, pts: pts, gap: gap, points: points, stored: { correction })
                    score.stepSeconds += Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9; score.steps += 1
                } catch {
                    score.lostFrames += 1
                    score.lostFrameIndices.append(frame)
                    continue
                }
                var found: SubjectMatte?
                if verbose { score.notes.append("  step \(frame): \(leg.lastDiagnostic)") }
                switch answer {
                case .found(let m): found = m; lastMatte = m
                case .lost, .nothing: score.lostFrames += 1; score.lostFrameIndices.append(frame)
                }
                guard let truth, correction == nil else { continue }
                let g = MaskMetrics.downscaled(truth, width: w, height: h)
                let p = found.map { MaskMetrics.downscaled($0.values, width: w, height: h) }
                    ?? (mask: [Bool](repeating: false, count: g.mask.count), width: g.width, height: g.height)
                let j = MaskMetrics.jaccard(p.mask, g.mask)
                let full = found.map { $0.values } ?? [Float](repeating: 0, count: w * h)
                let f2 = MaskMetrics.boundaryF(full.map { $0 >= 0.5 }, truth.map { $0 >= 0.5 }, width: w, height: h, pixels: 2)
                if frame == 0 { score.firstJ = j; score.firstF2 = f2 }
                if let sweep, let found { sweep.score(found, frame: pb, truth: truth, width: w, height: h, picture: sweepPicture) }
                score.perFrame.append(MaskFrameScore(frame: frame, j: j, f: MaskMetrics.boundaryF(p.mask, g.mask, width: g.width, height: g.height)))
                score.add(j: j, f: MaskMetrics.boundaryF(p.mask, g.mask, width: g.width, height: g.height), f2: f2,
                          bandError: MaskMetrics.bandError(alpha: full, truth: truth, width: w, height: h))
                let truthMask = truth.map { $0 >= 0.5 }
                if let c = MaskLag.centroid(truthMask, width: w) {
                    // In tracker steps: a motion scenario is the same clip with the subject `stride` times as fast.
                    score.lagSamples.append(MaskLagSample(frame: frame / variant.stride, predicted: MaskLag.centroid(full.map { $0 >= 0.5 }, width: w),
                                                          truth: c, truthWidth: MaskLag.boxWidth(truthMask, width: w)))
                    shapes.append((p.mask, g.mask))
                }
                if verbose {
                    score.notes.append("frame \(frame): J \(String(format: "%.2f", j)) truth area \(String(format: "%.4f", Double(g.mask.filter { $0 }.count) / Double(g.mask.count))) box \(SubjectTrackRules.box(of: SubjectMatte(width: w, height: h, values: truth)).map { String(format: "%.2f,%.2f-%.2f,%.2f", $0.x0, $0.y0, $0.x1, $0.y1) } ?? "-") \(found == nil ? " (lost)" : "")")
                }
                if j < failIoU { failed = true }
            }
            // The shape against the labeled pictures around it (every scored frame has one sample, in order).
            if shapes.count == score.lagSamples.count, shapes.count >= 3 {
                for k in 1..<(shapes.count - 1) {
                    score.lagSamples[k].shapeLag = MaskLag.shapeLag(previous: MaskMetrics.jaccard(shapes[k].predicted, shapes[k - 1].truth),
                                                                    own: MaskMetrics.jaccard(shapes[k].predicted, shapes[k].truth),
                                                                    next: MaskMetrics.jaccard(shapes[k].predicted, shapes[k + 1].truth))
                }
            }
            score.notes.insert("per part: \(SubjectMaskTiming.takeTimings())", at: 0)
            return score
        }

        /// Speed buckets of the lag table, in subject widths per second (the maintainer: the lag shows on ordinary head movements).
        static let lagBuckets: [(String, ClosedRange<Double>)] = [("< 0.5", 0...0.5), ("0.5-1.5", 0.5...1.5), ("1.5-3", 1.5...3), ("> 3", 3...1e9)]

        /// How far the mask trails the subject, per clip and variant and per speed over all clips (`MaskLag.report`).
        static func lagTable(_ rows: [(clip: String, variant: String, score: MaskBenchScore)]) -> String {
            func fmt(_ r: MaskLagReport?) -> String {
                guard let r else { return "| - | - | - | - | - | - | 0 |" }
                let shape = r.shapeLag.map { String(format: "%+.2f", $0) } ?? "-"
                return String(format: "| %+.2f | %.1f | %+.1f | %.2f | %+.2f | ", r.lagFrames, r.meanError, r.alongError, r.widthsPerSecond, r.correlation)
                    + "\(shape) | \(r.count) |"
            }
            let head = "| lag (frames) | error (px) | along motion (px) | speed (widths/s) | corr(speed, along) | shape lag (labeled steps) | frames |"
            var out = "\n## Lag: mask centroid against the truth (+ frames = the mask trails the motion; along < 0 = behind)\n\n| clip | variant \(head)\n|---|---|---|---|---|---|---|---|---|\n"
            for r in rows where !r.score.lagSamples.isEmpty {
                out += "| \(r.clip) | \(r.variant) " + fmt(MaskLag.report(r.score.lagSamples, fps: r.score.fps)) + "\n"
            }
            out += "\n## Lag by subject speed, all clips pooled\n\n| variant | speed bucket \(head)\n|---|---|---|---|---|---|---|---|---|\n"
            for v in Variant.allCases {
                let mine = rows.filter { $0.variant == v.rawValue && !$0.score.lagSamples.isEmpty }
                guard !mine.isEmpty else { continue }
                for (name, range) in lagBuckets {
                    // Pool per clip (each clip's velocities from its own samples), then merge weighted by frames.
                    let parts = mine.compactMap { MaskLag.report($0.score.lagSamples, fps: $0.score.fps, widthsPerSecond: range) }
                    out += "| \(v.rawValue) | \(name) " + fmt(Self.pooled(parts)) + "\n"
                }
            }
            return out
        }

        /// Frame-weighted mean of per-clip lag reports (the lag weighted the same way; shortcut: not a joint fit, fine for a table).
        static func pooled(_ parts: [MaskLagReport]) -> MaskLagReport? {
            let n = parts.reduce(0) { $0 + $1.count }
            guard n > 0 else { return nil }
            func avg(_ k: KeyPath<MaskLagReport, Double>) -> Double { parts.reduce(0) { $0 + $1[keyPath: k] * Double($1.count) } / Double(n) }
            let shaped = parts.filter { $0.shapeLag != nil }, sn = shaped.reduce(0) { $0 + $1.shapeCount }
            let shape = sn > 0 ? shaped.reduce(0) { $0 + ($1.shapeLag ?? 0) * Double($1.shapeCount) } / Double(sn) : nil
            return MaskLagReport(lagFrames: avg(\.lagFrames), meanError: avg(\.meanError), alongError: avg(\.alongError),
                                 meanSpeed: avg(\.meanSpeed), widthsPerSecond: avg(\.widthsPerSecond), correlation: avg(\.correlation), count: n,
                                 shapeLag: shape, shapeCount: sn)
        }

        /// The compact mid-clip and occlusion tables (empty when no scenario ran).
        static func scenarioTables(_ rows: [(clip: String, variant: String, score: MaskBenchScore)], clips: [Clip]) -> String {
            func row(_ clip: String, _ v: Variant) -> MaskBenchScore? { rows.first { $0.clip == clip && $0.variant == v.rawValue }?.score }
            func fmt(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "-" }
            func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
            var out = ""
            for kind in [Variant.midClipClick, .midClipFix] {
            var mid: [(String, Int, Double?, Double?, Double, Double)] = []
            for clip in clips {
                guard let plan = plan(clip), let base = row(clip.name, .baseline), let click = row(clip.name, kind) else { continue }
                let after = (plan.mid + 1)..<Int.max
                mid.append((clip.name, plan.mid, MaskBenchScenarios.window(base.perFrame, after)?.jf, MaskBenchScenarios.window(click.perFrame, after)?.jf, base.jf, click.jf))
            }
            if !mid.isEmpty {
                out += "\n## \(kind == .midClipFix ? "Mid-clip fix" : "Mid-clip click"): J&F on the labeled frames after the click (before = baseline, after = with the click)\n\n| clip | click frame | J&F before | J&F after | delta | whole clip before | whole clip after |\n|---|---|---|---|---|---|---|\n"
                for m in mid {
                    out += "| \(m.0) | \(m.1) | \(fmt(m.2)) | \(fmt(m.3)) | \(m.2 != nil && m.3 != nil ? String(format: "%+.3f", m.3! - m.2!) : "-") | \(fmt(m.4)) | \(fmt(m.5)) |\n"
                }
                let b = mid.compactMap(\.2), a = mid.compactMap(\.3)
                out += "| mean (\(mid.count) clips) | | \(fmt(mean(b))) | \(fmt(mean(a))) | \(mean(b).flatMap { mb in mean(a).map { String(format: "%+.3f", $0 - mb) } } ?? "-") | \(fmt(mean(mid.map(\.4)))) | \(fmt(mean(mid.map(\.5)))) |\n"
            }
            }
            for v in Variant.allCases where v.hasGap {
                var lines: [(String, [Double?])] = [], recovered: [Int?] = [], reacquired: [Int?] = []
                for clip in clips {
                    guard let plan = plan(clip), let s = row(clip.name, v), let base = row(clip.name, .baseline) else { continue }
                    let w = [0..<plan.start, plan.start..<plan.end, plan.end..<Int.max].map { MaskBenchScenarios.window(s.perFrame, $0)?.jf }
                    let ref = MaskBenchScenarios.window(base.perFrame, plan.end..<Int.max)?.jf
                    let lost = s.lostFrameIndices.filter { $0 >= plan.start && $0 < plan.end }.count
                    let rec = MaskBenchScenarios.framesToRecover(s.perFrame, end: plan.end)
                    recovered.append(rec)
                    let back = returnFrame(v, plan: plan)
                    let again = MaskBenchScenarios.framesToReacquire(lost: s.lostFrameIndices, from: back, last: clip.labels.keys.max() ?? back)
                    reacquired.append(again)
                    lines.append(("| \(clip.name) | \(plan.start)..<\(plan.end) | \(fmt(w[0])) | \(fmt(w[1])) | \(fmt(w[2])) | \(fmt(ref)) | \(lost)/\(occlusionLength) | \(rec.map(String.init) ?? "never") | \(again.map(String.init) ?? "never") |", w + [ref]))
                }
                guard !lines.isEmpty else { continue }
                out += "\n## \(v.rawValue): J&F before, during and after the \(occlusionLength)-frame occlusion (recovery = frames after the occlusion until a labeled frame reaches J 0.5; resolution = label spacing; found again = frames from the subject's return to the first frame not answered lost)\n\n| clip | occluded | before | during | after | after, no occlusion | lost during | recover (frames) | found again (frames) |\n|---|---|---|---|---|---|---|---|---|\n"
                for l in lines { out += l.0 + "\n" }
                let cols = (0..<4).map { c in mean(lines.compactMap { $0.1[c] }) }
                let rec = recovered.compactMap { $0 }, again = reacquired.compactMap { $0 }
                out += "| mean (\(lines.count) clips) | | \(fmt(cols[0])) | \(fmt(cols[1])) | \(fmt(cols[2])) | \(fmt(cols[3])) | | \(mean(rec.map(Double.init)).map { String(format: "%.1f", $0) } ?? "-") (never: \(recovered.count - rec.count)/\(recovered.count)) | \(mean(again.map(Double.init)).map { String(format: "%.1f", $0) } ?? "-") (never: \(reacquired.count - again.count)/\(reacquired.count)) |\n"
            }
            return out
        }

        @Test func benchmark() async throws {
            let (clips, skipped) = Self.clips()
            for s in skipped { print("MASKBENCH skipped \(s)") }
            guard !clips.isEmpty else {
                print("MASKBENCH no labeled clips under \(Self.root.path): nothing to measure (layout in MaskBenchmarkTests.swift)")
                return
            }
            let models = ProcessInfo.processInfo.environment[SubjectMaskLocator.environmentKey] ?? ""
            guard !models.isEmpty else {
                print("MASKBENCH set \(SubjectMaskLocator.environmentKey) to the folder with the model parts")
                return
            }
            let engine = Self.engine(models)
            engine.prewarm()
            for _ in 0..<60_000 where engine.status == .warming { try await Task.sleep(for: .milliseconds(5)) }
            guard engine.status == .ready else {
                print("MASKBENCH model did not load: \(engine.status)")
                return
            }
            // SQ_MASK_BENCH_VARIANTS="baseline,strokes as prompts" limits the variants (default all).
            let only = (ProcessInfo.processInfo.environment["SQ_MASK_BENCH_VARIANTS"] ?? "").split(separator: ",").map(String.init)
            var rows: [(clip: String, variant: String, score: MaskBenchScore)] = []
            let sweep = Self.sweepsEdges ? EdgeSweep() : nil
            // SQ_MASK_BENCH_CLIPS=judo,lindy-hop limits the clips (default all).
            let wanted = (ProcessInfo.processInfo.environment["SQ_MASK_BENCH_CLIPS"] ?? "").split(separator: ",").map(String.init)
            let recovery = ProcessInfo.processInfo.environment["SQ_MASK_BENCH_RECOVERY"] == "1"
            let chosen = Variant.allCases.filter { v in
                if only.isEmpty { return recovery || !v.isScenario }
                // The scenario tables compare against the baseline, so it always runs with them.
                return only.contains(v.rawValue) || (v == .baseline && only.contains { Variant(rawValue: $0)?.isScenario == true })
            }
            for clip in clips where wanted.isEmpty || wanted.contains(clip.name) {
                for variant in chosen {
                    if let score = try await Self.run(clip, variant, engine: engine, sweep: variant == .baseline ? sweep : nil) {
                        rows.append((clip.name, variant.rawValue, score))
                        print("MASKBENCH \(clip.name) \(variant.rawValue): J&F \(String(format: "%.3f", score.jf)), lost \(score.lostFrames)")
                    }
                }
            }
            let plain = rows.filter { Variant(rawValue: $0.variant)?.isScenario != true }
            var table = MaskBenchScore.table(plain)
            table += Self.scenarioTables(rows, clips: clips)
            let lag = Self.lagTable(rows)
            table += lag
            for line in lag.split(separator: "\n") { print("MASKBENCH \(line)") }
            if let sweep {
                table += sweep.table()
                for line in sweep.table().split(separator: "\n") { print("MASKBENCH \(line)") }
            }
            for r in rows where !r.score.notes.isEmpty { table += "\n## \(r.clip) \(r.variant)\n" + r.score.notes.joined(separator: "\n") + "\n" }
            try FileManager.default.createDirectory(at: Self.out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ("# Mask benchmark (gate G0)\n\n" + table).write(to: Self.out, atomically: true, encoding: .utf8)
            print("MASKBENCH wrote \(Self.out.path)")
        }
    }
}
