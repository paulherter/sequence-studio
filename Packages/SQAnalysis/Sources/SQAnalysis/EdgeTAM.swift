import Accelerate
import CoreML
import CoreVideo
import Foundation
import SQCore
import Synchronization
import Vision

/// Loads the five Core ML parts of EdgeTAM (docs/research/subject-mask-edgetam.md; license: docs/THIRD_PARTY.md).
struct EdgeTAMLoader: SubjectMaskLoading {
    /// Compiled copies of `.mlpackage` parts (development: the app ships compiled parts). Never inside the models folder.
    static var compiledCache: URL {
        AnalysisCacheLocation.sharedDirectory("SubjectMask")
    }

    func load(_ parts: SubjectMaskParts, compute: SubjectTrackCompute) async throws -> any SubjectTrackModel {
        var loaded: [String: MLModel] = [:]
        let began = SubjectMaskTiming.now()
        for name in SubjectMaskParts.names {
            let part = SubjectMaskTiming.now()
            try Task.checkCancellation()
            guard let url = parts.urls[name] else { throw SubjectTrackError.prediction("no \(name)") }
            let compiled = try await Self.compiled(url, name: name)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = Self.units(name, compute)
            loaded[name] = try await MLModel.load(contentsOf: compiled, configuration: configuration)
            SubjectMaskTiming.count("load_\(name)", since: part)
        }
        try Task.checkCancellation()
        let model = try EdgeTAMModel(loaded)
        let tested = SubjectMaskTiming.now()
        // One pass through every part before a run may count on it: a part that loads but cannot predict on these
        // devices is found here, not on the user's first frame.
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            EdgeTAMModel.queue.async {
                do { try model.selfTest(); done.resume() } catch { done.resume(throwing: error) }
            }
        }
        SubjectMaskTiming.count("self_test", since: tested)
        // The person request a click with a person under it runs: its first run loads Vision's model (~0.5 s), which
        // otherwise landed on the user's first frame. Beside the load, not in it: the first run once took 2.6 s (Vision
        // building its plan), and the model is usable without it.
        DispatchQueue.global(qos: .userInitiated).async { SubjectMaskTiming.measure("person_warm") { SubjectPersonBox.warmUp() } }
        SubjectMaskTiming.report("model load (\(compute.rawValue))", since: began)
        return model
    }

    /// The image encoder runs on the same device as the other parts. On the Neural Engine beside a GPU run it was
    /// 0.6 s faster per 2 s clip but cost bench J&F (0.9047 -> 0.888, judo 0.797 -> 0.585: its fp16 features drift),
    /// so it stays off by default. `SQ_SUBJECT_MASK_ENCODER=gpu|neuralEngine` overrides it for measurements.
    static let encoderCompute: SubjectTrackCompute? = ProcessInfo.processInfo.environment["SQ_SUBJECT_MASK_ENCODER"].flatMap(SubjectTrackCompute.init(rawValue:))

    static func units(_ name: String, _ compute: SubjectTrackCompute) -> MLComputeUnits {
        let device = name == SubjectMaskParts.encoder ? (encoderCompute ?? compute) : compute
        // Never `.all`: its plan took longest to load and ran no faster.
        return device == .gpu ? .cpuAndGPU : .cpuAndNeuralEngine
    }

    static func compiled(_ url: URL, name: String) async throws -> URL {
        guard url.pathExtension == "mlpackage" else { return url }
        let fm = FileManager.default
        let stamp = ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let target = compiledCache.appendingPathComponent("\(name)-\(Int(stamp)).mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: target.path) { return target }
        try fm.createDirectory(at: compiledCache, withIntermediateDirectories: true)
        let made = try await MLModel.compileModel(at: url)
        do { try fm.moveItem(at: made, to: target) } catch {
            // Another load was faster: its copy serves.
            guard fm.fileExists(atPath: target.path) else { throw error }
            try? fm.removeItem(at: made)
        }
        return target
    }
}

/// The loaded parts. Predictions of all sessions run one at a time (`lock`): two tracks at once would double the
/// working memory for no gain, the devices are the limit.
final class EdgeTAMModel: SubjectTrackModel, @unchecked Sendable {
    static let queue = DispatchQueue(label: "sq.subjectmask.model", qos: .utility)
    static let memorySlots = 7, memoryTokens = 512, memoryDim = 64, pointerSlots = 16, pointerDim = 256

    let encoder: MLModel, decoder: MLModel, decoderBox: MLModel, memoryEncoder: MLModel, memoryAttention: MLModel
    /// One prediction at a time, each with a deadline: one that never returns abandons this model (its waiters and
    /// every later call throw `stalled` at once) instead of blocking every later pick.
    private let runner = SubjectDeadlineRunner()
    /// The image encoder's own line: it runs beside the other parts (the next frame's encoder while this frame is in
    /// the memory attention and the decoder), at most one encoder prediction at a time.
    private let encoderRunner = SubjectDeadlineRunner()

    init(_ parts: [String: MLModel]) throws {
        func part(_ name: String, inputs: [String], outputs: [String]) throws -> MLModel {
            guard let m = parts[name] else { throw SubjectTrackError.prediction("no \(name)") }
            let d = m.modelDescription
            for i in inputs where d.inputDescriptionsByName[i] == nil { throw SubjectTrackError.prediction("\(name) has no input \(i)") }
            for o in outputs where d.outputDescriptionsByName[o] == nil { throw SubjectTrackError.prediction("\(name) has no output \(o)") }
            return m
        }
        let prompt = ["pix_feat", "high_res_0", "high_res_1", "point_coords", "point_labels", "choice"]
        let answer = ["low_res_mask", "obj_ptr", "object_score", "ious", "all_masks"]
        encoder = try part(SubjectMaskParts.encoder, inputs: ["image"], outputs: ["vision_feat", "feat_no_mem", "high_res_0", "high_res_1"])
        decoder = try part(SubjectMaskParts.decoder, inputs: prompt, outputs: answer)
        decoderBox = try part(SubjectMaskParts.decoderBox, inputs: prompt, outputs: answer)
        memoryEncoder = try part(SubjectMaskParts.memoryEncoder, inputs: ["vision_feat", "low_res_mask", "is_click"], outputs: ["memory"])
        memoryAttention = try part(SubjectMaskParts.memoryAttention, inputs: ["vision_feat", "memory", "memory_valid", "obj_ptrs", "ptr_valid"],
                                   outputs: ["pix_feat"])
    }

    func makeSession() -> any SubjectTrackSession { EdgeTAMSession(self) }

    func run(_ name: String, _ model: MLModel, _ inputs: [String: MLFeatureValue]) throws -> any MLFeatureProvider {
        do {
            return try (model === encoder ? encoderRunner : runner).run {
                let began = DispatchTime.now().uptimeNanoseconds
                defer { SubjectMaskTiming.count(name, since: began) }
                return try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
            }
        } catch let own as SubjectTrackError {
            throw own
        } catch {
            throw SubjectTrackError.prediction("\(name): \(error.localizedDescription)")
        }
    }

    /// A click and one tracked frame on a gray picture. These are the model's first predictions, where the devices
    /// build their plans: they get the long deadline, so a slow Mac that finishes is not taken for a hung one (which
    /// failed the load, twice, and lost the model for the launch).
    func selfTest() throws {
        try runner.withDeadline(SubjectDeadlineRunner.selfTestSeconds) {
            try encoderRunner.withDeadline(SubjectDeadlineRunner.selfTestSeconds) { try firstPredictions() }
        }
    }

    /// A gray BGRA picture of `side` x `side`.
    static func grayFrame(side: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, nil, &made) == kCVReturnSuccess, let frame = made else {
            throw SubjectTrackError.badFrame("no test frame")
        }
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) { memset(base, 128, CVPixelBufferGetBytesPerRow(frame) * side) }
        CVPixelBufferUnlockBaseAddress(frame, [])
        return frame
    }

    private func firstPredictions() throws {
        let frame = try Self.grayFrame(side: 64)
        // A click with a box first (a person under the click): the box decoder's first prediction builds its plan
        // here too (~0.1-0.2 s, which landed on the user's first frame).
        _ = try EdgeTAMSession(self).click(frame, point: Vec2(0.5, 0.5), box: SubjectTrackBox(x0: 0.25, y0: 0.25, x1: 0.75, y1: 0.75))
        let session = EdgeTAMSession(self)
        _ = try session.click(frame, point: Vec2(0.5, 0.5), box: nil)
        // The tracked frame through the look-ahead, as a run's frames go.
        let next = try Self.grayFrame(side: 64)
        session.lookAhead(next)
        let out = try session.track(next)
        try session.commit()
        let n = SubjectTrackRules.logitSize * SubjectTrackRules.logitSize
        guard out.logits.count == n, !out.logits.contains(where: { !$0.isFinite }) else {
            throw SubjectTrackError.prediction("the model's answer is not a mask")
        }
    }
}

/// The memory bookkeeping of the reference tracker for one object and one conditioning frame: memory slot 0 holds
/// the conditioning frame, the up to six frames before this one fill the slots from the end (nearest last), the
/// object pointers are the conditioning frame's and then the recent ones, newest first.
final class EdgeTAMSession: SubjectTrackSession {
    private struct Features {
        let vision: MLMultiArray, noMemory: MLMultiArray, high0: MLMultiArray, high1: MLMultiArray
    }

    private typealias Entry = (memory: [Float], pointer: [Float])
    private let model: EdgeTAMModel
    private var square: CVPixelBuffer?
    /// The look-ahead's own model square (its encoder may still read it while `square` is filled for this frame).
    private var aheadSquare: CVPixelBuffer?
    /// The next frame's features, encoded beside this frame's other predictions (`lookAhead`).
    private let ahead = SubjectLookAhead<Features>(label: "sq.subjectmask.encode-ahead")
    /// The last whole frame encoded: a pick asks the same frame up to five times (prompts), encoded once. Holds the
    /// frame, so its buffer is not handed out again for another picture while it is here.
    private var encoded: (frame: CVPixelBuffer, features: Features)?
    private var conditioning: Entry?
    private var recent: [Entry] = []   // newest last
    private var pending: (features: Features, pix: MLMultiArray, low: MLMultiArray, pointer: [Float], logits: [Float])?
    /// The last `corrections`: the frame and points they answered and the mask token behind each candidate.
    private var offered: (features: Features, pix: MLMultiArray, points: [(Double, Double, Float)], tokens: [Int])?
    /// Which tracked frames enter `recent` (the conditioning entry always stays). SQ_MASK_MEM_GATE="distance,certainty"
    /// overrides it for the benchmark.
    private var gate = EdgeTAMSession.defaultGate
    static let defaultGate: SubjectMemoryGate = {
        let env = ProcessInfo.processInfo.environment
        guard env["SQ_MASK_BENCH"] == "1" else { return .tracker }   // the override is a benchmark knob only
        let parts = (env["SQ_MASK_MEM_GATE"] ?? "").split(separator: ",")
        guard parts.count == 2, let d = Int(parts[0]), let c = Double(parts[1]) else { return .tracker }
        return SubjectMemoryGate(minDistance: d, minCertainty: c)
    }()

    init(_ model: EdgeTAMModel) { self.model = model }

    // MARK: Arrays

    static func floats(_ array: MLMultiArray) throws -> [Float] {
        switch array.dataType {
        case .float32: return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        #if arch(arm64)
        case .float16: return array.withUnsafeBufferPointer(ofType: Float16.self) { $0.map { Float($0) } }
        #endif
        default: throw SubjectTrackError.prediction("unexpected array type \(array.dataType.rawValue)")
        }
    }

    static func makeArray(_ shape: [Int], _ fill: (UnsafeMutableBufferPointer<Float>) -> Void = { _ in }) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
            pointer.initialize(repeating: 0)
            fill(pointer)
        }
        return array
    }

    private func array(_ provider: any MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let value = provider.featureValue(for: name)?.multiArrayValue else { throw SubjectTrackError.prediction("missing output \(name)") }
        return value
    }

    // MARK: Parts

    /// The frame stretched onto the model square `square`.
    private static func stretched(_ frame: CVPixelBuffer, crop: SubjectTrackBox? = nil, onto square: inout CVPixelBuffer?) throws -> CVPixelBuffer {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { throw SubjectTrackError.badFrame("not BGRA") }
        let side = SubjectTrackRules.modelSize
        if square == nil {
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
            var made: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attrs, &made) == kCVReturnSuccess else {
                throw SubjectTrackError.badFrame("no model frame")
            }
            square = made
        }
        guard let target = square else { throw SubjectTrackError.badFrame("no model frame") }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(target, [])
        defer { CVPixelBufferUnlockBaseAddress(target, []); CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let src = CVPixelBufferGetBaseAddress(frame), let dst = CVPixelBufferGetBaseAddress(target) else {
            throw SubjectTrackError.badFrame("no pixels")
        }
        let fw = CVPixelBufferGetWidth(frame), fh = CVPixelBufferGetHeight(frame), stride = CVPixelBufferGetBytesPerRow(frame)
        // The part of the frame that goes onto the square (all of it, or the crop).
        var cx = 0, cy = 0, cw = fw, ch = fh
        if let crop {
            cx = min(max(Int((crop.x0 * Double(fw)).rounded()), 0), fw - 1); cy = min(max(Int((crop.y0 * Double(fh)).rounded()), 0), fh - 1)
            cw = max(1, min(Int((crop.x1 * Double(fw)).rounded()) - cx, fw - cx)); ch = max(1, min(Int((crop.y1 * Double(fh)).rounded()) - cy, fh - cy))
        }
        var from = vImage_Buffer(data: src.advanced(by: cy * stride + cx * 4), height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: stride)
        var to = vImage_Buffer(data: dst, height: vImagePixelCount(side), width: vImagePixelCount(side), rowBytes: CVPixelBufferGetBytesPerRow(target))
        guard vImageScale_ARGB8888(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else {
            throw SubjectTrackError.badFrame("scale failed")
        }
        return target
    }

    private static func encode(_ model: EdgeTAMModel, _ frame: CVPixelBuffer, crop: SubjectTrackBox?, onto square: inout CVPixelBuffer?) throws -> Features {
        let input = try SubjectMaskTiming.measure("stretch") { try stretched(frame, crop: crop, onto: &square) }
        let out = try model.run("encoder", model.encoder, ["image": MLFeatureValue(pixelBuffer: input)])
        func array(_ name: String) throws -> MLMultiArray {
            guard let value = out.featureValue(for: name)?.multiArrayValue else { throw SubjectTrackError.prediction("missing output \(name)") }
            return value
        }
        return Features(vision: try array("vision_feat"), noMemory: try array("feat_no_mem"), high0: try array("high_res_0"), high1: try array("high_res_1"))
    }

    private func encode(_ frame: CVPixelBuffer, crop: SubjectTrackBox? = nil) throws -> Features {
        if crop != nil { return try Self.encode(model, frame, crop: crop, onto: &square) }
        if let e = encoded, e.frame === frame { return e.features }
        let features: Features
        if let early = try SubjectMaskTiming.measure("ahead_wait", { try ahead.take(frame) }) {
            features = early
        } else {
            features = try Self.encode(model, frame, crop: nil, onto: &square)
        }
        encoded = (frame, features)
        return features
    }

    func lookAhead(_ frame: CVPixelBuffer) {
        if let e = encoded, e.frame === frame { return }
        let model = model
        ahead.start(frame) { [self] in
            // Only the look-ahead's thread touches `aheadSquare` (one look-ahead at a time).
            try Self.encode(model, frame, crop: nil, onto: &aheadSquare)
        }
    }

    private struct Decoded {
        var logits: [Float], score: Float, ious: [Float], low: MLMultiArray, pointer: [Float], all: MLMultiArray
    }

    /// `points`: (x, y, label) in model pixels; none = tracked frame, one = click, three = box corners + click.
    /// `choice`: mask token to keep, nil = the candidate the model rates best.
    private func decode(_ pixFeat: MLMultiArray, _ features: Features, points: [(Double, Double, Float)], choice: Int?) throws -> Decoded {
        let slots = points.count == 3 ? 3 : 1
        let coords = try Self.makeArray([1, slots, 2]) { target in
            for (index, point) in points.enumerated() { target[index * 2] = Float(point.0); target[index * 2 + 1] = Float(point.1) }
        }
        let labels = try Self.makeArray([1, slots]) { target in
            target[0] = -1
            for (index, point) in points.enumerated() { target[index] = point.2 }
        }
        let pick = try Self.makeArray([1, 4]) { if let choice { $0[choice] = 1 } }
        let out = try model.run(slots == 3 ? "decoder_box" : "decoder", slots == 3 ? model.decoderBox : model.decoder, [
            "pix_feat": MLFeatureValue(multiArray: pixFeat), "high_res_0": MLFeatureValue(multiArray: features.high0),
            "high_res_1": MLFeatureValue(multiArray: features.high1), "point_coords": MLFeatureValue(multiArray: coords),
            "point_labels": MLFeatureValue(multiArray: labels), "choice": MLFeatureValue(multiArray: pick),
        ])
        let unpacked = SubjectMaskTiming.now()
        defer { SubjectMaskTiming.count("unpack", since: unpacked) }
        let low = try array(out, "low_res_mask")
        let logits = try Self.floats(low)
        guard logits.count == SubjectTrackRules.logitSize * SubjectTrackRules.logitSize else {
            throw SubjectTrackError.prediction("mask of \(logits.count) values")
        }
        return Decoded(logits: logits, score: try Self.floats(array(out, "object_score")).first ?? 0, ious: try Self.floats(array(out, "ious")),
                       low: low, pointer: try Self.floats(array(out, "obj_ptr")), all: try array(out, "all_masks"))
    }

    private func remember(_ features: Features, _ low: MLMultiArray, isClick: Bool) throws -> [Float] {
        let flag = try Self.makeArray([1]) { $0[0] = isClick ? 1 : 0 }
        let out = try model.run("mem_encoder", model.memoryEncoder, [
            "vision_feat": MLFeatureValue(multiArray: features.vision), "low_res_mask": MLFeatureValue(multiArray: low),
            "is_click": MLFeatureValue(multiArray: flag),
        ])
        return try Self.floats(array(out, "memory"))
    }

    // MARK: SubjectTrackSession

    func click(_ frame: CVPixelBuffer, point: Vec2, box: SubjectTrackBox?) throws -> SubjectTrackOutput {
        let features = try encode(frame)
        let p = SubjectTrackRules.modelPoint(point)
        var decoded: Decoded
        if let box {
            // A box is answered with the single-mask token (the reference code's rule).
            let b = SubjectTrackRules.modelBox(box)
            decoded = try decode(features.noMemory, features, points: [(b.x0, b.y0, 2), (b.x1, b.y1, 3), (p.x, p.y, 1)], choice: 0)
        } else {
            decoded = try decode(features.noMemory, features, points: [(p.x, p.y, 1)], choice: nil)
            let all = try Self.floats(decoded.all)
            let n = SubjectTrackRules.logitSize * SubjectTrackRules.logitSize
            if all.count == 4 * n, decoded.ious.count == 4 {
                let areas = (0..<4).map { t in Double(all[t * n..<(t + 1) * n].reduce(0) { $0 + ($1 > 0 ? 1 : 0) }) / Double(n) }
                let largest = SubjectTrackRules.largestCandidate(areas: areas, ious: decoded.ious)
                let best = (1...3).max { decoded.ious[$0] < decoded.ious[$1] } ?? 1
                if largest != best { decoded = try decode(features.noMemory, features, points: [(p.x, p.y, 1)], choice: largest) }
            }
        }
        conditioning = (try remember(features, decoded.low, isClick: true), decoded.pointer)
        recent = []; pending = nil; gate.reset()
        return SubjectTrackOutput(logits: decoded.logits, score: decoded.score)
    }

    func condition(_ frame: CVPixelBuffer, matte: SubjectMatte) throws {
        guard let box = SubjectTrackRules.box(of: matte), let inside = SubjectTrackRules.interiorPoint(of: matte) else { throw SubjectTrackError.emptyMatte }
        let features = try encode(frame)
        // The pointer (what the object is) comes from the decoder asked with the matte's box and a point on it; the
        // memory (where it is on this frame) is the matte itself, as given.
        let b = SubjectTrackRules.modelBox(box), p = SubjectTrackRules.modelPoint(inside)
        let decoded = try decode(features.noMemory, features, points: [(b.x0, b.y0, 2), (b.x1, b.y1, 3), (p.x, p.y, 1)], choice: 0)
        let size = SubjectTrackRules.logitSize
        let given = SubjectTrackRules.logits(from: matte, size: size)
        let low = try Self.makeArray(decoded.low.shape.map(\.intValue)) { target in
            for i in 0..<min(target.count, given.count) { target[i] = given[i] }
        }
        conditioning = (try remember(features, low, isClick: true), decoded.pointer)
        recent = []; pending = nil; gate.reset()
    }

    func track(_ frame: CVPixelBuffer) throws -> SubjectTrackOutput {
        guard let conditioning else { throw SubjectTrackError.notConditioned }
        let features = try encode(frame)
        let slots = EdgeTAMModel.memorySlots, slotSize = EdgeTAMModel.memoryTokens * EdgeTAMModel.memoryDim
        let pointers = EdgeTAMModel.pointerSlots, dim = EdgeTAMModel.pointerDim
        guard conditioning.memory.count == slotSize, conditioning.pointer.count == dim else { throw SubjectTrackError.prediction("memory of another shape") }
        // Only entries of the right shape are written, and only those are marked valid.
        let packed = SubjectMaskTiming.now()
        let recentMemory = Array(recent.filter { $0.memory.count == slotSize }.suffix(slots - 1).reversed())
        let recentPointers = Array(recent.filter { $0.pointer.count == dim }.suffix(pointers - 1).reversed())
        let memory = try Self.makeArray([1, slots, EdgeTAMModel.memoryTokens, EdgeTAMModel.memoryDim]) { target in
            conditioning.memory.withUnsafeBufferPointer { _ = UnsafeMutableBufferPointer(rebasing: target[0..<slotSize]).update(fromContentsOf: $0) }
            for (back, entry) in recentMemory.enumerated() {
                let slot = slots - 1 - back   // nearest frame -> last slot
                entry.memory.withUnsafeBufferPointer {
                    _ = UnsafeMutableBufferPointer(rebasing: target[slot * slotSize..<(slot + 1) * slotSize]).update(fromContentsOf: $0)
                }
            }
        }
        let memoryValid = try Self.makeArray([1, slots]) { target in
            target[0] = 1
            for back in 0..<recentMemory.count { target[slots - 1 - back] = 1 }
        }
        let pointerArray = try Self.makeArray([1, pointers, dim]) { target in
            for i in 0..<dim { target[i] = conditioning.pointer[i] }
            for (index, entry) in recentPointers.enumerated() {
                for i in 0..<dim { target[(index + 1) * dim + i] = entry.pointer[i] }
            }
        }
        let pointerValid = try Self.makeArray([1, pointers]) { target in
            for index in 0...recentPointers.count { target[index] = 1 }
        }
        SubjectMaskTiming.count("pack", since: packed)
        let attended = try model.run("mem_attention", model.memoryAttention, [
            "vision_feat": MLFeatureValue(multiArray: features.vision), "memory": MLFeatureValue(multiArray: memory),
            "memory_valid": MLFeatureValue(multiArray: memoryValid), "obj_ptrs": MLFeatureValue(multiArray: pointerArray),
            "ptr_valid": MLFeatureValue(multiArray: pointerValid),
        ])
        let pix = try array(attended, "pix_feat")
        let decoded = try decode(pix, features, points: [], choice: nil)
        pending = (features, pix, decoded.low, decoded.pointer, decoded.logits)
        offered = nil
        return SubjectTrackOutput(logits: decoded.logits, score: decoded.score)
    }

    /// The second pass: the crop stretched onto the model square, asked with the first answer's box (in crop
    /// coordinates) and a point inside it, as a click is. No memory is read or written.
    func refine(_ frame: CVPixelBuffer, crop: SubjectTrackBox, box: SubjectTrackBox, inside: Vec2) throws -> [Float]? {
        guard crop.width > 0, crop.height > 0 else { return nil }
        let features = try encode(frame, crop: crop)
        func local(_ x: Double, _ y: Double) -> (Double, Double) { ((x - crop.x0) / crop.width, (y - crop.y0) / crop.height) }
        let a = local(box.x0, box.y0), b = local(box.x1, box.y1), c = local(inside.x, inside.y)
        let m = SubjectTrackBox(x0: min(max(a.0, 0), 1), y0: min(max(a.1, 0), 1), x1: min(max(b.0, 0), 1), y1: min(max(b.1, 0), 1))
        let box = SubjectTrackRules.modelBox(m), p = SubjectTrackRules.modelPoint(Vec2(min(max(c.0, 0), 1), min(max(c.1, 0), 1)))
        let decoded = try decode(features.noMemory, features, points: [(box.x0, box.y0, 2), (box.x1, box.y1, 3), (p.x, p.y, 1)], choice: 0)
        return decoded.score > 0 ? decoded.logits : nil
    }

    func corrections(_ points: [MagicPoint]) throws -> [[Float]] {
        guard let p = pending, !points.isEmpty else { return [] }
        // One point: the one-point decoder; two or three: the three-slot one, padded with "no point" (-1). More: the last three.
        var asked: [(Double, Double, Float)] = points.suffix(3).map {
            let m = SubjectTrackRules.modelPoint($0.position)
            return (m.x, m.y, $0.subtract ? 0 : 1)
        }
        if asked.count == 2 { asked.append((0, 0, -1)) }
        let decoded = try decode(p.pix, p.features, points: asked, choice: nil)
        let all = try Self.floats(decoded.all)
        let n = SubjectTrackRules.logitSize * SubjectTrackRules.logitSize
        guard all.count == 4 * n, decoded.ious.count == 4 else {
            offered = (p.features, p.pix, asked, [-1])
            return [decoded.logits]
        }
        let tokens = (0..<4).sorted { decoded.ious[$0] > decoded.ious[$1] }
        offered = (p.features, p.pix, asked, tokens)
        return tokens.map { Array(all[$0 * n..<($0 + 1) * n]) }
    }

    func adoptCorrection(_ index: Int, reseed: Bool) throws {
        guard let o = offered, o.tokens.indices.contains(index) else { return }
        let token = o.tokens[index]
        let decoded = try decode(o.pix, o.features, points: o.points, choice: token < 0 ? nil : token)
        pending = nil; offered = nil
        if reseed {
            conditioning = (try remember(o.features, decoded.low, isClick: true), decoded.pointer)
            recent = []; gate.reset()
        } else {
            recent.append((try remember(o.features, decoded.low, isClick: true), decoded.pointer))
            recent = Array(recent.suffix(EdgeTAMModel.pointerSlots - 1))
        }
    }

    func commit() throws {
        guard let p = pending else { return }
        pending = nil
        guard SubjectMaskTiming.measure("gate", { gate.admit(logits: p.logits) }) else { return }
        recent.append((try remember(p.features, p.low, isClick: false), p.pointer))
        recent = Array(recent.suffix(EdgeTAMModel.pointerSlots - 1))
    }
}

/// The box of the person under a point, from Vision's person instance mask (it separates people that the foreground
/// mask joins): the best prompt for a click on a person. nil when no person is under the point or Vision fails.
enum SubjectPersonBox {
    /// One request on a gray picture (it finds nobody): Vision loads its person model.
    static func warmUp() {
        guard let frame = try? EdgeTAMModel.grayFrame(side: 256) else { return }
        _ = try? VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up).perform([VNGeneratePersonInstanceMaskRequest()])
    }

    static func find(_ frame: CVPixelBuffer, at p: Vec2) -> SubjectTrackBox? {
        let request = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up)
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first else { return nil }
        let labels = observation.instanceMask
        guard CVPixelBufferGetPixelFormatType(labels) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddress(labels) else { return nil }
        let w = CVPixelBufferGetWidth(labels), h = CVPixelBufferGetHeight(labels), row = CVPixelBufferGetBytesPerRow(labels)
        guard w > 0, h > 0, p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return nil }
        let base = raw.assumingMemoryBound(to: UInt8.self)
        let label = base[min(Int(p.y * Double(h)), h - 1) * row + min(Int(p.x * Double(w)), w - 1)]
        // Only a label Vision lists is a person (0 and anything else is background).
        guard label != 0, observation.allInstances.contains(Int(label)) else { return nil }
        // The piece of that label that holds the click: Vision's labels carry stray specks across the picture, and the
        // box of all of them is the whole frame (which the guard below then threw away: no person box on most clips).
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where base[y * row + x] == label { values[y * w + x] = 1 } }
        guard let found = SubjectTrackRules.piecesBox(in: SubjectMatte(width: w, height: h, values: values), at: p) else { return nil }
        // A box that is the whole picture says nothing about which subject is meant.
        guard found.area < 0.9 else { return nil }
        return found
    }
}
