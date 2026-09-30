import Foundation
import SSLibrary

/// Production wiring of the Library panel: FSEvents watcher, preview cache and provider, preset store and the
/// favorites and watched-folder files in Application Support.
public enum LibraryServices {
    static let foldersKey = "library.watchedFolders"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sequence Studio", isDirectory: true)
    }

    /// The model is not running yet: call `start(_:)`.
    @MainActor
    public static func makeModel(defaults: UserDefaults = .standard) -> LibraryPanelModel {
        let support = supportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = (try? PresetStore(applicationSupport: support))
            ?? (try! PresetStore(applicationSupport: FileManager.default.temporaryDirectory
                .appendingPathComponent("ss-presets-\(UUID().uuidString)", isDirectory: true)))
        let cache = PreviewCache(cachesDirectory: PreviewCache.defaultCachesDirectory())
        let coordinator = PreviewCoordinator(cache: cache, provider: MediaPreviewProvider(cache: cache))
        let model = LibraryPanelModel(index: LibraryIndex(watcher: FSEventsFolderWatcher()), presetStore: store,
                                      coordinator: coordinator, favoritesURL: support.appendingPathComponent("favorites.json"))
        model.onFoldersChanged = { folders in
            if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: foldersKey) }
        }
        return model
    }

    /// Restores the saved watched folders, then loads favorites, presets and the index.
    @MainActor
    public static func start(_ model: LibraryPanelModel, defaults: UserDefaults = .standard) async {
        if let data = defaults.data(forKey: foldersKey),
           let folders = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            await model.restoreFolders(folders)
        }
        await model.start()
    }
}
