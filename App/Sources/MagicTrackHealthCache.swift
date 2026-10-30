import Foundation
import SQAnalysis
import SQCore
import SQEditorSession
import SQInspectorUI

/// The portable weak-tracking cache (SQEditorSession) over the Mac's matte store: it reads the stored matte areas of a key,
/// and `forget` also drops the key lanes' tracked frames.
extension MagicTrackHealthCache {
    @MainActor static func mac(store: MagicMatteStore = .shared) -> MagicTrackHealthCache {
        let cache = MagicTrackHealthCache(samples: { store.healthSamples(key: $0) })
        cache.onForget = { if store === MagicMatteStore.shared { MagicTrackedFrames.shared.forget() } }
        return cache
    }
}
