import Foundation

/// 5.1 to stereo fold-down for a source that sits on a stereo track (FILMCRAFT-PRS #1036, #733). ITU-R BS.775:
/// Lo = L + C * 0.7071 + Ls * 0.7071, Ro = R + C * 0.7071 + Rs * 0.7071, the LFE channel is dropped. The coefficients
/// are applied as they are (no normalization): a loud surround mix can exceed full scale, the delivery limiter and
/// the track fader deal with that like with any hot source. `normalized` divides by the sum of the largest side
/// (1 + 2 * 0.7071) when a caller needs a guaranteed no-clip result.
public enum SurroundFoldDown {
    /// Order of the six channels in the decoded buffer.
    public enum ChannelOrder: Sendable, Hashable, CaseIterable {
        /// WAV / SMPTE: L, R, C, LFE, Ls, Rs (what the mixer expects).
        case smpte
        /// AAC element order: C, L, R, Ls, Rs, LFE (what some decoders deliver, #733).
        case aac
        /// Film order: L, C, R, Ls, Rs, LFE.
        case film

        /// Index of each speaker in a buffer of this order.
        var index: (l: Int, r: Int, c: Int, lfe: Int, ls: Int, rs: Int) {
            switch self {
            case .smpte: return (0, 1, 2, 3, 4, 5)
            case .aac: return (1, 2, 0, 5, 3, 4)
            case .film: return (0, 2, 1, 5, 3, 4)
            }
        }
    }

    /// -3 dB: the weight of the center and of each surround channel on its side.
    public static let centerGain: Float = 0.707_106_78
    public static let surroundGain: Float = 0.707_106_78
    /// Channel count this fold-down handles.
    public static let channelCount = 6

    /// Gain that keeps a full-scale signal on every contributing channel inside full scale.
    public static var normalizingGain: Float { 1 / (1 + centerGain + surroundGain) }

    /// Folds six channels (`channels[i]` is channel i of `order`, `frames` samples each) into `left` and `right`.
    /// Returns false (outputs untouched) when `channels` does not hold six channels.
    @discardableResult
    public static func fold(channels: [UnsafePointer<Float>], order: ChannelOrder = .smpte, frames: Int,
                            left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                            normalized: Bool = false) -> Bool {
        guard channels.count == channelCount, frames > 0 else { return false }
        let ix = order.index
        let l = channels[ix.l], r = channels[ix.r], c = channels[ix.c], ls = channels[ix.ls], rs = channels[ix.rs]
        let g: Float = normalized ? normalizingGain : 1
        for i in 0..<frames {
            let center = c[i] * centerGain
            left[i] = (l[i] + center + ls[i] * surroundGain) * g
            right[i] = (r[i] + center + rs[i] * surroundGain) * g
        }
        return true
    }

    /// Interleaved variant: `samples` holds `frames * 6` values (channel-fastest); returns interleaved stereo
    /// (`frames * 2`), or nil when the count does not match.
    public static func fold(interleaved samples: [Float], order: ChannelOrder = .smpte, normalized: Bool = false) -> [Float]? {
        guard samples.count % channelCount == 0 else { return nil }
        let frames = samples.count / channelCount
        let ix = order.index, g: Float = normalized ? normalizingGain : 1
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let o = i * channelCount
            let center = samples[o + ix.c] * centerGain
            out[i * 2] = (samples[o + ix.l] + center + samples[o + ix.ls] * surroundGain) * g
            out[i * 2 + 1] = (samples[o + ix.r] + center + samples[o + ix.rs] * surroundGain) * g
        }
        return out
    }
}
