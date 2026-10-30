import Foundation
import SQCore

/// App-wide media management defaults (Preferences > Media: Outside Files, Project Folder, Library). A project's own
/// `MediaPolicy` overrides them. Shared by the Mac app and the portable shell (one store, the Mac keys).
public enum MediaSettings {
    public static let outsideKey = "sq.media.outside"
    public static let libraryKey = "sq.media.copyLibraryItems"
    public static let watchKey = "sq.media.watchProjectFolder"

    public static var defaults: MediaPolicyDefaults {
        get { load(from: .standard) }
        set { store(newValue, in: .standard) }
    }

    public static func load(from d: UserDefaults) -> MediaPolicyDefaults {
        MediaPolicyDefaults(
            outside: d.string(forKey: outsideKey).flatMap(OutsideMediaMode.init(rawValue:)) ?? .ask,
            copyLibraryItems: d.object(forKey: libraryKey) == nil ? true : d.bool(forKey: libraryKey),
            watchFolder: d.object(forKey: watchKey) == nil ? true : d.bool(forKey: watchKey))
    }

    public static func store(_ v: MediaPolicyDefaults, in d: UserDefaults) {
        d.set(v.outside.rawValue, forKey: outsideKey)
        d.set(v.copyLibraryItems, forKey: libraryKey)
        d.set(v.watchFolder, forKey: watchKey)
    }
}

/// Preference: open the import window when an SD card or external drive mounts. Default on.
public enum CardImportSettings {
    public static let key = "sq.autoImportFromCards"

    public static var enabled: Bool {
        get { isEnabled(.standard) }
        set { setEnabled(newValue, defaults: .standard) }
    }

    public static func isEnabled(_ d: UserDefaults) -> Bool { d.object(forKey: key) == nil ? true : d.bool(forKey: key) }
    public static func setEnabled(_ on: Bool, defaults d: UserDefaults) { d.set(on, forKey: key) }
}
