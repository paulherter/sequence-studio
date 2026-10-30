import Foundation
import SQCore
import SQEditorUI

/// FB-W: the session (new instances, transition Reset) and Effect Controls ("Use as Default", Reset) read the user's
/// defaults from the one library; their changes are written there, and every change (also from Preferences) comes back.
extension EditorPanels {
    func wireEffectDefaults() {
        let lib = EffectDefaultsLibrary.shared
        session.effectDefaults = lib.defaults
        effectModel.effectDefaults = lib.defaults
        let store: (EffectDefaults) -> Void = { [weak self] d in
            if !lib.replace(with: d) {
                self?.onStatus?("Your defaults could not be saved.")
                self?.applyEffectDefaults(lib.defaults)
            }
        }
        session.onEffectDefaultsChange = store
        effectModel.onEffectDefaultsChange = store
        NotificationCenter.default.addObserver(forName: EffectDefaultsLibrary.didChange, object: lib, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyEffectDefaults(lib.defaults) }
        }
    }

    private func applyEffectDefaults(_ d: EffectDefaults) {
        session.effectDefaults = d
        if effectModel.effectDefaults != d { effectModel.effectDefaults = d }
        syncTransitions(.selection)
    }
}
