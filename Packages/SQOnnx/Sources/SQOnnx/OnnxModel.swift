import CSQOnnx
import Foundation

/// A float32 tensor handed to or returned from a model.
public struct OnnxTensor: Sendable, Equatable {
    public var shape: [Int]
    public var data: [Float]
    public init(shape: [Int], data: [Float]) {
        precondition(shape.reduce(1, *) == data.count, "OnnxTensor shape does not match its data")
        self.shape = shape; self.data = data
    }
    /// A zero tensor.
    public init(shape: [Int]) { self.init(shape: shape, data: [Float](repeating: 0, count: shape.reduce(1, *))) }
}

public enum OnnxError: Error, Equatable, CustomStringConvertible {
    case unavailable(String)
    case failed(String)
    public var description: String {
        switch self { case .unavailable(let s), .failed(let s): s }
    }
}

/// One ONNX model on ONNX Runtime. Float32 inputs and outputs only (all five EdgeTAM parts are). Calls on one model
/// are serialized by the caller (ONNX Runtime allows parallel runs, DirectML on one device gains nothing from them).
public final class OnnxModel: @unchecked Sendable {
    private let session: OpaquePointer
    public let inputNames: [String]
    public let outputNames: [String]

    /// Loads the runtime once (`dll`: a full path to onnxruntime.dll; nil = next to the exe or on PATH). Throws
    /// `unavailable` when it cannot (the Mac, or the DLL is missing).
    public static func loadRuntime(dll: String? = nil) throws {
        var err = [CChar](repeating: 0, count: 512)
        if sqort_load(dll, &err, 512) != 0 { throw OnnxError.unavailable(String(cString: err)) }
    }

    public static var isAvailable: Bool { sqort_available() != 0 }

    /// `directML`: the DirectML provider on `device` (nil = the default adapter), the CPU for what it does not take.
    public init(path: String, directML: Bool, device: Int? = nil, threads: Int = 0) throws {
        if !Self.isAvailable { try Self.loadRuntime() }
        var err = [CChar](repeating: 0, count: 512)
        guard let s = sqort_open(path, directML ? 1 : 0, Int32(device ?? -1), Int32(threads), &err, 512) else {
            throw OnnxError.failed(String(cString: err))
        }
        session = s
        inputNames = (0..<Int(sqort_input_count(s))).map { String(cString: sqort_input_name(s, Int32($0))) }
        outputNames = (0..<Int(sqort_output_count(s))).map { String(cString: sqort_output_name(s, Int32($0))) }
    }

    deinit { sqort_close(session) }

    /// Runs the model. `inputs` are matched by name; every input the model has must be given (extras are ignored).
    /// The outputs come back in `outputNames` order.
    public func run(_ inputs: [String: OnnxTensor]) throws -> [OnnxTensor] {
        var ordered: [OnnxTensor] = []
        for name in inputNames {
            guard let t = inputs[name] else { throw OnnxError.failed("missing input \(name)") }
            ordered.append(t)
        }
        var err = [CChar](repeating: 0, count: 512)
        let count = outputNames.count
        var data = [UnsafeMutablePointer<Float>?](repeating: nil, count: count)
        var counts = [Int64](repeating: 0, count: count)
        var ranks = [Int32](repeating: 0, count: count)
        var dims = [Int64](repeating: 0, count: count * 8)
        let status: Int32 = withTensorPointers(ordered) { dataPointers, shapePointers, inRanks in
            sqort_run(session, dataPointers, shapePointers, inRanks, &data, &counts, &ranks, &dims, &err, 512)
        }
        if status != 0 { throw OnnxError.failed(String(cString: err)) }
        return (0..<count).map { i in
            let n = Int(counts[i])
            defer { sqort_free(data[i]) }
            let shape = (0..<Int(ranks[i])).map { Int(dims[i * 8 + $0]) }
            return OnnxTensor(shape: shape, data: data[i].map { Array(UnsafeBufferPointer(start: $0, count: n)) } ?? [])
        }
    }

    /// Pins every tensor's data and shape for the duration of `body`.
    private func withTensorPointers<R>(
        _ tensors: [OnnxTensor],
        _ body: (UnsafePointer<UnsafePointer<Float>?>, UnsafePointer<UnsafePointer<Int64>?>, UnsafePointer<Int32>) -> R
    ) -> R {
        let shapes: [[Int64]] = tensors.map { $0.shape.map(Int64.init) }
        let ranks: [Int32] = shapes.map { Int32($0.count) }
        var dataPointers = [UnsafePointer<Float>?](repeating: nil, count: tensors.count)
        var shapePointers = [UnsafePointer<Int64>?](repeating: nil, count: tensors.count)
        // Pin by copying into stable allocations: simple and the copies are small next to a model run.
        let dataCopies = tensors.map { t -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(t.data.count, 1))
            t.data.withUnsafeBufferPointer { if let base = $0.baseAddress { p.initialize(from: base, count: t.data.count) } }
            return p
        }
        let shapeCopies = shapes.map { s -> UnsafeMutablePointer<Int64> in
            let p = UnsafeMutablePointer<Int64>.allocate(capacity: max(s.count, 1))
            s.withUnsafeBufferPointer { if let base = $0.baseAddress { p.initialize(from: base, count: s.count) } }
            return p
        }
        defer { dataCopies.forEach { $0.deallocate() }; shapeCopies.forEach { $0.deallocate() } }
        for i in 0..<tensors.count { dataPointers[i] = UnsafePointer(dataCopies[i]); shapePointers[i] = UnsafePointer(shapeCopies[i]) }
        return dataPointers.withUnsafeBufferPointer { d in
            shapePointers.withUnsafeBufferPointer { s in ranks.withUnsafeBufferPointer { r in body(d.baseAddress!, s.baseAddress!, r.baseAddress!) } }
        }
    }
}
