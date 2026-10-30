import Foundation

// v82: the output channel layout of a sequence. Stored only when not Stereo, so untouched sequences encode as before; a
// sequence with Mono makes the file v82 (ProjectFile+V82.swift).

/// What the sequence mix is delivered as. Stereo is the engine's native two-channel mix. Mono folds it with `fold`:
/// playback gets the one channel on both speakers (dual mono), export writes one audio channel.
public enum ChannelLayout: String, Codable, Sendable, CaseIterable {
    case stereo, mono

    public var channelCount: Int { self == .mono ? 1 : 2 }

    /// The Mono mix law: the plain average (L + R) / 2. Full-scale correlated input (L = R = 1) stays at 1.0, so the sum
    /// never clips and needs no limiter of its own; opposite phase cancels, as it does on a mono speaker. (An equal-power
    /// -3 dB sum, 0.707 (L + R), would reach +3 dB on correlated material.)
    @inlinable public static func fold(_ left: Float, _ right: Float) -> Float { (left + right) * 0.5 }
}

extension Timeline {
    /// Output channels of the sequence (default Stereo).
    public var channelLayout: ChannelLayout {
        get { channelLayoutStore ?? .stereo }
        set { channelLayoutStore = newValue == .stereo ? nil : newValue }
    }
}
