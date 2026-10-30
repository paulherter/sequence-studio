import Foundation
import SQCore
import SQOnnx

// EdgeTAM on ONNX Runtime (the Windows backend of the subject mask; the Mac runs the same five parts as Core ML in
// EdgeTAM.swift). Same parts, same inputs and outputs, same memory bookkeeping; plain float arrays and an RGBA8 picture
// instead of MLMultiArray and CVPixelBuffer, so this file builds on both platforms. Model files: docs/THIRD_PARTY.md.
// shortcut: the session keeps the Mac session's logic by copy (memory packing, candidate choice), no look-ahead encoder
// thread and no prediction deadline; upgrade by moving the shared bookkeeping out of EdgeTAM.swift into one portable type.

/// An RGBA8 picture, rows tightly packed, origin top left.
public struct SubjectFrame: Sendable {
    public var width: Int, height: Int
    public var rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "SubjectFrame size mismatch")
        self.width = width; self.height = height; self.rgba = rgba
    }

    /// The picture turned clockwise by `degrees` (a multiple of 90, the file's rotation tag) so that it is upright, as
    /// the Mac analysis frames are: a pick point is a fraction of the upright picture and the mattes are stored upright.
    public func upright(rotation degrees: Int) -> SubjectFrame {
        let q = ((degrees / 90) % 4 + 4) % 4
        guard q != 0 else { return self }
        let (w, h) = (width, height)
        let (nw, nh) = q == 2 ? (w, h) : (h, w)
        var out = [UInt8](repeating: 0, count: rgba.count)
        for y in 0..<h {
            for x in 0..<w {
                // Clockwise: (x, y) of the source lands at (h-1-y, x); twice: (w-1-x, h-1-y); counter-clockwise: (y, w-1-x).
                let (dx, dy) = q == 1 ? (h - 1 - y, x) : (q == 2 ? (w - 1 - x, h - 1 - y) : (y, w - 1 - x))
                let s = (y * w + x) * 4, d = (dy * nw + dx) * 4
                out[d] = rgba[s]; out[d + 1] = rgba[s + 1]; out[d + 2] = rgba[s + 2]; out[d + 3] = rgba[s + 3]
            }
        }
        return SubjectFrame(width: nw, height: nh, rgba: out)
    }
}

/// What the tracking model said about one frame.
public struct EdgeTAMAnswer: Sendable {
    /// `SubjectTrackRules.logitSize` squared logits over the whole (stretched) frame.
    public var logits: [Float]
    /// > 0: the object is on this frame.
    public var score: Float
}

public enum EdgeTAMOnnxError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case notConditioned
    case badAnswer(String)
    public var description: String {
        switch self {
        case .missing(let s): "EdgeTAM model: \(s)"
        case .notConditioned: "the session has no click yet"
        case .badAnswer(let s): "EdgeTAM answered wrongly: \(s)"
        }
    }
}

/// Where the five ONNX parts are: `SQ_SUBJECT_MASK_MODELS`, a `SubjectMask` folder next to the exe, then
/// `%LOCALAPPDATA%\SequenceStudio\SubjectMask`.
public enum EdgeTAMOnnxLocation {
    public static let names = ["encoder", "decoder", "decoder_box", "mem_encoder", "mem_attention"]

    public static func file(_ name: String, in dir: URL) -> URL { dir.appendingPathComponent("edgetam_\(name).onnx") }

    public static func complete(_ dir: URL) -> Bool {
        names.allSatisfy { FileManager.default.fileExists(atPath: file($0, in: dir).path) }
    }

    public static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var out: [URL] = []
        if let env = environment["SQ_SUBJECT_MASK_MODELS"], !env.isEmpty { out.append(URL(fileURLWithPath: env)) }
        if let exe = Bundle.main.executableURL { out.append(exe.deletingLastPathComponent().appendingPathComponent("SubjectMask")) }
        if let local = environment["LOCALAPPDATA"], !local.isEmpty {
            out.append(URL(fileURLWithPath: local).appendingPathComponent("SequenceStudio/SubjectMask"))
        }
        return out
    }

    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        candidates(environment: environment).first(where: complete)
    }
}

/// The loaded parts. Predictions of all sessions run one at a time.
public final class EdgeTAMOnnxModel: @unchecked Sendable {
    static let memorySlots = 7, memoryTokens = 512, memoryDim = 64, pointerSlots = 16, pointerDim = 256
    let encoder: OnnxModel, decoder: OnnxModel, decoderBox: OnnxModel, memoryEncoder: OnnxModel, memoryAttention: OnnxModel
    private let lock = NSLock()
    /// Seconds spent in each part since the last `takeTimings`, by name (for the bench and the log).
    private var timings: [String: (seconds: Double, count: Int)] = [:]

    /// Loads all parts (`directML`: the DirectML provider; false = CPU only).
    public init(directory: URL, directML: Bool = true, device: Int? = nil) throws {
        func load(_ name: String) throws -> OnnxModel {
            let file = EdgeTAMOnnxLocation.file(name, in: directory)
            guard FileManager.default.fileExists(atPath: file.path) else { throw EdgeTAMOnnxError.missing(file.path) }
            return try OnnxModel(path: file.path, directML: directML, device: device)
        }
        encoder = try load("encoder"); decoder = try load("decoder"); decoderBox = try load("decoder_box")
        memoryEncoder = try load("mem_encoder"); memoryAttention = try load("mem_attention")
    }

    public func makeSession() -> EdgeTAMOnnxSession { EdgeTAMOnnxSession(self) }

    func run(_ name: String, _ model: OnnxModel, _ inputs: [String: OnnxTensor]) throws -> [String: OnnxTensor] {
        lock.lock(); defer { lock.unlock() }
        let began = ContinuousClock.now
        let out = try model.run(inputs)
        let spent = ContinuousClock.now - began
        let seconds = Double(spent.components.seconds) + Double(spent.components.attoseconds) / 1e18
        let old = timings[name] ?? (0, 0)
        timings[name] = (old.seconds + seconds, old.count + 1)
        return Dictionary(uniqueKeysWithValues: zip(model.outputNames, out))
    }

    /// Per part: total seconds and calls since the last call.
    public func takeTimings() -> [String: (seconds: Double, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        defer { timings = [:] }
        return timings
    }

    /// The frame stretched onto the model's square, RGB 0...1, planar (1, 3, side, side). `crop`: frame fractions.
    static func input(_ frame: SubjectFrame, crop: SubjectTrackBox? = nil) -> OnnxTensor {
        let side = SubjectTrackRules.modelSize
        var cx = 0, cy = 0, cw = frame.width, ch = frame.height
        if let crop {
            cx = min(max(Int((crop.x0 * Double(frame.width)).rounded()), 0), frame.width - 1)
            cy = min(max(Int((crop.y0 * Double(frame.height)).rounded()), 0), frame.height - 1)
            cw = max(1, min(Int((crop.x1 * Double(frame.width)).rounded()) - cx, frame.width - cx))
            ch = max(1, min(Int((crop.y1 * Double(frame.height)).rounded()) - cy, frame.height - cy))
        }
        var data = [Float](repeating: 0, count: 3 * side * side)
        // Bilinear on pixel centers; a shrink by more than 2 averages a 2 x 2 block per tap so the picture is not aliased.
        let sx = Double(cw) / Double(side), sy = Double(ch) / Double(side)
        let wide = max(sx, sy) > 2
        let plane = side * side
        frame.rgba.withUnsafeBufferPointer { px in
            data.withUnsafeMutableBufferPointer { out in
                // Column taps once.
                var x0s = [Int](repeating: 0, count: side), x1s = x0s, fxs = [Float](repeating: 0, count: side)
                for x in 0..<side {
                    let fx = (Double(x) + 0.5) * sx - 0.5
                    let i = Int(fx.rounded(.down))
                    x0s[x] = min(max(i, 0), cw - 1); x1s[x] = min(max(i + 1, 0), cw - 1)
                    fxs[x] = Float(min(max(fx - Double(i), 0), 1))
                }
                for y in 0..<side {
                    let fy = (Double(y) + 0.5) * sy - 0.5
                    let j = Int(fy.rounded(.down))
                    let y0 = min(max(j, 0), ch - 1), y1 = min(max(j + 1, 0), ch - 1)
                    let ty = Float(min(max(fy - Double(j), 0), 1))
                    for x in 0..<side {
                        let tx = fxs[x]
                        for c in 0..<3 {
                            func at(_ xx: Int, _ yy: Int) -> Float { Float(px[((cy + yy) * frame.width + cx + xx) * 4 + c]) }
                            var a = at(x0s[x], y0), b = at(x1s[x], y0), d = at(x0s[x], y1), e = at(x1s[x], y1)
                            if wide {
                                // The neighbors one source pixel further out, for the box average.
                                a = (a + at(min(x0s[x] + 1, cw - 1), y0) + at(x0s[x], min(y0 + 1, ch - 1)) + at(min(x0s[x] + 1, cw - 1), min(y0 + 1, ch - 1))) / 4
                                b = (b + at(min(x1s[x] + 1, cw - 1), y0) + at(x1s[x], min(y0 + 1, ch - 1)) + at(min(x1s[x] + 1, cw - 1), min(y0 + 1, ch - 1))) / 4
                                d = (d + at(min(x0s[x] + 1, cw - 1), y1) + at(x0s[x], min(y1 + 1, ch - 1)) + at(min(x0s[x] + 1, cw - 1), min(y1 + 1, ch - 1))) / 4
                                e = (e + at(min(x1s[x] + 1, cw - 1), y1) + at(x1s[x], min(y1 + 1, ch - 1)) + at(min(x1s[x] + 1, cw - 1), min(y1 + 1, ch - 1))) / 4
                            }
                            let top = a + (b - a) * tx, bottom = d + (e - d) * tx
                            out[c * plane + y * side + x] = (top + (bottom - top) * ty) / 255
                        }
                    }
                }
            }
        }
        return OnnxTensor(shape: [1, 3, side, side], data: data)
    }
}

/// The memory bookkeeping of the reference tracker for one object and one conditioning frame (see EdgeTAMSession).
public final class EdgeTAMOnnxSession: @unchecked Sendable {
    private struct Features { let vision: OnnxTensor, noMemory: OnnxTensor, high0: OnnxTensor, high1: OnnxTensor }
    private typealias Entry = (memory: [Float], pointer: [Float])
    private struct Decoded { var logits: [Float], score: Float, ious: [Float], low: OnnxTensor, pointer: [Float], all: [Float] }

    private let model: EdgeTAMOnnxModel
    private var encoded: (frame: SubjectFrame, features: Features)?
    private var conditioning: Entry?
    private var recent: [Entry] = []   // newest last
    private var pending: (features: Features, pix: OnnxTensor, low: OnnxTensor, pointer: [Float], logits: [Float])?
    private var gate = SubjectMemoryGate.tracker

    init(_ model: EdgeTAMOnnxModel) { self.model = model }

    private func encode(_ frame: SubjectFrame, crop: SubjectTrackBox? = nil) throws -> Features {
        if crop == nil, let e = encoded, e.frame.width == frame.width, e.frame.height == frame.height, e.frame.rgba == frame.rgba {
            return e.features
        }
        let out = try model.run("encoder", model.encoder, ["image": EdgeTAMOnnxModel.input(frame, crop: crop)])
        func part(_ n: String) throws -> OnnxTensor {
            guard let t = out[n] else { throw EdgeTAMOnnxError.badAnswer("encoder has no \(n)") }
            return t
        }
        let features = Features(vision: try part("vision_feat"), noMemory: try part("feat_no_mem"),
                                high0: try part("high_res_0"), high1: try part("high_res_1"))
        if crop == nil { encoded = (frame, features) }
        return features
    }

    /// `points`: (x, y, label) in model pixels; none = tracked frame, one = click, three = box corners + click.
    private func decode(_ pixFeat: OnnxTensor, _ features: Features, points: [(Double, Double, Float)], choice: Int?) throws -> Decoded {
        let slots = points.count == 3 ? 3 : 1
        var coords = OnnxTensor(shape: [1, slots, 2])
        var labels = OnnxTensor(shape: [1, slots])
        labels.data[0] = -1
        for (i, p) in points.enumerated() { coords.data[i * 2] = Float(p.0); coords.data[i * 2 + 1] = Float(p.1); labels.data[i] = p.2 }
        var pick = OnnxTensor(shape: [1, 4])
        if let choice { pick.data[choice] = 1 }
        let out = try model.run(slots == 3 ? "decoder_box" : "decoder", slots == 3 ? model.decoderBox : model.decoder, [
            "pix_feat": pixFeat, "high_res_0": features.high0, "high_res_1": features.high1,
            "point_coords": coords, "point_labels": labels, "choice": pick,
        ])
        guard let low = out["low_res_mask"], let ptr = out["obj_ptr"], let score = out["object_score"], let ious = out["ious"],
              let all = out["all_masks"] else { throw EdgeTAMOnnxError.badAnswer("the decoder lacks an output") }
        guard low.data.count == SubjectTrackRules.logitSize * SubjectTrackRules.logitSize else {
            throw EdgeTAMOnnxError.badAnswer("mask of \(low.data.count) values")
        }
        return Decoded(logits: low.data, score: score.data.first ?? 0, ious: ious.data, low: low, pointer: ptr.data, all: all.data)
    }

    private func remember(_ features: Features, _ low: OnnxTensor, isClick: Bool) throws -> [Float] {
        let out = try model.run("mem_encoder", model.memoryEncoder, [
            "vision_feat": features.vision, "low_res_mask": low, "is_click": OnnxTensor(shape: [1], data: [isClick ? 1 : 0]),
        ])
        guard let memory = out["memory"] else { throw EdgeTAMOnnxError.badAnswer("no memory") }
        return memory.data
    }

    /// Conditions on a click (frame fractions), with a box around the subject when one is known. Without a box the
    /// largest candidate the model trusts is kept.
    public func click(_ frame: SubjectFrame, point: Vec2, box: SubjectTrackBox?) throws -> EdgeTAMAnswer {
        let features = try encode(frame)
        let p = SubjectTrackRules.modelPoint(point)
        var decoded: Decoded
        if let box {
            let b = SubjectTrackRules.modelBox(box)
            decoded = try decode(features.noMemory, features, points: [(b.x0, b.y0, 2), (b.x1, b.y1, 3), (p.x, p.y, 1)], choice: 0)
        } else {
            decoded = try decode(features.noMemory, features, points: [(p.x, p.y, 1)], choice: nil)
            let n = SubjectTrackRules.logitSize * SubjectTrackRules.logitSize
            if decoded.all.count == 4 * n, decoded.ious.count == 4 {
                let areas = (0..<4).map { t in Double(decoded.all[t * n..<(t + 1) * n].reduce(0) { $0 + ($1 > 0 ? 1 : 0) }) / Double(n) }
                let largest = SubjectTrackRules.largestCandidate(areas: areas, ious: decoded.ious)
                let best = (1...3).max { decoded.ious[$0] < decoded.ious[$1] } ?? 1
                if largest != best { decoded = try decode(features.noMemory, features, points: [(p.x, p.y, 1)], choice: largest) }
            }
        }
        conditioning = (try remember(features, decoded.low, isClick: true), decoded.pointer)
        recent = []; pending = nil; gate.reset()
        return EdgeTAMAnswer(logits: decoded.logits, score: decoded.score)
    }

    /// Conditions on a Magic pick: the clicks of one frame (frame fractions, `subtract` = take the area out). One adding
    /// click is `click`; more (or a removing one) go through the three-slot decoder with the last three, as the Mac
    /// corrections do, and keep the model's best candidate.
    public func pick(_ frame: SubjectFrame, points: [(point: Vec2, subtract: Bool)]) throws -> EdgeTAMAnswer {
        guard let first = points.first else { throw EdgeTAMOnnxError.badAnswer("no point") }
        if points.count == 1, !first.subtract { return try click(frame, point: first.point, box: nil) }
        let features = try encode(frame)
        var asked: [(Double, Double, Float)] = points.suffix(3).map {
            let m = SubjectTrackRules.modelPoint($0.point)
            return (m.x, m.y, $0.subtract ? 0 : 1)
        }
        if asked.count == 2 { asked.append((0, 0, -1)) }
        let decoded = try decode(features.noMemory, features, points: asked, choice: nil)
        conditioning = (try remember(features, decoded.low, isClick: true), decoded.pointer)
        recent = []; pending = nil; gate.reset()
        return EdgeTAMAnswer(logits: decoded.logits, score: decoded.score)
    }

    /// Conditions on a matte of this frame (a corrected or earlier tracked one).
    public func condition(_ frame: SubjectFrame, matte: SubjectMatte) throws {
        guard let box = SubjectTrackRules.box(of: matte), let inside = SubjectTrackRules.interiorPoint(of: matte) else {
            throw EdgeTAMOnnxError.badAnswer("empty matte")
        }
        let features = try encode(frame)
        let b = SubjectTrackRules.modelBox(box), p = SubjectTrackRules.modelPoint(inside)
        let decoded = try decode(features.noMemory, features, points: [(b.x0, b.y0, 2), (b.x1, b.y1, 3), (p.x, p.y, 1)], choice: 0)
        let given = SubjectTrackRules.logits(from: matte, size: SubjectTrackRules.logitSize)
        var low = decoded.low
        for i in 0..<min(low.data.count, given.count) { low.data[i] = given[i] }
        conditioning = (try remember(features, low, isClick: true), decoded.pointer)
        recent = []; pending = nil; gate.reset()
    }

    /// The subject on the next frame. Not remembered until `commit`.
    public func track(_ frame: SubjectFrame) throws -> EdgeTAMAnswer {
        guard let conditioning else { throw EdgeTAMOnnxError.notConditioned }
        let features = try encode(frame)
        let slots = EdgeTAMOnnxModel.memorySlots, slotSize = EdgeTAMOnnxModel.memoryTokens * EdgeTAMOnnxModel.memoryDim
        let pointers = EdgeTAMOnnxModel.pointerSlots, dim = EdgeTAMOnnxModel.pointerDim
        guard conditioning.memory.count == slotSize, conditioning.pointer.count == dim else {
            throw EdgeTAMOnnxError.badAnswer("memory of another shape")
        }
        let recentMemory = Array(recent.filter { $0.memory.count == slotSize }.suffix(slots - 1).reversed())
        let recentPointers = Array(recent.filter { $0.pointer.count == dim }.suffix(pointers - 1).reversed())
        var memory = OnnxTensor(shape: [1, slots, EdgeTAMOnnxModel.memoryTokens, EdgeTAMOnnxModel.memoryDim])
        memory.data.replaceSubrange(0..<slotSize, with: conditioning.memory)
        for (back, entry) in recentMemory.enumerated() {
            let slot = slots - 1 - back   // nearest frame -> last slot
            memory.data.replaceSubrange(slot * slotSize..<(slot + 1) * slotSize, with: entry.memory)
        }
        var memoryValid = OnnxTensor(shape: [1, slots])
        memoryValid.data[0] = 1
        for back in 0..<recentMemory.count { memoryValid.data[slots - 1 - back] = 1 }
        var pointerArray = OnnxTensor(shape: [1, pointers, dim])
        pointerArray.data.replaceSubrange(0..<dim, with: conditioning.pointer)
        for (index, entry) in recentPointers.enumerated() { pointerArray.data.replaceSubrange((index + 1) * dim..<(index + 2) * dim, with: entry.pointer) }
        var pointerValid = OnnxTensor(shape: [1, pointers])
        for index in 0...recentPointers.count { pointerValid.data[index] = 1 }
        let attended = try model.run("mem_attention", model.memoryAttention, [
            "vision_feat": features.vision, "memory": memory, "memory_valid": memoryValid,
            "obj_ptrs": pointerArray, "ptr_valid": pointerValid,
        ])
        guard let pix = attended["pix_feat"] else { throw EdgeTAMOnnxError.badAnswer("no pix_feat") }
        let decoded = try decode(pix, features, points: [], choice: nil)
        pending = (features, pix, decoded.low, decoded.pointer, decoded.logits)
        return EdgeTAMAnswer(logits: decoded.logits, score: decoded.score)
    }

    /// Adds the frame `track` just answered to the memory of recent frames (when the gate admits it).
    public func commit() throws {
        guard let p = pending else { return }
        pending = nil
        guard gate.admit(logits: p.logits) else { return }
        recent.append((try remember(p.features, p.low, isClick: false), p.pointer))
        recent = Array(recent.suffix(EdgeTAMOnnxModel.pointerSlots - 1))
    }
}
