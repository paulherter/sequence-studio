import Foundation
import Synchronization

/// Listening level of the timeline output (F7.5): a volume slider and a Dim switch. It is an app preference (`sq.monitor.*`),
/// not project data, and is applied only at the very end of the monitoring output (the engine's output mixer volume, after
/// the meter tap). Export and bounce never read it.
public enum MonitorGain {
    public static let levelKey = "sq.monitor.levelDB"
    public static let dimKey = "sq.monitor.dim"
    public static let minDB: Double = -60          // slider floor = mute
    public static let maxDB: Double = 0            // never boosts above the mix
    public static let dimDB: Double = -20

    public struct Setting: Sendable, Equatable {
        public var levelDB: Double
        public var dim: Bool
        public init(levelDB: Double = 0, dim: Bool = false) { self.levelDB = levelDB; self.dim = dim }

        /// Linear gain for the output mixer.
        public var linear: Float {
            let level = levelDB.isFinite ? min(max(levelDB, MonitorGain.minDB), MonitorGain.maxDB) : 0
            if level <= MonitorGain.minDB { return 0 }
            let db = level + (dim ? MonitorGain.dimDB : 0)
            return Float(pow(10, db / 20))
        }

        public static func current(defaults: UserDefaults = .standard) -> Setting {
            let raw = defaults.object(forKey: MonitorGain.levelKey) as? Double ?? 0
            let level = raw.isFinite ? min(max(raw, MonitorGain.minDB), MonitorGain.maxDB) : 0
            return Setting(levelDB: level, dim: defaults.bool(forKey: MonitorGain.dimKey))
        }
    }

    /// A level below this at launch resets to 0 dB: the app never starts silent with nothing on screen explaining it.
    public static let launchFloorDB: Double = -40

    /// Launch rules: Dim starts off; a stored level below `launchFloorDB` (or a non-finite one) goes back to 0 dB.
    public static func applyLaunchRules(defaults: UserDefaults = .standard) {
        var s = Setting.current(defaults: defaults)
        let raw = defaults.object(forKey: levelKey) as? Double
        if s.dim || (raw != nil && !(raw!.isFinite && raw! >= launchFloorDB)) {
            if s.dim { s.dim = false }
            if let raw, !(raw.isFinite && raw >= launchFloorDB) { s.levelDB = 0 }
            store(s, defaults: defaults)
        }
    }

    private static let launched = Mutex<Set<ObjectIdentifier>>([])

    /// Runs the launch rules once per process for these defaults (every engine and every monitor strip may call it; only the
    /// first call acts), so opening a project or a second engine mid-session never turns Dim off.
    public static func applyLaunchRulesOnce(defaults: UserDefaults = .standard) {
        let first = launched.withLock { $0.insert(ObjectIdentifier(defaults)).inserted }
        if first { applyLaunchRules(defaults: defaults) }
    }

    public static func store(_ s: Setting, defaults: UserDefaults = .standard) {
        defaults.set(s.levelDB, forKey: levelKey)
        defaults.set(s.dim, forKey: dimKey)
    }

    /// Short gain ramp (about 30 ms in 6 steps) so a change never clicks. Stepped from a utility timer, not the render thread.
    public struct Ramp: Sendable {
        public static let steps = 6
        public static let stepSeconds = 0.005
        public private(set) var value: Float
        public var target: Float { didSet { if target != oldValue { remaining = Self.steps } } }
        private var remaining = 0
        public init(current: Float) { value = current; target = current }

        /// Next gain value, nil once the target is reached.
        public mutating func next() -> Float? {
            guard value != target else { remaining = 0; return nil }
            remaining -= 1
            if remaining <= 0 { value = target } else { value += (target - value) / Float(remaining + 1) }
            return value
        }
    }
}
