import Foundation

/// Renders one channel of a retimed (speed != 100 % and/or reversed) clip, stateless per output sample so any split
/// of the timeline into render blocks gives identical samples (seek, scrub, export all agree).
///
/// Output frame `o` (0 = the clip's first output frame) reads the source at `origin +/- o * speed`:
/// - `keepsPitch == false`, or speed exactly 100 % (plain reverse): resampling with linear interpolation
///   (varispeed: pitch follows speed; reverse at 100 % is bit exact).
/// - `keepsPitch == true` and speed != 100 %: time-stretch by overlap-add. Hann grains of `2 * hop` samples start every
///   `hop` output frames; each grain is a contiguous, unstretched piece of the source centred on the ideal source
///   position of its centre, so pitch is kept while the clip advances `speed` source seconds per second. The window
///   weights of two overlapping grains sum to 1 (the first `hop` frames use a flat window, so the clip start has no
///   fade). No waveform alignment (WSOLA): fast speech sounds slightly grainy, tonal music slightly chorused at the
///   extremes. Cost: each grain is read twice (2 x 2 x hop source frames per hop output frames per channel).
/// Reverse reads the grain (or the interpolation span) forwards and mirrors it; the first frame played is the last
/// source frame before `origin`.
final class AudioRetimer {
    /// Reads up to `count` frames of one channel starting at `from` (>= 0). Returns frames written.
    typealias Read = (_ from: Int64, _ count: Int, _ into: UnsafeMutablePointer<Float>) throws -> Int

    static let hop = 1024

    private var work: [Float] = []
    private var grain: [Float] = []
    private static let window: [Float] = {
        let n = 2 * hop
        return (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    }()

    /// Zero-padded read: negative `from` and a short read both give silence.
    private func fetch(_ read: Read, _ from: Int64, _ count: Int, _ dst: UnsafeMutablePointer<Float>) throws {
        dst.update(repeating: 0, count: count)
        let skip = from < 0 ? Int(min(-from, Int64(count))) : 0
        guard skip < count else { return }
        let got = try read(from + Int64(skip), count - skip, dst + skip)
        if got < count - skip { (dst + skip + got).update(repeating: 0, count: count - skip - got) }
    }

    /// `origin`: source frame at output frame 0 (forward: where the clip starts reading; reversed: the end it reads backwards
    /// from, exclusive). `speed`: source frames per output frame (> 0). `firstOutput`: index of `out[0]`, may be < 0 only
    /// when the caller wants silence-padded extrapolation (not used).
    func render(read: Read, origin: Double, speed: Double, reversed: Bool, keepsPitch: Bool,
                firstOutput: Int64, count: Int, into out: UnsafeMutablePointer<Float>) throws {
        guard count > 0 else { return }
        if keepsPitch && speed != 1 {
            try stretch(read, origin, speed, reversed, firstOutput, count, out)
        } else {
            try resample(read, origin, speed, reversed, firstOutput, count, out)
        }
    }

    // MARK: Varispeed

    private func resample(_ read: Read, _ origin: Double, _ speed: Double, _ reversed: Bool,
                          _ first: Int64, _ count: Int, _ out: UnsafeMutablePointer<Float>) throws {
        func pos(_ o: Int64) -> Double { reversed ? origin - Double(o) * speed - 1 : origin + Double(o) * speed }
        let p0 = pos(first), p1 = pos(first + Int64(count) - 1)
        let lo = Int64(min(p0, p1).rounded(.down)), hi = Int64(max(p0, p1).rounded(.down)) + 1
        let n = Int(hi - lo) + 1
        if work.count < n { work = [Float](repeating: 0, count: n) }
        try work.withUnsafeMutableBufferPointer { w in
            try fetch(read, lo, n, w.baseAddress!)
            for i in 0..<count {
                let p = pos(first + Int64(i))
                let fl = p.rounded(.down)
                let k = Int(Int64(fl) - lo)
                let fr = Float(p - fl)
                out[i] = fr == 0 ? w[k] : w[k] * (1 - fr) + w[k + 1] * fr
            }
        }
    }

    // MARK: Time-stretch (pitch kept)

    private func stretch(_ read: Read, _ origin: Double, _ speed: Double, _ reversed: Bool,
                         _ first: Int64, _ count: Int, _ out: UnsafeMutablePointer<Float>) throws {
        let h = Int64(Self.hop), g = 2 * Self.hop
        out.update(repeating: 0, count: count)
        if grain.count < g { grain = [Float](repeating: 0, count: g) }
        let last = first + Int64(count) - 1
        let kFirst = max(Int64(0), Self.floorDiv(first, h) - 1), kLast = Self.floorDiv(last, h)
        guard kFirst <= kLast else { return }
        for k in kFirst...kLast {
            let gStart = k * h                                  // output frame of the grain's first sample
            let lo = max(first, gStart), hi = min(last + 1, gStart + 2 * h)
            guard lo < hi else { continue }
            // Source centre of the grain: ideal source position of output frame `gStart + hop`.
            let centre = reversed ? origin - Double(gStart + h) * speed : origin + Double(gStart + h) * speed
            let src = Int64(centre.rounded()) - h
            try grain.withUnsafeMutableBufferPointer { gb in
                try fetch(read, src, g, gb.baseAddress!)
                for o in lo..<hi {
                    let i = Int(o - gStart)
                    // Flat window on the clip's very first hop (no grain before it to overlap with).
                    let w: Float = (k == 0 && i < Self.hop) ? 1 : Self.window[i]
                    let s = reversed ? gb[g - 1 - i] : gb[i]
                    out[Int(o - first)] += s * w
                }
            }
        }
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
