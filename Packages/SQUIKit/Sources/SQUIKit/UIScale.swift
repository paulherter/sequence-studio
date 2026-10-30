import Foundation
import CoreGraphics
import SQCore

/// App-wide UI scale (`sq.ui.scale` in UserDefaults; key, steps and clamp are SQCore `InterfaceScale`). One factor
/// multiplies the Theme type sizes, row heights and control metrics (`Theme.Typography`, `Theme.Row`,
/// `Theme.Metrics`), so no view scales on its own.
///
/// The factor is live: `set` updates `current` and posts `didChange`; `UIScaleRelayout` (one observer) rebuilds the open
/// windows. The tokens are computed, so every read after the change sees the new value.
public enum UIScale {
    public static var defaultsKey: String { InterfaceScale.defaultsKey }
    /// The allowed factors, one step per Cmd+Plus / Cmd+Minus.
    public static var steps: [Double] { InterfaceScale.steps }
    public static var didChange: Notification.Name { InterfaceScale.didChange }

    nonisolated(unsafe) private static var live: Double = load(from: .standard)
    private static let lock = NSLock()

    /// The factor in force now (what the tokens multiply with).
    public static var current: Double { lock.lock(); defer { lock.unlock() }; return live }
    /// The stored factor.
    public static var pending: Double { load(from: .standard) }

    public static func clamp(_ v: Double) -> Double { InterfaceScale.clamp(v) }

    /// The next step above (`delta` > 0) or below (`delta` < 0) `value`; stays at the ends.
    public static func stepped(from value: Double, delta: Int) -> Double { InterfaceScale.stepped(from: value, delta: delta) }

    public static func load(from defaults: UserDefaults) -> Double { InterfaceScale.load(from: defaults) }

    public static func set(_ value: Double, in defaults: UserDefaults = .standard) {
        let v = clamp(value)
        InterfaceScale.store(v, in: defaults)
        if defaults === UserDefaults.standard { lock.lock(); live = v; lock.unlock() }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func increase(in defaults: UserDefaults = .standard) {
        set(stepped(from: load(from: defaults), delta: 1), in: defaults)
    }
    public static func decrease(in defaults: UserDefaults = .standard) {
        set(stepped(from: load(from: defaults), delta: -1), in: defaults)
    }
    public static func reset(in defaults: UserDefaults = .standard) { set(1, in: defaults) }

    /// The factor that turns a size made at `old` into one at `new`.
    public static func ratio(from old: Double, to new: Double) -> Double { old > 0 ? new / old : 1 }

    /// A point size rescaled from factor `old` to `new`, on half points.
    public static func rescaled(_ size: CGFloat, from old: Double, to new: Double) -> CGFloat {
        (size * CGFloat(ratio(from: old, to: new)) * 2).rounded() / 2
    }

    /// A token value times `factor`, on half points; the value itself at factor 1.
    public static func scaled(_ value: CGFloat, by factor: Double = current) -> CGFloat {
        factor == 1 ? value : (value * CGFloat(factor) * 2).rounded() / 2
    }
}
