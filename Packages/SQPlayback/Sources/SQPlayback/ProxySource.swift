import Foundation

/// When the monitor decodes a media's proxy instead of the original (W9.9 AutoProxy). Paused frames are always the
/// original's exact frame; export never sees proxies (it does not go through the engine).
public struct ProxyUse: Sendable, Hashable {
    /// While a scrub gesture runs (`beginScrub`...`endScrub`).
    public var scrubbing: Bool
    /// While playing (weak Macs, or the `sq.proxy.playback` setting).
    public var playback: Bool
    public init(scrubbing: Bool, playback: Bool) { self.scrubbing = scrubbing; self.playback = playback }

    public static let off = ProxyUse(scrubbing: false, playback: false)
    /// Engine default: proxies for scrubbing once the resolver has one.
    public static let `default` = ProxyUse(scrubbing: true, playback: false)
}
