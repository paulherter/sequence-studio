import Foundation
import SQLibrary
import SQInspectorUI
import SQEditorSession

/// The Library's SFX bin: a watched folder in Application Support that is created on demand and starts empty
/// (nothing is bundled, the user adds sound files). "Whoosh at Selected Cuts" takes its sound from here.
extension LibraryPanelModel {
    public static let sfxBinName = "SFX"

    /// The SFX bin when it exists in the Library.
    public var sfxFolder: WatchedFolder? {
        guard let dir = sfxDirectory?.standardizedFileURL else { return nil }
        return folders.first { $0.folder.url.standardizedFileURL == dir }?.folder
    }

    /// Creates the bin (folder on disk and Library entry) when it does not exist yet, without changing the selection.
    @discardableResult
    public func ensureSFXBin() async -> WatchedFolder? {
        if let f = sfxFolder { return f }
        guard let dir = sfxDirectory else { return nil }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        await restoreFolders([WatchedFolder(url: dir, displayName: Self.sfxBinName)])
        onFoldersChanged?(folders.map(\.folder))
        return sfxFolder
    }

    /// Copies audio files into the SFX bin (creating it first); name clashes get a number. Returns the files copied.
    @discardableResult
    public func addToSFXBin(_ urls: [URL]) async -> Int {
        guard let folder = await ensureSFXBin() else { return 0 }
        var copied = 0
        for url in urls where LibraryItemKind.classify(url) == .audio {
            if url.deletingLastPathComponent().standardizedFileURL == folder.url.standardizedFileURL { continue }
            var dest = folder.url.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                let base = url.deletingPathExtension().lastPathComponent
                dest = folder.url.appendingPathComponent("\(base) \(n)").appendingPathExtension(url.pathExtension)
                n += 1
            }
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { copied += 1 }
        }
        if copied > 0 { await rescan(folder.id) }
        return copied
    }

    /// Audio files of the SFX bin by name.
    public var sfxSounds: [URL] {
        guard let f = sfxFolder else { return [] }
        return entries(in: f.id).filter { $0.kind == .audio }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { $0.url(in: f) }
    }

    /// Remembers the whoosh the user picked (from the Library item menu).
    public func chooseWhoosh(_ url: URL) { whooshDefaults.set(url.path, forKey: Self.lastWhooshKey) }

    /// The sound "Whoosh at Selected Cuts" uses from the Sequence menu: the last chosen one while it is still in the bin,
    /// else the bin's first audio file. Nil when the bin is empty or missing.
    public var whooshSound: URL? {
        let sounds = sfxSounds
        if let path = whooshDefaults.string(forKey: Self.lastWhooshKey),
           let hit = sounds.first(where: { $0.path == path }) { return hit }
        return sounds.first
    }
}
