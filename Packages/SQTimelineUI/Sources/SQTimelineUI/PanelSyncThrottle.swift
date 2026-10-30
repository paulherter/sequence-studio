import Foundation

/// While the sequence plays and the timeline is scrolled, every playback tick re-synced all side panels (about 1 ms of main
/// thread per tick, in the same run-loop turn as the timeline draw and its Core Animation commit). Panels whose values change
/// with the playhead only need a refresh a few times a second then; the playhead, monitor time and follow stay per tick.
public struct PanelSyncThrottle: Sendable {
    /// A scroll this recent counts as "scrolling" (covers the gaps between trackpad events and momentum frames).
    public static let scrollWindow: TimeInterval = 0.15
    /// Longest pause between two side-panel syncs while scrolling.
    public static let interval: TimeInterval = 0.1

    private var lastSync: TimeInterval = -.infinity
    public init() {}

    /// `playheadOnly`: the change is a playhead move during playback and nothing else. Returns whether the panels sync now.
    public mutating func shouldSyncPanels(now: TimeInterval, playheadOnly: Bool, lastScroll: TimeInterval) -> Bool {
        guard playheadOnly, now - lastScroll < Self.scrollWindow, now - lastSync < Self.interval else {
            lastSync = now
            return true
        }
        return false
    }
}
