import Foundation

/// Preferences > Interface Size as stored (`sq.ui.scale`): the steps and the clamp, without UI. The Mac `UIScale`
/// (SQUIKit) adds the live factor its tokens multiply with; the portable Preferences and the Windows theme read this.
public enum InterfaceScale {
    public static let defaultsKey = "sq.ui.scale"
    /// The allowed factors, one step per Cmd+Plus / Cmd+Minus.
    public static let steps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5]
    /// Posted after `store` (the Mac `UIScaleRelayout` rebuilds its windows on it).
    public static let didChange = Notification.Name("sq.uiScaleDidChange")

    public static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 1 }
        return min(max(v, steps.first!), steps.last!)
    }

    /// The next step above (`delta` > 0) or below (`delta` < 0) `value`; stays at the ends.
    public static func stepped(from value: Double, delta: Int) -> Double {
        let v = clamp(value)
        if delta > 0 { return steps.first { $0 > v + 1e-9 } ?? steps.last! }
        if delta < 0 { return steps.last { $0 < v - 1e-9 } ?? steps.first! }
        return v
    }

    public static func load(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: defaultsKey) != nil else { return 1 }
        return clamp(defaults.double(forKey: defaultsKey))
    }

    /// Writes the clamped factor (a non-finite value stores 1). Callers that keep a live copy update it themselves.
    public static func store(_ value: Double, in defaults: UserDefaults = .standard) {
        defaults.set(clamp(value), forKey: defaultsKey)
    }
}
