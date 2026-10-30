import Foundation
import Synchronization

/// Where the analysis caches (stabilization, subject masks, Magic and subject mattes) live. The app points it at
/// `<cache folder>` (Settings > Media) at launch and on a folder change; before that, and in tests, every cache sits
/// where it always did. Existing files are not moved; entries are rebuilt on demand. The matte stores are created once
/// per launch, so a folder change reaches them at the next launch.
public enum AnalysisCacheLocation {
    private static let configured = Mutex<URL?>(nil)

    /// nil: the historic default (`~/Library/Caches/Sequence Studio`, mattes under the bundle identifier).
    public static func configure(root: URL?) { configured.withLock { $0 = root } }

    public static var configuredRoot: URL? { configured.withLock { $0 } }

    /// `<root>/<name>` when a root is configured, else the legacy folder.
    static func directory(_ name: String, legacy: () -> URL?) -> URL? {
        if let root = configuredRoot { return root.appendingPathComponent(name, isDirectory: true) }
        return legacy()
    }

    /// Legacy matte folder: `~/Library/Caches/<bundle>/<name>`.
    static func legacyBundleDirectory(_ name: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SequenceStudio").appendingPathComponent(name)
    }

    /// `~/Library/Caches/Sequence Studio/<name>` (temp when caches are unavailable).
    static func legacySharedDirectory(_ name: String) -> URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Sequence Studio", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// Folder `name` of the shared analysis cache.
    static func sharedDirectory(_ name: String) -> URL {
        configuredRoot?.appendingPathComponent(name, isDirectory: true) ?? legacySharedDirectory(name)
    }
}
