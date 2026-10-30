import AVFoundation
import CoreVideo
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQAnalysis

/// Runs on the real tracking model. Only when `SQ_SUBJECT_MASK_MODELS` names the folder with its five parts (they are
/// not in the repository); the measured numbers are printed as `PERF` lines.
extension VisionSuites {
    @Suite(.enabled(if: ProcessInfo.processInfo.environment[SubjectMaskLocator.environmentKey] != nil))
    struct SubjectMaskModelTests {
        static var models: String { ProcessInfo.processInfo.environment[SubjectMaskLocator.environmentKey] ?? "" }

        /// The clip the conversion was checked on: `SQ_SUBJECT_MASK_CLIP`, or the one next to the models.
        static var clip: URL? {
            let url = ProcessInfo.processInfo.environment["SQ_SUBJECT_MASK_CLIP"].map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: models).deletingLastPathComponent().appendingPathComponent("EdgeTAM/examples/01_breakdancer.mp4")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        static func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return ok == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        }

        static func engine(_ compute: SubjectTrackCompute) -> SubjectMaskEngine {
            let environment = [SubjectMaskLocator.environmentKey: models]
            return SubjectMaskEngine(locate: { SubjectMaskLocator.locate(environment: environment, bundle: nil, support: nil) },
                                     compute: compute, loader: EdgeTAMLoader(), personBox: SubjectPersonBox.find)
        }

        static func ready(_ engine: SubjectMaskEngine) async throws -> Double {
            let t0 = Date()
            engine.prewarm()
            for _ in 0..<60_000 where engine.status == .warming { try await Task.sleep(for: .milliseconds(5)) }
            #expect(engine.status == .ready)
            return Date().timeIntervalSince(t0)
        }

        static func iou(_ a: SubjectMatte, _ b: SubjectMatte) -> Double {
            guard a.values.count == b.values.count else { return 0 }
            var inter = 0, union = 0
            for i in a.values.indices {
                let x = a.values[i] >= 0.5, y = b.values[i] >= 0.5
                if x && y { inter += 1 }
                if x || y { union += 1 }
            }
            return union == 0 ? 1 : Double(inter) / Double(union)
        }

        /// Mean width (px of the matte) of the band between clearly outside and clearly inside.
        static func softBand(_ m: SubjectMatte) -> Double {
            guard m.width > 2, m.height > 2 else { return 0 }
            var soft = 0, contour = 0
            for y in 1..<(m.height - 1) {
                for x in 1..<(m.width - 1) {
                    let v = m[x, y]
                    if v > 0.05 && v < 0.95 { soft += 1 }
                    if v >= 0.5 && (m[x - 1, y] < 0.5 || m[x + 1, y] < 0.5 || m[x, y - 1] < 0.5 || m[x, y + 1] < 0.5) { contour += 1 }
                }
            }
            return contour == 0 ? 0 : Double(soft) / Double(contour)
        }

        @Test func theModelLoadsAndFollowsAMovingPatch() async throws {
            let engine = Self.engine(.gpu)
            let seconds = try await Self.ready(engine)
            print("PERF subject mask model load (GPU): \(String(format: "%.1f", seconds)) s")
            let url = try await MaskTrackerTests().writeMovie()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = MagicMatteStore(directory: nil)
            let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter(), engine: engine)
            let r = try await tracker.track(key: "p", points: SubjectMaskEngineTests.click, from: 0, to: 23.0 / 24, store: store)
            #expect(r.frames + r.lostTimes.count == 24 && store.times(key: "p").count == 24)
            #expect(engine.status == .ready && engine.failures == 0)
            // The model either follows the patch or says it lost it: never a matte somewhere else.
            for i in 0..<24 {
                let m = try #require(store.matte(key: "p", pts: Double(i) / 24))
                guard let c = m.centroid, !m.isBlank else { continue }
                #expect(abs(c.x / Double(m.width) * 320 - Double(80 + 4 * i)) < 16, "frame \(i)")
            }
            print("PERF subject mask model on the test patch: \(r.frames) of 24 frames followed, \(r.lostTimes.count) lost")
            engine.release()
        }

        @Test func theModelFollowsAPersonOnBothComputeUnits() async throws {
            guard let url = Self.clip else { print("PERF subject mask model: no clip, run skipped"); return }
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let fps = Double(try await track.load(.nominalFrameRate))
            let clickTime = 10 / fps, end = 59 / fps
            let click = [MagicPoint(position: Vec2(660.0 / 1280, 330.0 / 720), subtract: false,
                                    sourceTime: Time(Int64((clickTime * 60_000).rounded()), 60_000))]
            var mattes: [SubjectTrackCompute: [SubjectMatte]] = [:]
            for compute in [SubjectTrackCompute.gpu, .neuralEngine] {
                let name = compute == .gpu ? "GPU" : "Neural Engine"
                let before = Self.footprintMB()
                let engine = Self.engine(compute)
                let load = try await Self.ready(engine)
                guard engine.status == .ready else { continue }
                let loaded = Self.footprintMB()
                let store = MagicMatteStore(directory: nil)
                let tracker = MagicMaskTracker(url: url, limits: .current, engine: engine)
                let t0 = Date()
                let forward = try await tracker.track(key: "p", points: click, from: clickTime, to: end, store: store)
                let back = try await tracker.track(key: "p", points: click, from: clickTime, to: 0, store: store)
                let seconds = Date().timeIntervalSince(t0)
                let after = Self.footprintMB()
                let frames = forward.frames + back.frames, lost = forward.lostTimes.count + back.lostTimes.count
                #expect(engine.status == .ready && engine.failures == 0)
                #expect(frames + lost == 61 && lost == 0, "\(name): \(frames) followed, \(lost) lost")
                var all: [SubjectMatte] = []
                for i in 0..<60 { all.append(try #require(store.matte(key: "p", pts: Double(i) / fps))) }
                mattes[compute] = all
                let at = all[10]
                let area = Double(at.values.count { $0 >= 0.5 }) / Double(max(at.values.count, 1))
                let band = all.map(Self.softBand).reduce(0, +) / Double(all.count)
                print("PERF subject mask \(name): load \(String(format: "%.1f", load)) s, \(String(format: "%.1f", seconds * 1000 / 61)) ms/frame "
                    + "(decode + track + edges \(SubjectMatteEdges.enabled ? "on" : "off"), \(at.width)x\(at.height)), area \(String(format: "%.2f", area * 100)) %, "
                    + "band \(String(format: "%.1f", band)) px")
                print("PERF subject mask \(name) memory: +\(Int(loaded - before)) MB loaded, +\(Int(after - before)) MB after the run")
                // The subject is the whole person under the click (the one-click answer of the reference is a part of it).
                #expect(area > 0.05 && area < 0.3)
                #expect(at[at.width * 660 / 1280, at.height * 330 / 720] >= 0.5)
                engine.release()
            }
            if let g = mattes[.gpu], let n = mattes[.neuralEngine] {
                let ious = zip(g, n).map(Self.iou)
                let mean = ious.reduce(0, +) / Double(ious.count), low = ious.min() ?? 0
                print("PERF subject mask GPU vs Neural Engine IoU: mean \(String(format: "%.4f", mean)), min \(String(format: "%.4f", low))")
                #expect(mean > 0.97 && low > 0.9)
            }
        }

        @Test func theEdgeStepIsCheap() async throws {
            guard let url = Self.clip else { return }
            let engine = Self.engine(.gpu)
            _ = try await Self.ready(engine)
            let fps = 30.0
            let click = [MagicPoint(position: Vec2(660.0 / 1280, 330.0 / 720), subtract: false, sourceTime: Time(10, 30))]
            let store = MagicMatteStore(directory: nil)
            _ = try await MagicMaskTracker(url: url, limits: .current, engine: engine).track(key: "p", points: click, from: 10 / fps, to: 12 / fps, store: store)
            let matte = try #require(store.matte(key: "p", pts: 11 / fps))
            let gray = (0..<matte.values.count).map { Float(($0 * 31) % 255) / 255 }
            let t0 = Date()
            for _ in 0..<20 { _ = SubjectMatteEdges.refine(matte, gray: gray) }
            let ms = Date().timeIntervalSince(t0) * 1000 / 20
            print("PERF subject mask edge step \(matte.width)x\(matte.height): \(String(format: "%.2f", ms)) ms")
            #expect(ms < 250)   // 3 ms optimized, 85 ms in a debug build
            engine.release()
        }
    }
}
