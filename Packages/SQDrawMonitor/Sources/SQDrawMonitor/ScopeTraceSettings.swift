import Foundation
import SQDrawKit
import SQUIKit

/// The waveform settings of the scopes, one set for every scopes view on both platforms (the Mac AppKit `ScopesView`, the
/// drawn `ScopesPanel`): the trace intensity of the Waveform and RGB Parade (the renderers' `intensity` gain), chosen
/// from `menuItems()` and kept in the defaults. The vectorscope and histogram keep their own map (gain 1).
@MainActor
public final class ScopeTraceSettings {
    public static let shared = ScopeTraceSettings()
    public static let defaultsKey = "sq.scopes.waveformIntensity"
    /// Posted (object: the settings) when a value changes, so every scopes view redraws.
    public static let didChange = Notification.Name("sq.scopes.waveformSettingsDidChange")
    /// The menu's intensity steps.
    public static let steps: [Float] = [0.5, 0.75, 1, 1.5, 2]
    public static let range: ClosedRange<Float> = 0.25...4
    /// The settings button's tip and menu header.
    public static let buttonTip = "Waveform settings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.defaultsKey) as? Double
        intensity = stored.map { min(max(Float($0), Self.range.lowerBound), Self.range.upperBound) } ?? 1
    }

    /// The trace gain of the Waveform and RGB Parade (1 = the renderers' default map).
    public var intensity: Float {
        didSet {
            let v = min(max(intensity, Self.range.lowerBound), Self.range.upperBound)
            if v != intensity { intensity = v }     // inside didSet: no second observer call
            guard v != oldValue else { return }
            defaults.set(Double(v), forKey: Self.defaultsKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// The scopes these settings apply to.
    public static func hasSettings(_ k: ScopeKind) -> Bool { k == .waveform || k == .parade }

    /// The gain `k` is drawn with.
    public func intensity(for k: ScopeKind) -> Float { Self.hasSettings(k) ? intensity : 1 }

    /// The settings menu: a header and the intensity steps, the current one checked.
    public func menuItems() -> [SQMenuItem] {
        [.header("Intensity")] + Self.steps.map { v in
            SQMenuItem(title: "\(Int((v * 100).rounded()))%", isChecked: abs(intensity - v) < 0.001,
                       action: { [weak self] in self?.intensity = v })
        }
    }
}
