#if canImport(Accelerate)
import Accelerate
#endif
import Foundation
import SQCore

/// The spectral engine of Pitch Shift and Disguise Voice: one channel, STFT with a 2048 window and 512 hop (sqrt-Hann
/// analysis and synthesis), own implementation, no borrowed code.
///
/// Pitch: phase vocoder with peak-region shifting (the method of Laroche and Dolson, "New phase-vocoder techniques for
/// pitch-shifting", 1999). Every spectral peak is one partial; its true frequency comes from the phase advance since the last
/// frame; the peak and the bins around it move as one block by `frequency x (ratio - 1)` and get one common phase rotation that
/// accumulates per frame. Bins of a partial keep their phase relation (no "phasiness" of the plain phase vocoder) and the
/// output frequency is exact, not rounded to a bin. Phases are referenced to the frame center, where a windowed partial has
/// one phase across its whole lobe, so a block can be read at a fractional bin position.
///
/// Formants: the spectral envelope (peak-riding: running maximum of the log spectrum, then cepstral smoothing) is measured on
/// the input; the shifted spectrum is re-weighted from where its envelope went (`bin / ratio`) to where it shall be
/// (`bin / formant`). `formant` 1 keeps the voice character, `formant == ratio` lets it move with the pitch.
///
/// Delay: exactly `AudioPitchValues.latencySamples` (= the window). Neutral controls pass the sound through unchanged.
/// Nothing here allocates after `init`.
final class PitchVocoder {
    static let n = 2_048, hop = 512, bins = n / 2 + 1
    /// Half width of the running maximum of the envelope in bins (+-140 Hz: closes the gaps between harmonics up to 280 Hz pitch; the smoothing after it does the rest).
    static let envelopeReach = 6
    /// Largest envelope correction per bin in nepers (30 dB).
    static let maxEnvelopeGain = 3.45

    struct Controls {
        /// Pitch ratio (2 = one octave up).
        var ratio = 1.0
        /// Where the spectral envelope goes: 1 = stays, `ratio` = moves with the pitch.
        var formant = 1.0
        /// Extra, frequency-dependent envelope shift in bins: largest around 2 kHz, none at 0 and from 4 kHz up.
        var bend = 0.0
        /// The envelope is put back blurred (formant detail is lost).
        var coarse = false
        /// Random phase offset per partial and frame in radians, 0 = none.
        var jitter = 0.0
        var jitterKey: UInt64 = 0

        var isNeutral: Bool { ratio == 1 && formant == 1 && bend == 0 && !coarse && jitter == 0 }
        var shapesEnvelope: Bool { formant != ratio || bend != 0 || coarse }
    }

    // All state is raw memory owned by this object: no bounds, exclusivity or uniqueness checks in the render path.
    private typealias Buf = UnsafeMutablePointer<Double>
    private let pool: Buf
    private let window: Buf, liftFine: Buf, liftCoarse: Buf
    private let fftRe: Buf, fftIm: Buf                                     // FFT output before it is copied back
    #if canImport(Accelerate)
    private let forwardSetup: vDSP_DFT_SetupD, inverseSetup: vDSP_DFT_SetupD
    #else
    // shortcut: portable radix-2 FFT where Accelerate is missing (Windows); several times slower than vDSP, upgrade
    // to a vectorized FFT when Windows playback runs voice effects in real time.
    private let portableFFT = FFTRadix2(size: PitchVocoder.n)
    private var fftScratchRe = [Double](repeating: 0, count: PitchVocoder.n)
    private var fftScratchIm = [Double](repeating: 0, count: PitchVocoder.n)
    #endif
    private let inRing: Buf                                                // last n input samples, circular
    private var inPos = 0
    private var sinceFrame = 0
    private let ola: Buf
    private let fifo: UnsafeMutablePointer<Float>                          // circular output queue, 2 n
    private var fifoRead = 0, fifoCount = 0
    private let re: Buf, im: Buf, cep: Buf
    private let xr: Buf, xi: Buf, pr: Buf, pi: Buf, yr: Buf, yi: Buf
    private let mag: Buf, logMag: Buf, envFine: Buf, envCoarse: Buf
    private var theta: Buf, thetaNext: Buf
    private let peaks: UnsafeMutablePointer<Int>
    private var peakCount = 0
    // Pitch tracker: the window at a quarter of the rate.
    private static let decN = n / 4, lagMin = 30, lagMax = 200
    private let dec: Buf, rho: Buf

    init() {
        let n = Self.n, bins = Self.bins
        // One block for every Double buffer.
        let sizes = [n, n, n, n, n, n, n, n, n, n, bins, bins, bins, bins, bins, bins, bins, bins, bins, bins, bins, bins,
                     Self.decN, Self.lagMax + 2]
        let total = sizes.reduce(0, +)
        let base = Buf.allocate(capacity: total)
        base.initialize(repeating: 0, count: total)
        pool = base
        var at = 0
        func take(_ i: Int) -> Buf { defer { at += sizes[i] }; return base + at }
        window = take(0); liftFine = take(1); liftCoarse = take(2); fftRe = take(3); fftIm = take(4)
        inRing = take(5); ola = take(6); re = take(7); im = take(8); cep = take(9)
        xr = take(10); xi = take(11); pr = take(12); pi = take(13); yr = take(14); yi = take(15)
        mag = take(16); logMag = take(17); envFine = take(18); envCoarse = take(19); theta = take(20); thetaNext = take(21)
        dec = take(22); rho = take(23)
        fifo = .allocate(capacity: 2 * n)
        fifo.initialize(repeating: 0, count: 2 * n)
        peaks = .allocate(capacity: bins)
        peaks.initialize(repeating: 0, count: bins)
        // 2048 is a size vDSP always supports; a missing setup would be a broken system.
        #if canImport(Accelerate)
        forwardSetup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(n), .FORWARD)!
        inverseSetup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(n), .INVERSE)!
        #endif
        for i in 0..<n { window[i] = sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))) }
        // Cepstral low-pass, full below `pass`, cosine fade to 0 at `stop` (quefrency in samples, mirrored).
        func lifter(_ out: Buf, pass: Int, stop: Int) {
            for q in 0..<n {
                let d = min(q, n - q)
                out[q] = d <= pass ? 1 : d >= stop ? 0 : 0.5 + 0.5 * cos(Double.pi * Double(d - pass) / Double(stop - pass))
            }
        }
        lifter(liftFine, pass: 64, stop: 110)          // keeps formants (detail from about 300 Hz), removes harmonics up to 400 Hz pitch
        lifter(liftCoarse, pass: 22, stop: 44)         // formants blur into broad humps (detail narrower than about 1 kHz is gone)
        reset()
    }

    deinit {
        pool.deallocate(); fifo.deallocate(); peaks.deallocate()
        #if canImport(Accelerate)
        vDSP_DFT_DestroySetupD(forwardSetup); vDSP_DFT_DestroySetupD(inverseSetup)
        #endif
    }

    /// Complex FFT in place (forward unscaled, inverse scaled by 1 / n). vDSP: several times faster than `FFTRadix2`, and
    /// just as fast in a debug build, where a Swift loop of this size costs milliseconds per frame.
    private func fft(_ re: Buf, _ im: Buf, inverse: Bool) {
        let n = Self.n
        #if canImport(Accelerate)
        vDSP_DFT_ExecuteD(inverse ? inverseSetup : forwardSetup, re, im, fftRe, fftIm)
        if inverse {
            var s = 1 / Double(n)
            vDSP_vsmulD(fftRe, 1, &s, re, 1, vDSP_Length(n))
            vDSP_vsmulD(fftIm, 1, &s, im, 1, vDSP_Length(n))
        } else {
            re.update(from: fftRe, count: n)
            im.update(from: fftIm, count: n)
        }
        #else
        for i in 0..<n { fftScratchRe[i] = re[i]; fftScratchIm[i] = im[i] }
        portableFFT.transform(&fftScratchRe, &fftScratchIm, inverse: inverse)
        for i in 0..<n { re[i] = fftScratchRe[i]; im[i] = fftScratchIm[i] }
        #endif
    }

    func reset() {
        for i in 0..<Self.n { inRing[i] = 0; ola[i] = 0 }
        for i in 0..<Self.bins { pr[i] = 0; pi[i] = 0; theta[i] = 0; thetaNext[i] = 0 }
        for i in 0..<(2 * Self.n) { fifo[i] = 0 }
        inPos = 0; sinceFrame = 0; fifoRead = 0
        fifoCount = AudioPitchValues.latencySamples - (Self.n - Self.hop)       // the pre-fill: the rest of the delay is the window
    }

    /// `reset` with the hop grid on absolute positions: the next sample pushed is number `p`, and a hop completes with every
    /// sample whose number plus one is a multiple of `hop`. So the frames of a stream that starts anywhere fall where the
    /// frames of the same stream started at 0 fall. The first hop is shorter then, and so is the pre-fill: the delay stays
    /// one window.
    func reset(nextSample p: Int64) {
        reset()
        let h = Int64(Self.hop)
        let phase = Int(((p % h) + h) % h)
        sinceFrame = phase
        fifoCount -= phase
    }

    /// Takes one input sample; true when a hop is complete: call `analyze` and `synthesize` before the next `pop`.
    @inline(__always) func push(_ x: Float) -> Bool {
        inRing[inPos] = Double(x)
        inPos = (inPos + 1) & (Self.n - 1)
        sinceFrame += 1
        if sinceFrame == Self.hop { sinceFrame = 0; return true }
        return false
    }

    /// The next output sample (the input `latencySamples` ago, processed).
    @inline(__always) func pop() -> Float {
        let v = fifo[fifoRead]
        fifoRead = (fifoRead + 1) & (2 * Self.n - 1)
        fifoCount -= 1
        return v
    }

    /// Spectrum of the last `n` samples, phases referenced to the frame center.
    func analyze() {
        let n = Self.n
        for k in 0..<n {
            re[k] = inRing[(inPos + k) & (n - 1)] * window[k]       // oldest first
            im[k] = 0
        }
        fft(re, im, inverse: false)
        for k in 0..<Self.bins {
            let s: Double = k & 1 == 0 ? 1 : -1
            let a = re[k] * s, b = im[k] * s
            xr[k] = a; xi[k] = b
            mag[k] = (a * a + b * b).squareRoot()
        }
    }

    /// Pitch of the last window in Hz, nil when it is not voiced (60...400 Hz, normalized autocorrelation at 12 kHz).
    func estimateF0(sampleRate: Double) -> Double? {
        let m = Self.decN, n = Self.n
        var energy = 0.0
        for j in 0..<m {
            let b = inPos + 4 * j
            let v = 0.25 * (inRing[b & (n - 1)] + inRing[(b + 1) & (n - 1)] + inRing[(b + 2) & (n - 1)] + inRing[(b + 3) & (n - 1)])
            dec[j] = v
            energy += v * v
        }
        guard energy / Double(m) > 1e-7 else { return nil }                    // below -70 dBFS: silence
        let len = m - Self.lagMax - 1
        var e0 = 0.0
        for j in 0..<len { e0 += dec[j] * dec[j] }
        guard e0 > 1e-12 else { return nil }
        var best = 0.0
        var e1 = 0.0                                                            // energy of the shifted part, slid along
        for j in 0..<len { e1 += dec[j + Self.lagMin - 1] * dec[j + Self.lagMin - 1] }
        for lag in (Self.lagMin - 1)...(Self.lagMax + 1) {
            var num = 0.0
            #if canImport(Accelerate)
            vDSP_dotprD(dec, 1, dec + lag, 1, &num, vDSP_Length(len))
            #else
            for j in 0..<len { num += dec[j] * dec[j + lag] }
            #endif
            let r = e1 > 1e-12 ? num / (e0 * e1).squareRoot() : 0
            if lag + len < m { e1 += dec[lag + len] * dec[lag + len] - dec[lag] * dec[lag] }
            rho[lag] = r
            if lag >= Self.lagMin && lag <= Self.lagMax && r > best { best = r }
        }
        guard best > 0.5 else { return nil }
        // The shortest period that is nearly as good as the best one (the best alone often is two periods).
        for lag in Self.lagMin...Self.lagMax where rho[lag] >= 0.9 * best && rho[lag] >= rho[lag - 1] && rho[lag] >= rho[lag + 1] {
            let a = rho[lag - 1], b = rho[lag], c = rho[lag + 1]
            let den = a - 2 * b + c
            let off = abs(den) > 1e-12 ? min(0.5, max(-0.5, 0.5 * (a - c) / den)) : 0
            return sampleRate / 4 / (Double(lag) + off)
        }
        return nil
    }

    /// Builds the output frame for `c` from the analyzed spectrum and queues one hop.
    func synthesize(_ c: Controls) {
        let n = Self.n, bins = Self.bins
        if c.isNeutral {
            for k in 0..<bins { yr[k] = xr[k]; yi[k] = xi[k]; theta[k] = 0 }
        } else {
            shift(c)
            if c.shapesEnvelope { shapeEnvelope(c) }
        }
        for k in 0..<bins { pr[k] = xr[k]; pi[k] = xi[k] }
        for k in 0..<bins {
            let s: Double = k & 1 == 0 ? 1 : -1
            re[k] = yr[k] * s; im[k] = yi[k] * s
            if k > 0 && k < n / 2 { re[n - k] = re[k]; im[n - k] = -im[k] }
        }
        im[0] = 0; im[n / 2] = 0
        fft(re, im, inverse: true)
        // Overlap-add (sqrt-Hann at 75 % overlap sums to 2), emit the finished hop.
        for k in 0..<n { ola[k] += re[k] * window[k] * 0.5 }
        for k in 0..<Self.hop {
            fifo[(fifoRead + fifoCount) & (2 * n - 1)] = Float(ola[k])
            fifoCount += 1
        }
        for k in 0..<(n - Self.hop) { ola[k] = ola[k + Self.hop] }
        for k in (n - Self.hop)..<n { ola[k] = 0 }
    }

    /// Moves every partial (peak and its region) to `ratio` times its frequency.
    private func shift(_ c: Controls) {
        let bins = Self.bins
        for k in 0..<bins { yr[k] = 0; yi[k] = 0 }
        peakCount = 0
        var k = 2
        while k < bins - 2 {
            let m = mag[k]
            if m > 1e-9 && m > mag[k - 1] && m >= mag[k + 1] && m > mag[k - 2] && m >= mag[k + 2] {
                peaks[peakCount] = k; peakCount += 1
                k += 2
            }
            k += 1
        }
        guard peakCount > 0 else {
            // Nothing tonal (silence, a click): passed on as it is.
            for i in 0..<bins { yr[i] = xr[i]; yi[i] = xi[i]; theta[i] = 0 }
            return
        }
        let twoPi = 2 * Double.pi
        let binsPerRadian = Double(Self.n) / (twoPi * Double(Self.hop))
        let radiansPerBin = twoPi * Double(Self.hop) / Double(Self.n)
        var lo = 0
        for p in 0..<peakCount {
            let k = peaks[p]
            var hi = bins - 1
            if p + 1 < peakCount {
                // The region ends at the lowest bin before the next peak.
                var mi = k + 1, mv = mag[k + 1]
                var i = k + 2
                while i < peaks[p + 1] { if mag[i] < mv { mv = mag[i]; mi = i }; i += 1 }
                hi = mi
            }
            // True frequency from the phase advance since the last frame (expected: k quarter turns at hop = n / 4).
            let cr = xr[k] * pr[k] + xi[k] * pi[k], ci = xi[k] * pr[k] - xr[k] * pi[k]
            var d = atan2(ci, cr) - radiansPerBin * Double(k & 3)
            d -= twoPi * (d / twoPi).rounded()
            var kTrue = Double(k) + d * binsPerRadian
            if abs(kTrue - Double(k)) > 1 { kTrue = Double(k) }          // onset or noise: no reliable advance
            let s = kTrue * (c.ratio - 1)
            var th = theta[k] + radiansPerBin * s
            th -= twoPi * (th / twoPi).rounded()
            for i in lo...hi { thetaNext[i] = th }
            let out = c.jitter == 0 ? th : th + c.jitter * Self.unit(c.jitterKey &+ UInt64(k) &* 0x9E37_79B9_7F4A_7C15)
            let co = cos(out), si = sin(out)
            let j0 = max(0, Int((Double(lo) + s).rounded(.up))), j1 = min(bins - 1, Int((Double(hi) + s).rounded(.down)))
            if j0 <= j1 {
                for j in j0...j1 {
                    // The block read at a fractional bin: Catmull-Rom across four bins.
                    let src = Double(j) - s
                    let fl = src.rounded(.down)
                    let f = src - fl
                    let i1 = min(bins - 1, max(0, Int(fl)))
                    let i0 = max(0, i1 - 1), i2 = min(bins - 1, i1 + 1), i3 = min(bins - 1, i1 + 2)
                    let f2 = f * f, f3 = f2 * f
                    let w0 = -0.5 * f3 + f2 - 0.5 * f, w1 = 1.5 * f3 - 2.5 * f2 + 1
                    let w2 = -1.5 * f3 + 2 * f2 + 0.5 * f, w3 = 0.5 * f3 - 0.5 * f2
                    let a = w0 * xr[i0] + w1 * xr[i1] + w2 * xr[i2] + w3 * xr[i3]
                    let b = w0 * xi[i0] + w1 * xi[i1] + w2 * xi[i2] + w3 * xi[i3]
                    yr[j] += a * co - b * si
                    yi[j] += a * si + b * co
                }
            }
            lo = hi + 1
        }
        swap(&theta, &thetaNext)
    }

    /// Re-weights the shifted spectrum: from the envelope it carries now to the wanted one.
    private func shapeEnvelope(_ c: Controls) {
        let n = Self.n, bins = Self.bins, reach = Self.envelopeReach
        for k in 0..<bins { logMag[k] = 0.5 * log(mag[k] * mag[k] + 1e-14) }
        for k in 0..<bins {
            var m = logMag[k]
            var i = max(0, k - reach)
            let e = min(bins - 1, k + reach)
            while i <= e { if logMag[i] > m { m = logMag[i] }; i += 1 }
            re[k] = m
            if k > 0 && k < n / 2 { re[n - k] = m }
        }
        for k in 0..<n { im[k] = 0 }
        fft(re, im, inverse: false)
        if c.coarse { for q in 0..<n { cep[q] = re[q] } }
        for q in 0..<n { re[q] *= liftFine[q]; im[q] = 0 }
        fft(re, im, inverse: true)
        for k in 0..<bins { envFine[k] = re[k] }
        if c.coarse {
            for q in 0..<n { re[q] = cep[q] * liftCoarse[q]; im[q] = 0 }
            fft(re, im, inverse: true)
            for k in 0..<bins { envCoarse[k] = re[k] }
        }
        let top = Double(bins - 1)
        let bendEnd = 4_000.0 / 48_000.0 * Double(n)              // the bend acts below 4 kHz
        let invRatio = 1 / c.ratio, invFormant = 1 / c.formant
        for j in 0..<bins {
            let x = Double(j)
            var from = x * invFormant
            if c.bend != 0 && x < bendEnd { from += c.bend * sin(Double.pi * x / bendEnd) }
            let target = c.coarse ? Self.read(envCoarse, at: min(top, max(0, from))) : Self.read(envFine, at: min(top, max(0, from)))
            let current = Self.read(envFine, at: min(top, x * invRatio))
            let g = exp(min(Self.maxEnvelopeGain, max(-Self.maxEnvelopeGain, target - current)))
            yr[j] *= g; yi[j] *= g
        }
    }

    /// `a` holds `bins` values; `x` within 0...bins - 1.
    @inline(__always) private static func read(_ a: UnsafeMutablePointer<Double>, at x: Double) -> Double {
        let i = Int(x), f = x - Double(i)
        return i + 1 < bins ? a[i] + (a[i + 1] - a[i]) * f : a[bins - 1]
    }

    /// SplitMix64.
    @inline(__always) static func hash(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// -1...1 from a key.
    @inline(__always) static func unit(_ key: UInt64) -> Double {
        Double(hash(key) >> 11) / Double(1 << 53) * 2 - 1
    }
}

/// Pitch Shift of a clip chain: one engine per channel.
final class PitchShiftStage {
    private let channels: [PitchVocoder]
    init(channels: Int) { self.channels = (0..<channels).map { _ in PitchVocoder() } }
    func reset() { for c in channels { c.reset() } }

    /// `from` at the first sample, `to` one block later (semitones). `enabled == false` runs neutral: the delay stays.
    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 from: Double, to: Double, preserveFormants: Bool, enabled: Bool) {
        let step = (to - from) / Double(n)
        for c in 0..<min(chs, channels.count) {
            let v = channels[c], x = buf[c]
            for i in 0..<n {
                if v.push(x[i]) {
                    var ctl = PitchVocoder.Controls()
                    if enabled {
                        ctl.ratio = AudioPitchValues.ratio(semitones: min(24, max(-24, from + step * Double(i))))
                        ctl.formant = preserveFormants ? 1 : ctl.ratio
                    }
                    v.analyze()
                    v.synthesize(ctl)
                }
                x[i] = v.pop()
            }
        }
    }
}

/// Disguise Voice of a clip chain. Not a pitch shifter with a fixed setting (that is undone by shifting back):
///
/// - the speaker's pitch is tracked and replaced: the output follows an invented melody (seeded noise around a fixed center),
///   so neither the speaker's average pitch nor the intonation is left in the output;
/// - the formants move by a factor that drifts over time, plus a bend that shifts the lower formants against the upper ones;
/// - the spectral envelope goes back blurred (detail narrower than about 1 kHz is discarded, not hidden);
/// - every partial gets a small random phase offset per frame; the channels are summed to mono.
///
/// The modulation is a function of the clip-local position and a seed derived from the effect's id, which exists only in the
/// project: an export holds the processed sound and nothing about the curves. It still is not anonymization: what is said,
/// rhythm, accent and wording stay, and speaker recognition trained on disguised speech does better than chance.
final class DisguiseVoiceStage {
    private let voc = PitchVocoder()
    private let fs: Double
    private let rate: Int64
    private let seed: UInt64
    /// Clip-local number of the next sample, counted in this stage's own sample rate.
    private var pos: Int64 = 0
    private var hasPos = false
    /// Tests: every synthesized frame as (step on the absolute hop grid, what the engine was told).
    var trace: ((Int64, PitchVocoder.Controls) -> Void)?
    private let delay: [UnsafeMutablePointer<Float>]        // the untouched sound per channel, for "switched off"
    private var delayPos = 0
    private var logRatio = 0.0, hasRatio = false
    private var wasOff = true

    init(sampleRate: Double, channels: Int, id: UUID) {
        fs = sampleRate
        rate = Int64(sampleRate.rounded())
        let (hi, lo) = MultibandMeterTap.split(id)
        seed = PitchVocoder.hash(hi ^ PitchVocoder.hash(lo))
        delay = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: AudioPitchValues.latencySamples)
            p.initialize(repeating: 0, count: AudioPitchValues.latencySamples)
            return p
        }
    }
    deinit { for p in delay { p.deallocate() } }

    func reset() {
        voc.reset()
        for p in delay { p.update(repeating: 0, count: AudioPitchValues.latencySamples) }
        delayPos = 0; logRatio = 0; hasRatio = false; wasOff = true; hasPos = false
    }

    /// Smooth seeded noise, -1...1; `x` counts in steps (one new random value per unit).
    @inline(__always) private func noise(_ x: Double, lane: UInt64) -> Double {
        let fl = x.rounded(.down), f = x - fl
        let i = UInt64(bitPattern: Int64(fl))
        let base = seed &+ lane &* 0xD6E8_FEB8_6659_FD93
        let a = PitchVocoder.unit(base &+ i), b = PitchVocoder.unit(base &+ i &+ 1)
        return a + (b - a) * f * f * (3 - 2 * f)
    }

    /// What the engine does at `step` of the absolute hop grid (clip-local sample `step * hop`): the seeded curves depend
    /// on the step alone, so playback from a seek point and an export from the start read the same values.
    /// `f0` = tracked pitch of the input, nil while unvoiced.
    func controls(voice: Int, step: Int64, f0: Double?) -> PitchVocoder.Controls {
        let t = Double(step * Int64(PitchVocoder.hop)) / fs
        let high = voice == 1
        // The invented melody: slow swings of +-2.5 semitones plus quicker ones of +-0.8 around the center.
        let target = (high ? 215.0 : 100.0) * pow(2, (2.5 * noise(t * 1.3, lane: 1) + 0.8 * noise(t * 4.7, lane: 2)) / 12)
        if let f0 {
            let want = min(1.2, max(-1.2, log2(target / f0)))
            logRatio = hasRatio ? logRatio + 0.5 * (want - logRatio) : want
            hasRatio = true
        } else if !hasRatio {
            logRatio = high ? 0.5 : -0.4                      // nothing voiced yet: a plain shift in the chosen direction
        }
        var c = PitchVocoder.Controls()
        c.ratio = pow(2, logRatio)
        c.formant = (high ? 1.15 : 0.87) * pow(2, 0.1 * noise(t * 0.9, lane: 3))
        c.bend = 250.0 / fs * Double(PitchVocoder.n) * noise(t * 0.7, lane: 4)
        c.coarse = true
        c.jitter = 0.3
        c.jitterKey = PitchVocoder.hash(seed ^ UInt64(bitPattern: step))
        return c
    }

    /// `at` = clip-local position of the block's first sample. Switched off: every channel delayed, untouched.
    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 voice: Int, at: Time, enabled: Bool) {
        let chs = min(chs, delay.count), len = AudioPitchValues.latencySamples
        guard chs > 0 else { return }
        // The stage counts its own samples; the block position only places the start and a jump (rounding moves it by one).
        let want = AudioPitchValues.sample(at, rate: rate)
        let jumped = !hasPos || abs(want - pos) > 1
        if jumped { pos = want; hasPos = true }
        // Starts from silence, never from the original; a jump is a new start as well.
        if enabled && (wasOff || jumped) { voc.reset(nextSample: pos); hasRatio = false }
        wasOff = !enabled
        let scale = 1 / Float(chs)
        for i in 0..<n {
            var mono: Float = 0
            for c in 0..<chs {
                let x = buf[c][i]
                mono += x
                if !enabled { buf[c][i] = delay[c][delayPos] }
                delay[c][delayPos] = x
            }
            delayPos = (delayPos + 1) & (len - 1)
            pos += 1
            guard enabled else { continue }
            if voc.push(mono * scale) {
                let f0 = voc.estimateF0(sampleRate: fs)
                voc.analyze()
                let step = pos / Int64(PitchVocoder.hop)            // exact: a hop completes on the grid only
                let c = controls(voice: voice, step: step, f0: f0)
                trace?(step, c)
                voc.synthesize(c)
            }
            let y = voc.pop()
            for c in 0..<chs { buf[c][i] = y }
        }
    }
}
