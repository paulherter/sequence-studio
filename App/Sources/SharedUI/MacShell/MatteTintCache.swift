import AppKit
import SQAnalysis
import SQCore
import SQInspectorUI

/// The stored Magic mattes as tint pictures, read and made off the main thread; `MacMagicMasks` keeps one for its coverage planes.
@MainActor final class MatteTintCache<Value> {
    private var images: [String: Value] = [:]
    private var order: [String] = []
    /// Keys with no stored matte at this revision, and loads in flight: neither is asked again.
    private var missing: Set<String> = []
    private var pending: Set<String> = []
    /// `MagicTrackedFrames.shared.revision` the images were made at: a Track run (also with the same pick) and deleting
    /// tracked frames bump it, and the stored mattes are read again.
    private(set) var revision = -1
    /// The newest frame asked for: loads of frames scrubbed past are dropped instead of piling up in Debug.
    private var latestPts = Double.nan
    private let make: @Sendable (SubjectMatte) -> Value?

    private struct Box: @unchecked Sendable { let value: Value? }

    init(make: @escaping @Sendable (SubjectMatte) -> Value?) { self.make = make }

    /// A load for this matte is running (as opposed to known missing).
    func isPending(key: String, pts: Double) -> Bool { pending.contains("\(key)@\(pts)") }

    /// The cached tint, or nil while it is read and decoded off the main thread (`ready` runs on main when it is in).
    func image(key: String, pts: Double, ready: @escaping @MainActor () -> Void) -> Value? {
        let now = MagicTrackedFrames.shared.revision
        if now != revision { images = [:]; order = []; missing = []; pending = []; revision = now }
        let k = "\(key)@\(pts)"
        if let hit = images[k] { return hit }
        latestPts = pts
        guard !missing.contains(k), pending.insert(k).inserted else { return nil }
        let make = make
        Task.detached(priority: .userInitiated) { [weak self] in
            if await MainActor.run(body: { self?.latestPts != pts }) {
                await MainActor.run { if self?.revision == now { self?.pending.remove(k) } }
                return
            }
            let box = Box(value: MagicMatteStore.shared.matte(key: key, pts: pts).flatMap(make))
            await MainActor.run {
                guard let self, self.revision == now else { return }   // tracked frames changed meanwhile: asked again by the next update
                self.pending.remove(k)
                if let v = box.value {
                    self.images[k] = v; self.order.append(k)
                    if self.order.count > 12 { self.images[self.order.removeFirst()] = nil }
                } else { self.missing.insert(k) }
                ready()
            }
        }
        return nil
    }
}
