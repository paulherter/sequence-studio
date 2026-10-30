import Foundation

/// Undo names of the track header toggles: state-specific ("Mute Track" / "Unmute Track"), never "Toggle ...".
public enum TrackToggleNames {
    /// Shift/Option-click on a target chip changes several tracks at once.
    public static let targetAll = "Change Track Targets"

    /// Name of the step that sets `toggle` to `turningOn` on every track of a kind ("Mute Tracks").
    public static func name(_ toggle: TrackToggle, turningOn on: Bool, plural: Bool) -> String {
        guard plural else { return name(toggle, turningOn: on) }
        switch toggle {
        case .visible: return on ? "Show Track Outputs" : "Hide Track Outputs"
        case .mute: return on ? "Mute Tracks" : "Unmute Tracks"
        case .solo: return on ? "Solo Tracks" : "Unsolo Tracks"
        case .lock: return on ? "Lock Tracks" : "Unlock Tracks"
        case .target: return targetAll
        case .syncLock: return on ? "Enable Sync Locks" : "Disable Sync Locks"
        }
    }

    /// Name of the step that sets `toggle` to `turningOn`.
    public static func name(_ toggle: TrackToggle, turningOn on: Bool) -> String {
        switch toggle {
        case .visible: on ? "Show Track Output" : "Hide Track Output"
        case .mute: on ? "Mute Track" : "Unmute Track"
        case .solo: on ? "Solo Track" : "Unsolo Track"
        case .lock: on ? "Lock Track" : "Unlock Track"
        case .target: on ? "Target Track" : "Untarget Track"
        case .syncLock: on ? "Enable Sync Lock" : "Disable Sync Lock"
        }
    }
}
