import Foundation
import Synchronization

/// One meter reading of the watched Multiband Compressor: band input peaks (linear, after the crossover split), band gain
/// reduction (dB, >= 0, 0 for a bypassed band) and the output limiter's reduction (dB, >= 0). `sequence` counts published
/// blocks: an unchanged sequence means no audio ran through the effect since the last reading (stopped, or another clip).
public struct MultibandMeterReading: Sendable, Equatable {
    public var sequence: UInt64
    public var inputPeak: SIMD4<Float>
    public var gainReductionDB: SIMD4<Float>
    public var limiterReductionDB: Float

    public init(sequence: UInt64, inputPeak: SIMD4<Float>, gainReductionDB: SIMD4<Float>, limiterReductionDB: Float) {
        self.sequence = sequence; self.inputPeak = inputPeak
        self.gainReductionDB = gainReductionDB; self.limiterReductionDB = limiterReductionDB
    }
}

/// Lock-free meter feed from the audio threads to the Multiband custom setup. The UI names ONE effect to watch
/// (`watch(_:)`, the popup's effect); every `MultibandStage` of that effect publishes its block's levels with relaxed
/// atomic stores (no lock, no allocation: realtime-safe) and every other stage only does one atomic load per block.
/// Whatever chain runs the effect (playback, scrub, export) feeds it; nothing is ever published for an effect not
/// watched, and nothing is estimated: no audio = no new sequence.
public final class MultibandMeterTap: Sendable {
    public static let shared = MultibandMeterTap()

    private let watching = Atomic<Bool>(false)
    private let idHi = Atomic<UInt64>(0), idLo = Atomic<UInt64>(0)
    private let p0 = Atomic<UInt32>(0), p1 = Atomic<UInt32>(0), p2 = Atomic<UInt32>(0), p3 = Atomic<UInt32>(0)
    private let r0 = Atomic<UInt32>(0), r1 = Atomic<UInt32>(0), r2 = Atomic<UInt32>(0), r3 = Atomic<UInt32>(0)
    private let lim = Atomic<UInt32>(0)
    private let seq = Atomic<UInt64>(0)

    public init() {}

    static func split(_ id: UUID) -> (UInt64, UInt64) {
        withUnsafeBytes(of: id.uuid) { b in (b.load(fromByteOffset: 0, as: UInt64.self), b.load(fromByteOffset: 8, as: UInt64.self)) }
    }

    /// The effect whose stages publish; nil stops all publishing.
    public func watch(_ id: UUID?) {
        guard let id else { watching.store(false, ordering: .releasing); return }
        let (h, l) = Self.split(id)
        watching.store(false, ordering: .releasing)
        idHi.store(h, ordering: .relaxed); idLo.store(l, ordering: .relaxed)
        store(.zero, .zero, 0)                     // nothing of the previous effect shows (sequence unchanged: no audio yet)
        watching.store(true, ordering: .releasing)
    }

    /// Audio thread: is the stage with this id (pre-split) the watched one? One to three atomic loads.
    @inline(__always) func isWatched(hi: UInt64, lo: UInt64) -> Bool {
        watching.load(ordering: .acquiring) && idHi.load(ordering: .relaxed) == hi && idLo.load(ordering: .relaxed) == lo
    }

    /// Audio thread: one block's levels. Realtime-safe.
    func publish(inputPeak p: SIMD4<Double>, gainReductionDB g: SIMD4<Double>, limiterReductionDB l: Double) {
        store(p, g, l)
        seq.add(1, ordering: .releasing)
    }

    private func store(_ p: SIMD4<Double>, _ g: SIMD4<Double>, _ l: Double) {
        p0.store(Float(p[0]).bitPattern, ordering: .relaxed); p1.store(Float(p[1]).bitPattern, ordering: .relaxed)
        p2.store(Float(p[2]).bitPattern, ordering: .relaxed); p3.store(Float(p[3]).bitPattern, ordering: .relaxed)
        r0.store(Float(g[0]).bitPattern, ordering: .relaxed); r1.store(Float(g[1]).bitPattern, ordering: .relaxed)
        r2.store(Float(g[2]).bitPattern, ordering: .relaxed); r3.store(Float(g[3]).bitPattern, ordering: .relaxed)
        lim.store(Float(l).bitPattern, ordering: .relaxed)
    }

    /// Published blocks so far (all effects).
    public var sequence: UInt64 { seq.load(ordering: .acquiring) }

    /// The latest levels when `id` is the watched effect, else nil. Fields of one reading may come from two neighboring
    /// blocks (no lock); fine for a 30 Hz meter.
    public func reading(for id: UUID) -> MultibandMeterReading? {
        let (h, l) = Self.split(id)
        guard isWatched(hi: h, lo: l) else { return nil }
        let s = seq.load(ordering: .acquiring)
        func f(_ a: borrowing Atomic<UInt32>) -> Float { Float(bitPattern: a.load(ordering: .relaxed)) }
        return MultibandMeterReading(sequence: s, inputPeak: SIMD4(f(p0), f(p1), f(p2), f(p3)),
                                     gainReductionDB: SIMD4(f(r0), f(r1), f(r2), f(r3)), limiterReductionDB: f(lim))
    }
}
