import AppKit
import SQAnalysis
import SQCore
import SQEditorUI

/// Tint of the evaluated Magic matte of the shown clip in the Program monitor, so a tracked mask is visible without leaving the
/// Mask tool. On by default; Program monitor menu > Mask Tint. Subject and Picture mattes only exist inside the render
/// pipeline (no cached matte the monitor can read), so they get no tint yet.
/// The stored mattes as tint pictures, read and made off the main thread: the AppKit monitor's CGImages (`shared`) and
/// the shared UI's coverage planes (`MacMagicMasks`) each keep one.
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

@MainActor private enum MaskTintCache {
    static let shared: MatteTintCache<CGImage> = {
        let color = Theme.Colors.yellow
        return MatteTintCache { MagicHighlight.image($0, color: color, alpha: 0.3) }
    }()
    static func isPending(key: String, pts: Double) -> Bool { shared.isPending(key: key, pts: pts) }
    static func image(key: String, pts: Double, ready: @escaping @MainActor () -> Void) -> CGImage? {
        shared.image(key: key, pts: pts, ready: ready)
    }
}

extension EditorPanels {
    static let maskTintKey = "sq.showMaskTint"
    /// Default on: the key only exists once the user turned it off.
    static var showsMaskTint: Bool { UserDefaults.standard.object(forKey: maskTintKey) as? Bool ?? true }

    func toggleMaskTint() {
        UserDefaults.standard.set(!Self.showsMaskTint, forKey: Self.maskTintKey)
        updateOverlay()
    }

    /// Called from `updateOverlay`: the matte of every enabled Magic mask of the shown clip at the playhead's source frame,
    /// while the Mask tool is active or a mask is selected in Effect Controls; nothing while playing.
    func updateMaskTint() {
        let o = surface.overlay
        var maskSelected = false
        if case .mask? = effectModel.selectedSection { maskSelected = true }
        guard Self.showsMaskTint, !session.isPlaying, let c = effectModel.clip, c.id == overlayTarget?.clip,
              effectModel.playheadInClip, surface.tool.maskModeValue != nil || maskSelected else {
            if !o.maskTints.isEmpty { o.maskTints = [] }
            return
        }
        let fd = effectModel.frameDuration
        let local = min(effectModel.localPlayhead.snapped(to: fd), max(c.duration - fd, .zero))
        let t = c.shownSourceTime(atLocal: local, frameDuration: fd)      // the picture's frame, not the instant (reversed: one frame off)
        let pts = Double(t.value) / Double(max(t.timescale, 1))
        // In Magic mode the active mask's matte is already drawn as the pick (`updateMagicPick`): once, not twice.
        let drawnAsPick = o.maskTool == .magic ? effectModel.activeMagicMaskID : nil
        let masks = c.masks.filter { $0.enabled && $0.source == .magic && $0.id != drawnAsPick }
        var waiting = false
        let ready: @MainActor () -> Void = { [weak self] in self?.updateOverlay() }
        let tints = masks.compactMap { m -> CGImage? in
            // What the mask draws: a Face / Skin mask its narrowed matte, the whole person where that is missing.
            if let k = effectModel.magicPartKey(m.id) {
                if let i = MaskTintCache.image(key: k, pts: pts, ready: ready) { return i }
                // The narrowed matte is still being read: wait for it, even when the whole person is known missing.
                if MaskTintCache.isPending(key: k, pts: pts) { waiting = true }
            }
            guard let k = effectModel.magicCacheKey(m.id) else { return nil }
            if let i = MaskTintCache.image(key: k, pts: pts, ready: ready) { return i }
            if MaskTintCache.isPending(key: k, pts: pts) { waiting = true }
            return nil
        }
        // A tint still being read keeps the previous one on screen (no flicker while scrubbing); the result redraws.
        if waiting && tints.isEmpty && !o.maskTints.isEmpty { return }
        o.maskTints = tints
    }
}
