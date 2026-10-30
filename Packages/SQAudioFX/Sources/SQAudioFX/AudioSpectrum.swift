import Foundation
import Synchronization

/// Per-clip spectrum feed for the effect popups (Multiband / EQ): the UI names ONE effect to watch and whether it wants the
/// sound before ("Spectrum at Input") or after the effect. Every `ClipAudioFXChain` holding that effect copies its block
/// (channels averaged to mono) into a ring of the last `SpectrumAnalyzer.size` samples; the UI copies the ring out at
/// ~30 Hz and runs the FFT itself (`SpectrumAnalyzer`), so the audio thread never does an FFT.
///
/// Realtime: a chain not holding the watched effect pays one atomic load per stage and block. The watched one writes
/// under `withLockIfAvailable` (never waits: if the UI is copying at that moment, that block is skipped) and never
/// allocates (the ring is preallocated and only written in place; the UI copies element-wise into its own array, so the
/// ring's storage is never shared). Whatever chain runs the effect feeds it (playback, scrub, export); nothing is
/// estimated: no audio = no new sequence.
public final class AudioSpectrumTap: Sendable {
    public static let shared = AudioSpectrumTap()

    private struct Ring {
        var samples = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        var pos = 0
    }

    private let watching = Atomic<Bool>(false)
    private let input = Atomic<Bool>(false)
    private let idHi = Atomic<UInt64>(0), idLo = Atomic<UInt64>(0)
    private let seq = Atomic<UInt64>(0)
    private let ring = Mutex(Ring())

    public init() {}

    /// The effect whose chain publishes (nil stops all publishing); `atInput` = the sound going into it, else coming out.
    /// Clears the ring, so nothing of the previous effect shows.
    public func watch(_ id: UUID?, atInput: Bool = false) {
        watching.store(false, ordering: .releasing)
        guard let id else { return }
        let (h, l) = MultibandMeterTap.split(id)
        idHi.store(h, ordering: .relaxed); idLo.store(l, ordering: .relaxed)
        input.store(atInput, ordering: .relaxed)
        ring.withLock { r in for i in r.samples.indices { r.samples[i] = 0 }; r.pos = 0 }
        watching.store(true, ordering: .releasing)
    }

    /// Audio thread: is the effect with this (pre-split) id the watched one? One to three atomic loads.
    @inline(__always) func isWatched(hi: UInt64, lo: UInt64) -> Bool {
        watching.load(ordering: .acquiring) && idHi.load(ordering: .relaxed) == hi && idLo.load(ordering: .relaxed) == lo
    }

    /// Audio thread: tap the input (true) or the output (false) of the watched effect.
    @inline(__always) var atInput: Bool { input.load(ordering: .relaxed) }

    /// Audio thread: one block, channels averaged. Never waits, never allocates.
    func push(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int) {
        guard chs > 0, n > 0 else { return }
        let scale = 1 / Float(chs)
        let done: Bool? = ring.withLockIfAvailable { r in
            let size = r.samples.count
            var pos = r.pos
            r.samples.withUnsafeMutableBufferPointer { s in
                for i in 0..<n {
                    var v: Float = 0
                    for c in 0..<chs { v += buf[c][i] }
                    s[pos] = v * scale
                    pos += 1
                    if pos == size { pos = 0 }
                }
            }
            r.pos = pos
            return true
        }
        if done != nil { seq.add(1, ordering: .releasing) }
    }

    /// Published blocks so far.
    public var sequence: UInt64 { seq.load(ordering: .acquiring) }

    /// UI: the last `SpectrumAnalyzer.size` samples (oldest first) into `out` when `id` is the watched effect, and the
    /// sequence they belong to (0 = nothing published since `watch`); nil when `id` is not watched.
    public func snapshot(for id: UUID, into out: inout [Float]) -> UInt64? {
        let (h, l) = MultibandMeterTap.split(id)
        guard isWatched(hi: h, lo: l) else { return nil }
        if out.count != SpectrumAnalyzer.size { out = [Float](repeating: 0, count: SpectrumAnalyzer.size) }
        let s = seq.load(ordering: .acquiring)
        out.withUnsafeMutableBufferPointer { o in
            ring.withLock { r in
                let size = r.samples.count
                for i in 0..<size { o[i] = r.samples[(r.pos + i) % size] }
            }
        }
        return s
    }
}

/// Magnitude spectrum for the display: Hann-windowed FFT of `size` samples, read out at log-spaced frequencies
/// 20 Hz...20 kHz as the level of a sine (dBFS: a full-scale sine reads 0 dB), clamped at `floorDB`. Main thread only.
public final class SpectrumAnalyzer {
    public static let size = 4_096
    public static let floorDB: Float = -120
    public static let minHz = 20.0, maxHz = 20_000.0

    private let fft = FFTRadix2(size: SpectrumAnalyzer.size)
    private let window: [Double]
    private var re = [Double](repeating: 0, count: SpectrumAnalyzer.size)
    private var im = [Double](repeating: 0, count: SpectrumAnalyzer.size)
    private var mag = [Double](repeating: 0, count: SpectrumAnalyzer.size / 2 + 1)

    public init() {
        window = (0..<Self.size).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.size)) }
    }

    /// `points` frequencies, log-spaced from `minHz` to `maxHz` inclusive.
    public static func frequencies(points: Int) -> [Double] {
        guard points > 1 else { return [minHz] }
        let a = log(minHz), b = log(maxHz)
        return (0..<points).map { exp(a + (b - a) * Double($0) / Double(points - 1)) }
    }

    /// One reading per frequency of `frequencies(points:)`: the strongest bin in the point's slice of the axis, or (where
    /// the points are denser than the bins, in the lows) the magnitude interpolated between the two nearest bins.
    public func magnitudesDB(_ samples: [Float], sampleRate: Double, points: Int) -> [Float] {
        let n = Self.size
        for i in 0..<n {
            re[i] = i < samples.count ? Double(samples[i]) * window[i] : 0
            im[i] = 0
        }
        fft.transform(&re, &im, inverse: false)
        // Sine amplitude: 2|X| / (n x coherent gain 0.5).
        for k in 0...(n / 2) { mag[k] = 4 * (re[k] * re[k] + im[k] * im[k]).squareRoot() / Double(n) }
        let df = sampleRate / Double(n)
        let freqs = Self.frequencies(points: points)
        let half = points > 1 ? (log(Self.maxHz) - log(Self.minHz)) / Double(points - 1) / 2 : 0
        return freqs.map { f in
            let lo = f * exp(-half) / df, hi = f * exp(half) / df
            let k0 = Int(lo.rounded(.up)), k1 = min(Int(hi.rounded(.down)), n / 2)
            var a = 0.0
            if k0 <= k1 {
                for k in k0...k1 { a = max(a, mag[k]) }
            } else {
                let x = min(f / df, Double(n / 2)), i = Int(x), t = x - Double(i)
                a = mag[i] * (1 - t) + mag[min(i + 1, n / 2)] * t
            }
            return a > 0 ? max(Self.floorDB, Float(20 * log10(a))) : Self.floorDB
        }
    }
}
