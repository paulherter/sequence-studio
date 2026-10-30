import Foundation

/// Pitch-keeping playback rate for shuttle audio (J/L at 2x, 4x, 8x... and slow rates) on platforms without a system
/// time-pitch unit (Windows; the Mac uses AVAudioUnitTimePitch). Streaming overlap-add: Hann grains of `2 * hop` input
/// frames, one grain per `hop` output frames, the grain start advancing `rate * hop` input frames, so the audio runs
/// `rate` times faster at its own pitch. Same grain math as `AudioRetimer.stretch` (no waveform alignment: speech at
/// high rates sounds grainy, which is what shuttle needs). Latency: `hop` frames.
/// The render thread owns it: `render` never allocates or locks; `reset` comes from the same thread (the sink checks a
/// flag the control thread sets).
public final class ShuttleStretch: @unchecked Sendable {
    public static let hop = 1024
    public static let maxRate = 32.0

    /// Fills `count` planar stereo frames of the 1x stream (the ring through `AudioRenderCore`).
    public typealias Source = (_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int) -> Void

    private let capacity: Int
    private let inL: UnsafeMutablePointer<Float>, inR: UnsafeMutablePointer<Float>
    private let accL: UnsafeMutablePointer<Float>, accR: UnsafeMutablePointer<Float>
    private let window: UnsafeMutablePointer<Float>
    /// Input frames buffered in `inL/inR`, grain start in them (fraction carried), finished output frames not yet read.
    private var inCount = 0
    private var pos = 0.0
    private var ready = 0, readAt = 0

    public init() {
        let h = Self.hop
        capacity = 2 * h + Int(Self.maxRate * Double(h)) + 2
        inL = .allocate(capacity: capacity); inR = .allocate(capacity: capacity)
        accL = .allocate(capacity: 2 * h); accR = .allocate(capacity: 2 * h)
        window = .allocate(capacity: 2 * h)
        for p in [inL, inR] { p.initialize(repeating: 0, count: capacity) }
        for p in [accL, accR] { p.initialize(repeating: 0, count: 2 * h) }
        // Periodic Hann: two grains `hop` apart sum to exactly 1.
        for k in 0..<(2 * h) { window[k] = Float(0.5 - 0.5 * cos(Double.pi * Double(k) / Double(h))) }
    }
    deinit { [inL, inR, accL, accR, window].forEach { $0.deallocate() } }

    /// Output frames between the input and what is heard (the first grain's rise).
    public static var latencyFrames: Int { hop }

    /// Drops all buffered audio (seek, rate change).
    public func reset() {
        inCount = 0; pos = 0; ready = 0; readAt = 0
        accL.update(repeating: 0, count: 2 * Self.hop); accR.update(repeating: 0, count: 2 * Self.hop)
    }

    /// `count` output frames at `rate` (input frames per output frame, clamped to 1/32...32), pulling the input from
    /// `source` as needed.
    public func render(rate: Double, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int,
                       source: Source) {
        let r = min(max(rate, 1 / Self.maxRate), Self.maxRate)
        var done = 0
        while done < count {
            if ready == 0 { grain(r, source) }
            let n = min(ready, count - done)
            (left + done).update(from: accL + readAt, count: n)
            (right + done).update(from: accR + readAt, count: n)
            readAt += n; ready -= n; done += n
            if ready == 0 { shiftAccumulator() }
        }
    }

    /// Adds the next grain; afterwards the first `hop` accumulator frames are final.
    private func grain(_ rate: Double, _ source: Source) {
        let h = Self.hop
        let start = Int(pos)
        let need = start + 2 * h
        if inCount < need {
            source(inL + inCount, inR + inCount, need - inCount)
            inCount = need
        }
        for k in 0..<(2 * h) {
            accL[k] += window[k] * inL[start + k]
            accR[k] += window[k] * inR[start + k]
        }
        ready = h; readAt = 0
        pos += rate * Double(h)
        // Keep only input the next grain can still read.
        let drop = min(Int(pos), inCount)
        if drop > 0 {
            let keep = inCount - drop
            if keep > 0 { inL.update(from: inL + drop, count: keep); inR.update(from: inR + drop, count: keep) }
            inCount = keep; pos -= Double(drop)
        }
    }

    private func shiftAccumulator() {
        let h = Self.hop
        accL.update(from: accL + h, count: h); accR.update(from: accR + h, count: h)
        (accL + h).update(repeating: 0, count: h); (accR + h).update(repeating: 0, count: h)
    }
}
