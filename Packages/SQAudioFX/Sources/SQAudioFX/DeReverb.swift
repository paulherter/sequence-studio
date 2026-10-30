import Foundation
import SQCore

/// De-Reverb: spectral suppression of the late reverberant tail (STFT, 1024 window, 256 hop, sqrt-Hann analysis and synthesis).
///
/// Model (Lebart-style late reverb estimate, simplified): the tail energy in a band now is the band's energy `delay` ago, decayed
/// by the room's reverb time: `tail = P(t - delay) x 10^(-6 delay / RT60)`. A band only counts as "tail" when it actually falls
/// like a tail (`d` = how close its fall is to the room's decay, 0 for steady or rising sound), so held vowels and onsets are left
/// alone. Gain per band = `max(floor, 1 - over x tail / P)`; the gain drops smoothly and rises at once (speech onsets stay clean).
///
/// Delay: exactly `AudioDeReverbValues.latencySamples` (= the window), also while the effect is off or at 0 %.
/// The constants (50 ms delay, over-subtraction, 24 dB floor at 100 %, band width) are ours, tuned on synthetic tails: unsourced.
final class DeReverbChannel {
    static let n = 1_024, hop = 256, bins = n / 2 + 1
    static let bandBins = 8
    static let bands = (bins + bandBins - 1) / bandBins
    /// Frames between the current spectrum and the one the tail estimate is taken from (50 ms).
    static let delayFrames = 10

    private let fft = FFTRadix2(size: 1_024)
    private let window: [Double]
    private var inRing = [Double](repeating: 0, count: DeReverbChannel.n)     // last n input samples, circular
    private var inPos = 0
    private var ola = [Double](repeating: 0, count: DeReverbChannel.n)
    private var fifo = [Float](repeating: 0, count: 2 * DeReverbChannel.n)     // circular output queue
    private var fifoRead = 0, fifoCount = 0
    private var sinceFrame = 0
    private var re = [Double](repeating: 0, count: DeReverbChannel.n)
    private var im = [Double](repeating: 0, count: DeReverbChannel.n)
    private var smoothed = [Double](repeating: 0, count: DeReverbChannel.bands)
    private var history: [Double]                                              // band powers of the last `delayFrames + 1` frames, flat
    private var band = [Double](repeating: 0, count: DeReverbChannel.bands)
    private var histPos = 0
    private var gainBand = [Double](repeating: 1, count: DeReverbChannel.bands)
    private var gainBin = [Double](repeating: 1, count: DeReverbChannel.bins)

    init() {
        window = (0..<Self.n).map { sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.n))) }
        history = [Double](repeating: 0, count: (Self.delayFrames + 1) * Self.bands)
        reset()
    }

    func reset() {
        for i in inRing.indices { inRing[i] = 0 }
        for i in ola.indices { ola[i] = 0 }
        for i in smoothed.indices { smoothed[i] = 0; gainBand[i] = 1 }
        for h in history.indices { history[h] = 0 }
        for i in gainBin.indices { gainBin[i] = 1 }
        inPos = 0; histPos = 0; sinceFrame = 0
        for i in fifo.indices { fifo[i] = 0 }
        fifoRead = 0
        fifoCount = AudioDeReverbValues.latencySamples - (Self.n - Self.hop)       // the pre-fill: the rest of the delay is the window
    }

    /// In place. `amount` 0...1, `decay` = reverb time in seconds, `tone` -1...1.
    func process(_ x: UnsafeMutablePointer<Float>, frames: Int, amount: Double, decay: Double, tone: Double, sampleRate: Double) {
        for i in 0..<frames {
            inRing[inPos] = Double(x[i])
            inPos = (inPos + 1) % Self.n
            sinceFrame += 1
            if sinceFrame == Self.hop {
                sinceFrame = 0
                frame(amount: amount, decay: decay, tone: tone, sampleRate: sampleRate)
            }
            x[i] = fifo[fifoRead]
            fifoRead = (fifoRead + 1) % fifo.count
            fifoCount -= 1
        }
    }

    private func frame(amount: Double, decay: Double, tone: Double, sampleRate: Double) {
        let n = Self.n
        for k in 0..<n {
            re[k] = inRing[(inPos + k) % n] * window[k]       // oldest first
            im[k] = 0
        }
        fft.transform(&re, &im, inverse: false)

        // Band powers, smoothed over time a little.
        for b in 0..<Self.bands {
            var p = 0.0, c = 0.0
            for k in (b * Self.bandBins)..<min((b + 1) * Self.bandBins, Self.bins) { p += re[k] * re[k] + im[k] * im[k]; c += 1 }
            band[b] = p / c
            smoothed[b] = 0.5 * smoothed[b] + 0.5 * band[b]
        }
        let oldBase = histPos * Self.bands               // the frame `delayFrames` ago (the slot we are about to overwrite)
        histPos = (histPos + 1) % (Self.delayFrames + 1)

        let amount = min(1, max(0, amount))
        let hopSec = Double(Self.hop) / sampleRate
        let delaySec = Double(Self.delayFrames) * hopSec
        let a = pow(10, -6 * delaySec / max(decay, 0.05))                // power left after `delay` of tail decay
        let floorPow = pow(10, -2.4 * amount)                            // 24 dB at 100 %
        let over = 0.5 + amount
        for b in 0..<Self.bands {
            let p = smoothed[b], pd = history[oldBase + b]
            history[oldBase + b] = p
            var target = 1.0
            if amount > 0, pd > 1e-9, p > 1e-12 {
                let d = min(1, max(0, (1 - p / pd) / (1 - a)))
                let f = (Double(b * Self.bandBins) + Double(Self.bandBins) / 2) * sampleRate / Double(Self.n)
                let w = min(4, max(0.25, pow(2, tone * log2(max(f, 62.5) / 1000) / 2)))
                let ratio = min(1, a * pd * d / p * w)
                target = sqrt(max(floorPow, 1 - over * ratio))
            }
            // Down slowly (no gulps), up at once (onsets stay clean).
            gainBand[b] = target > gainBand[b] ? target : gainBand[b] + (target - gainBand[b]) * 0.5
        }
        // Bands to bins, smoothed across the band edges.
        for k in 0..<Self.bins { gainBin[k] = gainBand[min(k / Self.bandBins, Self.bands - 1)] }
        if amount > 0 {
            var prev = gainBin[0]
            for k in 1..<(Self.bins - 1) {
                let cur = gainBin[k]
                gainBin[k] = 0.25 * prev + 0.5 * cur + 0.25 * gainBin[k + 1]
                prev = cur
            }
        }
        for k in 0..<Self.bins {
            let g = gainBin[k]
            re[k] *= g; im[k] *= g
            if k > 0 && k < Self.n / 2 { re[n - k] = re[k]; im[n - k] = -im[k] }
        }
        fft.transform(&re, &im, inverse: true)

        // Overlap-add (sqrt-Hann at 75 % overlap sums to 2), emit the finished hop.
        for k in 0..<n { ola[k] += re[k] * window[k] * 0.5 }
        for k in 0..<Self.hop {
            fifo[(fifoRead + fifoCount) % fifo.count] = Float(ola[k])
            fifoCount += 1
        }
        for k in 0..<(n - Self.hop) { ola[k] = ola[k + Self.hop] }
        for k in (n - Self.hop)..<n { ola[k] = 0 }
    }
}

/// Radix-2 complex FFT of `size` points (a power of two; in place, forward unscaled, inverse scaled by 1/n).
/// De-Reverb uses 1024, the spectrum display 4096.
final class FFTRadix2 {
    let n: Int
    private var cosT: [Double], sinT: [Double], rev: [Int]
    init(size: Int = 1_024) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        n = size
        let bits = size.trailingZeroBitCount
        cosT = (0..<(size / 2)).map { cos(2 * Double.pi * Double($0) / Double(size)) }
        sinT = (0..<(size / 2)).map { -sin(2 * Double.pi * Double($0) / Double(size)) }
        rev = (0..<size).map { i in
            var r = 0, v = i
            for _ in 0..<bits { r = (r << 1) | (v & 1); v >>= 1 }
            return r
        }
    }

    func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        for i in 0..<n where i < rev[i] { re.swapAt(i, rev[i]); im.swapAt(i, rev[i]) }
        var len = 2
        while len <= n {
            let half = len / 2, step = n / len
            var start = 0
            while start < n {
                for j in 0..<half {
                    let wr = cosT[j * step], wi = inverse ? -sinT[j * step] : sinT[j * step]
                    let a = start + j, b = a + half
                    let tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
                start += len
            }
            len <<= 1
        }
        if inverse { let s = 1 / Double(n); for i in 0..<n { re[i] *= s; im[i] *= s } }
    }
}

/// The De-Reverb stage of a clip chain: one channel processor per channel.
final class DeReverbStage {
    private let channels: [DeReverbChannel]
    private let fs: Double
    init(sampleRate: Double, channels: Int) {
        fs = sampleRate
        self.channels = (0..<channels).map { _ in DeReverbChannel() }
    }
    func reset() { for c in channels { c.reset() } }
    /// `enabled == false` runs at 0 % so the delay stays (the chain's latency counts this stage while it is off).
    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 amount: Double, decay: Double, tone: Double, enabled: Bool) {
        for c in 0..<min(chs, channels.count) {
            channels[c].process(buf[c], frames: n, amount: enabled ? amount : 0, decay: decay, tone: tone, sampleRate: fs)
        }
    }
}
