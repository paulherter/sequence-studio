import Foundation
import SQAudioFX

/// Preferences > Audio > De-Click for shells that do not link SQAudioFX themselves (the portable Preferences dialog).
public enum AudioPreferences {
    /// The stored setting; absent means on.
    public static func deClick(_ defaults: UserDefaults = .standard) -> Bool { AudioDeClick.isEnabled(in: defaults) }
    public static func setDeClick(_ on: Bool, defaults: UserDefaults = .standard) { defaults.set(on, forKey: AudioDeClick.defaultsKey) }
}
