import Foundation

/// Renders one channel of a retimed (speed != 100 % and/or reversed) clip, stateless per output sample so any split
/// of the timeline into render blocks gives identical samples (seek, scrub, export all agree).
///
/// Output frame `o` (0 = the clip's first output frame) reads the source at `origin +/- o * speed`. Nothing outside the
/// clip's source range `[srcStart, srcEnd)` is ever read as signal: samples outside it are silence.
/// - `keepsPitch == false`, or speed exactly 100 % (plain reverse): resampling with linear interpolation
///   (varispeed: pitch follows speed; reverse at 100 % is bit exact).
/// - `keepsPitch == true` and speed != 100 %: time-stretch by overlap-add. Hann grains of `2 * hop` samples start every
///   `hop` output frames; grain `k` is a contiguous, unstretched piece of the source that starts exactly at
///   `origin + k * hop * speed` (grain 0 at `origin`), so pitch is kept while the clip advances `speed` source seconds
///   per second. A grain that would reach past the range is moved back inside it (the last 2 hops repeat the last
///   `2 * hop` samples of the range instead of leaking media from outside it or dipping to silence). Window weights of
///   two overlapping grains sum to 1 (the first `hop` frames use a flat window, so the clip start has no fade). No
///   waveform alignment (WSOLA): fast speech sounds slightly grainy, tonal music slightly chorused at the extremes.
///   Cost: each grain is read twice (2 x 2 x hop source frames per hop output frames per channel).
/// Reverse reads the grain (or the interpolation span) forwards and mirrors it; the first frame played is the last
/// source frame before `origin`.
/// All buffers are allocated in `init` (off the audio feed path); `render` never allocates.
final class AudioRetimer: @unchecked Sendable {
    /// Reads up to `count` frames of one channel starting at `from` (>= 0). Returns frames written.
    typealias Read = (_ from: Int64, _ count: Int, _ into: UnsafeMutablePointer<Float>) throws -> Int

    static let hop = 1024
    /// Largest speed (10000 %) the interpolation span has to cover.
    private static let maxSpeed = 100

    private let maxFrames: Int
    private let work: UnsafeMutablePointer<Float>
    private let workCapacity: Int
    private let grain: UnsafeMutablePointer<Float>
    private static let window: [Float] = {
        let n = 2 * hop
        return (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
    }()

    init(maxFrames: Int) {
        self.maxFrames = maxFrames
        workCapacity = maxFrames * Self.maxSpeed + 8
        work = .allocate(capacity: workCapacity); work.initialize(repeating: 0, count: workCapacity)
        grain = .allocate(capacity: 2 * Self.hop); grain.initialize(repeating: 0, count: 2 * Self.hop)
    }
    deinit { work.deallocate(); grain.deallocate() }

    /// Reads `count` frames from `from` that lie inside `[lo, hi)`; everything else is zero.
    private func fetch(_ read: Read, _ from: Int64, _ count: Int, _ lo: Int64, _ hi: Int64, _ dst: UnsafeMutablePointer<Float>) throws {
        dst.update(repeating: 0, count: count)
        let a = max(from, lo, 0), b = min(from + Int64(count), hi)
        guard b > a else { return }
        let off = Int(a - from)
        let got = try read(a, Int(b - a), dst + off)
        if got < Int(b - a) { (dst + off + got).update(repeating: 0, count: Int(b - a) - got) }
    }

    /// - Parameters:
    ///   - origin: source frame at output frame 0 (forward: where the clip starts reading; reversed: the end it reads backwards from, exclusive).
    ///   - speed: source frames per output frame (> 0), at most 100.
    ///   - srcStart/srcEnd: the clip's source range in frames; reads outside it are silence.
    ///   - firstOutput: index of `out[0]` (>= 0).
    func render(read: Read, origin: Double, speed: Double, reversed: Bool, keepsPitch: Bool, srcStart: Int64, srcEnd: Int64,
                firstOutput: Int64, count: Int, into out: UnsafeMutablePointer<Float>) throws {
        guard count > 0 else { return }
        precondition(count <= maxFrames && speed <= Double(Self.maxSpeed) + 1e-9)
        if keepsPitch && speed != 1 {
            try stretch(read, origin, speed, reversed, srcStart, srcEnd, firstOutput, count, out)
        } else {
            try resample(read, origin, speed, reversed, srcStart, srcEnd, firstOutput, count, out)
        }
    }

    /// Variable-speed variant for clips with a speed track (and clips inside retimed nested clips): the source position comes
    /// from `position(o)` (media frames at output frame `o`, relative to the grid origin; `reversed` = playing backwards there)
    /// instead of `origin +/- o * speed`. Same two algorithms and the same stateless-per-sample guarantee:
    /// - `keepsPitch`: overlap-add grains of `2 * hop`, grain `k` starting at the source position of output frame `k * hop`;
    /// - otherwise linear interpolation at `position(o)` (pitch follows the speed, ramps glide).
    /// Positions beyond the work buffer (a chain faster than 100x) give silence.
    func renderMapped(read: Read, position: (Int64) -> (frames: Double, reversed: Bool), keepsPitch: Bool,
                      srcStart: Int64, srcEnd: Int64, firstOutput: Int64, count: Int, into out: UnsafeMutablePointer<Float>) throws {
        guard count > 0 else { return }
        precondition(count <= maxFrames)
        if keepsPitch {
            try stretchMapped(read, position, srcStart, srcEnd, firstOutput, count, out)
        } else {
            try resampleMapped(read, position, srcStart, srcEnd, firstOutput, count, out)
        }
    }

    private func resampleMapped(_ read: Read, _ position: (Int64) -> (frames: Double, reversed: Bool), _ s0: Int64, _ s1: Int64,
                                _ first: Int64, _ count: Int, _ out: UnsafeMutablePointer<Float>) throws {
        var lo = Int64.max, hi = Int64.min
        for i in 0..<count {
            let (p0, r) = position(first + Int64(i))
            let p = r ? p0 - 1 : p0
            let fl = Int64(p.rounded(.down))
            lo = min(lo, fl); hi = max(hi, fl + 1)
        }
        let n = Int(hi - lo) + 1
        guard n <= workCapacity else { out.update(repeating: 0, count: count); return }
        try fetch(read, lo, n, s0, s1, work)
        for i in 0..<count {
            let (p0, r) = position(first + Int64(i))
            let p = r ? p0 - 1 : p0
            let fl = p.rounded(.down)
            let k = Int(Int64(fl) - lo)
            let fr = Float(p - fl)
            out[i] = fr == 0 ? work[k] : work[k] * (1 - fr) + work[k + 1] * fr
        }
    }

    private func stretchMapped(_ read: Read, _ position: (Int64) -> (frames: Double, reversed: Bool), _ s0: Int64, _ s1: Int64,
                               _ first: Int64, _ count: Int, _ out: UnsafeMutablePointer<Float>) throws {
        let h = Int64(Self.hop), g = 2 * Self.hop
        out.update(repeating: 0, count: count)
        let last = first + Int64(count) - 1
        let kFirst = max(Int64(0), Self.floorDiv(first, h) - 1), kLast = Self.floorDiv(last, h)
        guard kFirst <= kLast else { return }
        for k in kFirst...kLast {
            let gStart = k * h
            let lo = max(first, gStart), hi = min(last + 1, gStart + 2 * h)
            guard lo < hi else { continue }
            let (p, reversed) = position(gStart)
            var src: Int64
            if reversed {
                src = Int64(p.rounded()) - Int64(g)
                src = max(src, s0)
                if s0 + Int64(g) <= s1 { src = min(src, s1 - Int64(g)) }
            } else {
                src = Int64(p.rounded())
                if s0 + Int64(g) <= s1 { src = min(src, s1 - Int64(g)) }
                src = max(src, s0)
            }
            try fetch(read, src, g, s0, s1, grain)
            for o in lo..<hi {
                let i = Int(o - gStart)
                let w: Float = (k == 0 && i < Self.hop) ? 1 : Self.window[i]
                out[Int(o - first)] += (reversed ? grain[g - 1 - i] : grain[i]) * w
            }
        }
    }

    // MARK: Varispeed

    private func resample(_ read: Read, _ origin: Double, _ speed: Double, _ reversed: Bool, _ s0: Int64, _ s1: Int64,
                          _ first: Int64, _ count: Int, _ out: UnsafeMutablePointer<Float>) throws {
        func pos(_ o: Int64) -> Double { reversed ? origin - Double(o) * speed - 1 : origin + Double(o) * speed }
        let p0 = pos(first), p1 = pos(first + Int64(count) - 1)
        let lo = Int64(min(p0, p1).rounded(.down)), hi = Int64(max(p0, p1).rounded(.down)) + 1
        let n = Int(hi - lo) + 1
        precondition(n <= workCapacity)
        try fetch(read, lo, n, s0, s1, work)
        for i in 0..<count {
            let p = pos(first + Int64(i))
            let fl = p.rounded(.down)
            let k = Int(Int64(fl) - lo)
            let fr = Float(p - fl)
            out[i] = fr == 0 ? work[k] : work[k] * (1 - fr) + work[k + 1] * fr
        }
    }

    // MARK: Time-stretch (pitch kept)

    private func stretch(_ read: Read, _ origin: Double, _ speed: Double, _ reversed: Bool, _ s0: Int64, _ s1: Int64,
                         _ first: Int64, _ count: Int, _ out: UnsafeMutablePointer<Float>) throws {
        let h = Int64(Self.hop), g = 2 * Self.hop
        out.update(repeating: 0, count: count)
        let last = first + Int64(count) - 1
        let kFirst = max(Int64(0), Self.floorDiv(first, h) - 1), kLast = Self.floorDiv(last, h)
        guard kFirst <= kLast else { return }
        for k in kFirst...kLast {
            let gStart = k * h                                  // output frame of the grain's first sample
            let lo = max(first, gStart), hi = min(last + 1, gStart + 2 * h)
            guard lo < hi else { continue }
            // Source segment [src, src + g) of the grain: grain 0 starts at the origin; a grain that would pass the range
            // is moved back inside it. Reversed: the segment ends at `origin - k * hop * speed`, mirrored below.
            var src: Int64
            if reversed {
                let end = Int64((origin - Double(gStart) * speed).rounded())
                src = end - Int64(g)
                src = max(src, s0)                              // not before the range start
                if s0 + Int64(g) <= s1 { src = min(src, s1 - Int64(g)) }
            } else {
                src = Int64((origin + Double(gStart) * speed).rounded())
                if s0 + Int64(g) <= s1 { src = min(src, s1 - Int64(g)) }
                src = max(src, s0)
            }
            try fetch(read, src, g, s0, s1, grain)
            for o in lo..<hi {
                let i = Int(o - gStart)
                // Flat window on the clip's very first hop (no grain before it to overlap with).
                let w: Float = (k == 0 && i < Self.hop) ? 1 : Self.window[i]
                let s = reversed ? grain[g - 1 - i] : grain[i]
                out[Int(o - first)] += s * w
            }
        }
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
