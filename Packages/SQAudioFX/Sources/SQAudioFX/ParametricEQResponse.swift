import Foundation
import SQCore

/// Read-only frequency response of the 5-band Parametric EQ for drawing a curve. Uses the very coefficients the audio
/// stage runs (`PEQBiquad`), so the picture and the sound cannot drift apart.
public enum ParametricEQResponse {
    /// Sample rate of the clip effect chain.
    public static let sampleRate = Double(ClipAudioFXChain.sampleRate)

    /// Response of filter `i` (0 HP, 1 low shelf, 2...6 peaks, 7 high shelf, 8 LP) alone in dB at `hz`; 0 when the band is off.
    public static func bandDB(_ values: AudioParametricEQValues, filter i: Int, hz: Double) -> Double {
        let b = values[i]
        guard b.on else { return 0 }
        return PEQBiquad.magnitudeDB(PEQBiquad.coef(filter: i, b, fs: sampleRate), hz: hz, fs: sampleRate)
    }

    /// Combined response of every enabled filter in dB at `hz`.
    public static func totalDB(_ values: AudioParametricEQValues, hz: Double) -> Double {
        PEQBiquad.totalMagnitudeDB(values, hz: hz, fs: sampleRate)
    }

    /// Combined response at each of `freqs`, written into `out` (resized; coefficients computed once per call, not per point).
    public static func totalDB(_ values: AudioParametricEQValues, at freqs: [Double], into out: inout [Double]) {
        out.removeAll(keepingCapacity: true)
        var coefs: [PEQBiquad.Coef] = []
        for i in 0..<AudioParametricEQValues.bandCount where values[i].on {
            coefs.append(PEQBiquad.coef(filter: i, values[i], fs: sampleRate))
        }
        for hz in freqs {
            var sum = 0.0
            for c in coefs { sum += PEQBiquad.magnitudeDB(c, hz: hz, fs: sampleRate) }
            out.append(sum)
        }
    }
}
