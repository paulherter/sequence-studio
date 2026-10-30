import Foundation

/// Per-channel listening state of the timeline meter: Solo and Mute per output channel (L, R). Monitoring only: the engine
/// applies it after the meter measurement and only on the speaker path, so meters, loudness and export never see it.
/// Solo wins over Mute of other channels (any soloed channel silences every channel that is not soloed); Mute silences a
/// channel even when it is soloed.
public struct ChannelMonitor: Sendable, Equatable {
    public static let channelCount = 2
    /// Bit i = channel i.
    public private(set) var muteMask: UInt8 = 0
    public private(set) var soloMask: UInt8 = 0
    public init() {}
    public init(muteMask: UInt8, soloMask: UInt8) {
        let all: UInt8 = (1 << UInt8(Self.channelCount)) - 1
        self.muteMask = muteMask & all
        self.soloMask = soloMask & all
    }

    private static func bit(_ channel: Int) -> UInt8? { (0..<channelCount).contains(channel) ? 1 << UInt8(channel) : nil }

    public func isMuted(_ channel: Int) -> Bool { Self.bit(channel).map { muteMask & $0 != 0 } ?? false }
    public func isSoloed(_ channel: Int) -> Bool { Self.bit(channel).map { soloMask & $0 != 0 } ?? false }
    public var isNeutral: Bool { muteMask == 0 && soloMask == 0 }

    /// Whether `channel` is heard: not muted, and (no solo anywhere or this channel is soloed).
    public func isAudible(_ channel: Int) -> Bool {
        guard Self.bit(channel) != nil else { return true }
        if isMuted(channel) { return false }
        return soloMask == 0 || isSoloed(channel)
    }

    /// Linear monitoring gain per channel (1 audible, 0 silenced).
    public var gains: [Float] { (0..<Self.channelCount).map { isAudible($0) ? 1 : 0 } }

    public mutating func toggleMute(_ channels: [Int]) {
        let on = !channels.allSatisfy(isMuted)
        for c in channels { if let b = Self.bit(c) { if on { muteMask |= b } else { muteMask &= ~b } } }
    }

    public mutating func toggleSolo(_ channels: [Int]) {
        let on = !channels.allSatisfy(isSoloed)
        for c in channels { if let b = Self.bit(c) { if on { soloMask |= b } else { soloMask &= ~b } } }
    }

    public mutating func clear() { muteMask = 0; soloMask = 0 }

    /// Linear gain ramp over a block (no click): `from` at the first frame, `to` after the last. Both 1 = untouched.
    public static func applyRamp(_ p: UnsafeMutablePointer<Float>, count: Int, from: Float, to: Float) {
        guard count > 0 else { return }
        if from == to {
            if to == 1 { return }
            if to == 0 { p.update(repeating: 0, count: count); return }
            for i in 0..<count { p[i] *= to }
            return
        }
        let step = (to - from) / Float(count)
        var g = from
        for i in 0..<count { p[i] *= g; g += step }
    }
}
