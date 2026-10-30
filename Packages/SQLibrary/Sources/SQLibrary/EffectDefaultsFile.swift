import Foundation
import SQCore

/// FB-W: the user's effect and transition defaults, `<Application Support>/Sequence Studio/Library/defaults.json`
/// (next to `presets.json`). Small, so it is read and written whole and synchronously.
public enum EffectDefaultsFile {
    public static let formatVersion = 1

    private struct File: Codable {
        var formatVersion: Int
        var payloadVersion: Int
        var defaults: EffectDefaults
    }

    public static func fileURL(applicationSupport: URL) -> URL {
        PresetStore.fileURL(applicationSupport: applicationSupport)
            .deletingLastPathComponent().appendingPathComponent("defaults.json")
    }

    /// Empty when there is no file. A newer format or payload throws `LibraryStoreError.newerFormat` (file untouched);
    /// a corrupt file is moved aside and the defaults start empty.
    public static func load(_ url: URL) throws -> EffectDefaults {
        guard FileManager.default.fileExists(atPath: url.path) else { return EffectDefaults() }
        let data = try Data(contentsOf: url)
        struct Header: Decodable { var formatVersion: Int; var payloadVersion: Int? }
        do {
            let h = try JSONDecoder().decode(Header.self, from: data)
            if h.formatVersion > formatVersion { throw LibraryStoreError.newerFormat(found: h.formatVersion, supported: formatVersion) }
            if let p = h.payloadVersion, p > EffectDefaults.payloadVersion {
                throw LibraryStoreError.newerFormat(found: p, supported: EffectDefaults.payloadVersion)
            }
            let file = try JSONDecoder().decode(File.self, from: data)
            // Through the payload initializer, so its upgrades (old shadow colors, custom alignment) run.
            return try EffectDefaults(payload: try file.defaults.payload(), version: file.payloadVersion)
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            try JSONFileIO.backupCorrupt(url)
            return EffectDefaults()
        }
    }

    public static func save(_ defaults: EffectDefaults, to url: URL) throws {
        try JSONFileIO.writeAtomically(File(formatVersion: formatVersion, payloadVersion: EffectDefaults.payloadVersion,
                                            defaults: defaults), to: url)
    }
}
