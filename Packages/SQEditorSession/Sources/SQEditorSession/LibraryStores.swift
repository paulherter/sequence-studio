import Foundation
import SQLibrary

/// The app's Application Support folder and its one preset store, below the Library panel so the session layer
/// (caption looks, Look store) reads the same instance. `LibraryServices` forwards to it.
public enum LibraryStores {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sequence Studio", isDirectory: true)
    }

    /// The one preset store of the app (Library panel, easing presets, effect presets). One actor per file: two
    /// stores on the same presets.json would each write their own stale copy over the other's changes.
    public static let presetStore: PresetStore = {
        // PresetStore adds "Sequence Studio/Library" itself: give it the Application Support root.
        (try? PresetStore(applicationSupport: PresetStore.defaultApplicationSupport()))
            ?? (try! PresetStore(applicationSupport: FileManager.default.temporaryDirectory
                .appendingPathComponent("sq-presets-\(UUID().uuidString)", isDirectory: true), standIn: true))
    }()
}
