import Foundation
import SQCore
import SQEditorSession
import SQLibrary

/// Production wiring of the Library model for the shared draw UI (Windows dock, Mac `SQ_SHARED_UI`): the same files in
/// Application Support as the Mac `LibraryServices` (favorites, watched folders, presets, SFX bin), with the platform's
/// folder watcher and preview provider.
public enum LibraryDrawServices {
    /// The model is not running yet: call `start(_:)`.
    @MainActor
    public static func makeModel(defaults: UserDefaults = .standard) -> LibraryPanelModel {
        let support = LibraryStores.supportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let cache = PreviewCache.appCache()
        let coordinator = PreviewCoordinator(cache: cache, provider: platformProvider(cache))
        let model = LibraryPanelModel(index: LibraryIndex(watcher: platformWatcher()), presetStore: LibraryStores.presetStore,
                                      coordinator: coordinator, favoritesURL: support.appendingPathComponent("favorites.json"))
        model.sfxDirectory = support.appendingPathComponent("SFX", isDirectory: true)
        model.lookStore = .shared
        model.onFoldersChanged = { LibraryFolderStore.save($0, defaults) }
        return model
    }

    /// Restores the saved watched folders, then loads favorites, presets and the index.
    @MainActor
    public static func start(_ model: LibraryPanelModel, defaults: UserDefaults = .standard) async {
        let folders = LibraryFolderStore.load(defaults)
        if !folders.isEmpty { await model.restoreFolders(folders) }
        LibraryPanelModel.registerInstalledPackFonts()
        await model.start()
    }

    static func platformWatcher() -> any FolderWatching {
        #if os(macOS)
        FSEventsFolderWatcher()
        #else
        PollingFolderWatcher()
        #endif
    }

    static func platformProvider(_ cache: PreviewCache) -> any PreviewProvider {
        #if os(macOS)
        MediaPreviewProvider(cache: cache)
        #else
        UnavailablePreviewProvider()
        #endif
    }
}

/// No thumbnails or waveforms from the model's preview queue: the draw panel takes its tiles from the host's media atlas.
/// shortcut: no waveform strips for audio tiles off the Mac; upgrade when SQMedia decodes audio peaks on Windows.
struct UnavailablePreviewProvider: PreviewProvider {
    struct Unavailable: Error {}
    func generate(_ request: PreviewRequest, to destination: URL) async throws { throw Unavailable() }
}

/// A folder watcher that compares a cheap signature (file count, newest modification date) every few seconds.
/// shortcut: polling, not ReadDirectoryChangesW; upgrade when the Windows backend gets a native change notification seam.
final class PollingFolderWatcher: FolderWatching, @unchecked Sendable {
    let interval: TimeInterval
    init(interval: TimeInterval = 3) { self.interval = interval }

    static func signature(_ url: URL) -> String {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return "missing"
        }
        var count = 0
        var newest = 0.0
        for case let f as URL in e {
            count += 1
            let d = FileWalk.Values.read(f, keys: Set(keys))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            newest = max(newest, d)
        }
        return "\(count):\(newest)"
    }

    func watch(_ url: URL, onChange: @escaping @Sendable () -> Void) -> any FolderWatchToken {
        let token = Token()
        let interval = interval
        Task.detached {
            var last = Self.signature(url)
            while !token.isCanceled {
                try? await Task.sleep(for: .seconds(interval))
                if token.isCanceled { break }
                let now = Self.signature(url)
                if now != last { last = now; onChange() }
            }
        }
        return token
    }

    final class Token: FolderWatchToken, @unchecked Sendable {
        private let lock = NSLock()
        private var canceled = false
        var isCanceled: Bool { lock.withLock { canceled } }
        func cancel() { lock.withLock { canceled = true } }
    }
}
