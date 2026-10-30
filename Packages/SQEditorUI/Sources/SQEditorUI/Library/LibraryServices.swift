import Foundation
import SQLibrary

/// Production wiring of the Library panel: FSEvents watcher, preview cache and provider, preset store and the
/// favorites and watched-folder files in Application Support.
public enum LibraryServices {
    public static var supportDirectory: URL { LibraryStores.supportDirectory }

    /// The one preset store of the app (`LibraryStores.presetStore`, which the session layer reads too).
    public static var presetStore: PresetStore { LibraryStores.presetStore }

    /// The model is not running yet: call `start(_:)`.
    @MainActor
    public static func makeModel(defaults: UserDefaults = .standard) -> LibraryPanelModel {
        let support = supportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = presetStore
        let cache = PreviewCache.appCache()
        let coordinator = PreviewCoordinator(cache: cache, provider: MediaPreviewProvider(cache: cache))
        let model = LibraryPanelModel(index: LibraryIndex(watcher: FSEventsFolderWatcher()), presetStore: store,
                                      coordinator: coordinator, favoritesURL: support.appendingPathComponent("favorites.json"))
        model.sfxDirectory = support.appendingPathComponent("SFX", isDirectory: true)
        model.lookStore = .shared
        model.onFoldersChanged = { folders in
            LibraryFolderStore.save(folders, defaults)
        }
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
}
