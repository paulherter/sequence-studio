import Foundation
import SQAnalysis
import SQAppShell
import SQCore
import SQDrawKit
import SQEditorSession
import SQInspectorUI

/// The Mask tool's Magic mode on Windows (SQAppShell `AppMagicMasks`): a click picks the object under it with EdgeTAM
/// (`WinMagicEngine`, ONNX Runtime + DirectML), stores its matte in `FrameMatteStore` for the compositor, and the track
/// buttons of Effect Controls follow it frame by frame. The Mac equivalents are `MacMagicMasks` / `MagicMaskTool` /
/// `EditorPanels.trackMagicMask`.
/// A click on another frame than the pick's corrects the tracked matte there (`correct`), as on the Mac.
/// Mattes are kept in the analysis cache by pick (`FrameMatteStore`, the Mac file format).
/// Hover: the object under the pointer is picked off the main thread (`HoverFeeder`, one answer at a time) and laid over the
/// Mask Tint at 45 % (the Mac AppKit hover highlight, whose color is the accent; here the tint's yellow). A pick does not
/// track on its own, as on the Mac (adb2016a5: the Track buttons do).
/// shortcut: the highlight is one EdgeTAM click per rest of the pointer (no all-objects map as Vision gives), so it lags
/// the pointer by ~0.1-0.3 s; upgrade with a cached image embedding per frame.
@MainActor
final class WinMagicMasks: AppMagicMasks {
    private let model: EffectControlsModel
    private let session: EditorSession
    private let status: (String) -> Void
    private let engine = WinMagicEngine.shared
    private var busy = false
    /// Called when a Track run wrote or kept mattes (the weak-track spans on the timeline are stale).
    var onTracked: (() -> Void)?
    private var tintMade: (keys: [String], image: RGBAImage, generation: Int)?
    private var tintGeneration = 0
    private let hoverSource = HoverSourceBox()
    private let hoverFeeder: HoverFeeder<SubjectMatte>
    private var hoverGeneration = 0

    init(model: EffectControlsModel, session: EditorSession, status: @escaping (String) -> Void) {
        self.model = model
        self.session = session
        self.status = status
        let box = hoverSource, engine = engine
        hoverFeeder = HoverFeeder { point, seconds in
            guard let s = box.get() else { return nil }
            return try? await engine.hover(path: s.path, media: s.media, point: point, at: seconds)
        }
        model.onTrackMagic = { [weak self] id, command in self?.track(id, command) }
        hoverFeeder.onChange = { [weak self] in
            self?.hoverGeneration += 1
            self?.session.engine.redraw()
        }
    }

    func refresh(target: Clip.ID?, magicOn: Bool, isPlaying: Bool) {
        if !magicOn || isPlaying { hoverFeeder.clear() }
    }

    // MARK: Hover

    var hasHover: Bool { hoverFeeder.answer != nil || hoverFeeder.isPending }

    func hover(_ p: Vec2?, target: Clip.ID?) {
        guard let p, !busy, !MaskTrackActivity.shared.magic.isTracking, let clip = model.clip, clip.id == target ?? clip.id,
              clip.sequence == nil, !clip.isGenerator, !clip.isStill, clip.holdFrame == nil,
              let media = session.project.media(clip.media), model.playheadInClip else {
            hoverFeeder.clear()
            return
        }
        let fd = model.frameDuration
        let local = min(model.localPlayhead.snapped(to: fd), max(clip.duration - fd, .zero))
        let t = clip.shownSourceTime(atLocal: local, frameDuration: fd)
        hoverSource.set(HoverSourceBox.Source(path: media.path, media: clip.media))
        hoverFeeder.move(p, seconds: WinMagicEngine.seconds(t))
    }

    // MARK: Pick

    func click(_ p: Vec2, target: Clip.ID?, subtract: Bool, newMask: Bool) {
        guard !busy else { return }
        guard let clip = model.clip, clip.id == target ?? clip.id, clip.sequence == nil, !clip.isGenerator, !clip.isStill,
              clip.holdFrame == nil, let media = session.project.media(clip.media), model.playheadInClip else {
            status("Magic works on video clips: select one under the playhead (click it in the picture or the timeline).")
            return
        }
        if !newMask, let id = model.activeMagicMaskID, model.magicClickCorrects(id) {
            correct(id, p, subtract: subtract, path: media.path, media: clip.media)
            return
        }
        guard let edit = model.magicClickEdit(at: p, subtract: subtract, newMask: newMask), let key = edit.key,
              let at = edit.points.last?.sourceTime else {
            if subtract { status("Click an object first; Remove (or Option-click) takes areas out of a pick.") }
            return
        }
        busy = true
        status("Magic is picking the object… (the first pick loads the model)")
        // The clicks of this frame only: corrections made on other frames belong to those frames.
        let points = edit.points.filter { $0.sourceTime == at }, path = media.path, id = clip.media
        let seconds = WinMagicEngine.seconds(at)
        let engine = engine
        Task { @MainActor [weak self] in
            defer { self?.busy = false }
            let matte: SubjectMatte?
            do {
                matte = try await Task.detached { try await engine.pick(path: path, media: id, key: key, points: points, at: seconds) }.value
            } catch {
                self?.status("\(error)")
                return
            }
            guard let self else { return }
            guard matte != nil else { self.status("Nothing to pick there: Magic finds people, animals and objects."); return }
            // The matte is stored: only now the click joins the project (one undo step), so it never holds a point without a matte.
            self.hoverFeeder.clear()
            self.model.applyMagicClick(edit)
            MaskTrackActivity.shared.magic.pickStored()
            self.session.engine.redraw()
            self.status("Picked on this frame. Track it with the buttons in Effect Controls. Click to add, Remove (or Option-click) to take areas out, Shift-click for a new mask.")
        }
    }

    /// A click on a frame other than the pick's: the tracked matte there gains (or loses) the object under the click. The
    /// project changes only once the corrected matte is stored (one undo step); the frames before it (after it, when
    /// the correction lies before the pick) are carried over to the new pick's key.
    private func correct(_ id: ClipMask.ID, _ p: Vec2, subtract: Bool, path: String, media: UUID) {
        guard let oldKey = model.magicCacheKey(id), let anchor = model.clip?.mask(id)?.magic?.anchorTime,
              let edit = model.magicClickEdit(at: p, subtract: subtract, newMask: false), edit.mask == id, let key = edit.key,
              let at = edit.points.last?.sourceTime else { return }
        guard !MaskTrackActivity.shared.magic.isTracking else { status("Stop the running track first, then correct the mask."); return }
        let seconds = WinMagicEngine.seconds(at), forward = seconds > WinMagicEngine.seconds(anchor)
        busy = true
        status("Magic is correcting the mask on this frame…")
        let engine = engine
        Task { @MainActor [weak self] in
            defer { self?.busy = false }
            let matte: SubjectMatte?
            do {
                matte = try await Task.detached {
                    try await engine.correct(path: path, media: media, key: key, oldKey: oldKey, point: p, subtract: subtract,
                                             at: seconds, keepBefore: forward)
                }.value
            } catch {
                self?.status("\(error)")
                return
            }
            guard let self else { return }
            guard matte != nil else {
                self.status(subtract ? "Nothing would be left of the mask on this frame, or the object is not in it: the mask stays as it is."
                                     : "Track the Magic mask to this frame first, then click here to correct it.")
                return
            }
            guard self.model.magicCacheKey(id) == oldKey else {
                engine.store.remove(key: key)
                self.status("The mask changed before the correction was ready: click again.")
                return
            }
            self.model.applyMagicClick(edit)
            self.session.engine.redraw()
            self.status(subtract ? "Removed from the mask on this frame. Track on with the buttons in Effect Controls."
                                 : "Added to the mask on this frame. Track on with the buttons in Effect Controls.")
        }
    }

    // MARK: Track

    /// The Magic mask's track controls: one frame back / forward, on to the clip's start / end, or Stop (nil).
    func track(_ id: ClipMask.ID, _ command: MagicTrackControl.Command?) {
        let activity = MaskTrackActivity.shared
        guard let command else {
            if activity.magic.stop() { _ = activity.stop(reason: "Stop pressed", keeps: true) }
            return
        }
        guard !activity.magic.isTracking else { return }
        guard let clip = model.clip, clip.sequence == nil, !clip.isGenerator, !clip.isStill, clip.holdFrame == nil,
              let media = session.project.media(clip.media) else { status("Magic tracking needs a video clip from a file."); return }
        let forward = switch command { case .step(let f), .run(let f): f }
        guard let key = model.magicCacheKey(id), let range = model.magicTrackRange(id, forward: forward) else {
            status("Pick an object with the Mask tool (Magic) first, with the playhead on the clip.")
            return
        }
        let fd = media.info?.video.map { Double($0.nominalFrameDuration.value) / Double(max($0.nominalFrameDuration.timescale, 1)) } ?? 1.0 / 30
        guard let leg = activity.magic.begin(command, playhead: range.from, edge: range.to, frame: fd) else {
            status(forward ? "The playhead is on the last frame: nothing to track forward." : "The playhead is on the first frame: nothing to track backward.")
            return
        }
        session.stopPlayback()
        var stepsPlayhead = false
        if case .step = command { stepsPlayhead = true }
        let token = activity.start(mask: id, forward: leg.forward, owner: session, key: key, clip: clip.id)
        status("Tracking Magic mask \(leg.forward ? "forward" : "backward")… (the first run loads the model)")
        let path = media.path, mediaID = clip.media
        let keep = activity.keepsFrames(token)
        let engine = engine
        let task = Task { @MainActor [weak self] in
            defer {
                MaskTrackActivity.shared.finish(token)
                MaskTrackActivity.shared.magic.finish()
            }
            do {
                let result = try await Task.detached {
                    try await engine.track(path: path, media: mediaID, key: key, from: leg.from, to: leg.to, keep: keep) { p in
                        Task { @MainActor in
                            guard MaskTrackActivity.shared.progress(Int((p * 100).rounded(.down)), token: token) else { return }
                            MaskTrackActivity.shared.magic.progress(p)
                        }
                    }
                }.value
                guard let self, MaskTrackActivity.shared.isCurrent(token) else { return }
                self.onTracked?()   // the weak-track spans on the timeline are stale now
                self.session.engine.redraw()
                if stepsPlayhead, result.frames > 0 { self.session.stepFrames(leg.forward ? 1 : -1) }
                if result.frames == 0 {
                    self.status(result.lost ? "The object was not found from this frame on: click it here to pick it up again."
                                            : "Nothing to follow here: pick the object on this frame first.")
                } else if result.lost {
                    self.status("Tracked \(result.frames) frames; the object was not found after that: click it there to pick it up again.")
                } else {
                    self.status("Tracked the Magic mask over \(result.frames) frames.")
                }
            } catch is CancellationError {
                guard let self, MaskTrackActivity.shared.mayWrite(token) else { return }
                self.status("Magic tracking stopped (frames done so far are kept).")
                self.onTracked?()
                self.session.engine.redraw()
            } catch {
                self?.status("\(error)")
            }
        }
        activity.attach(task, to: token)
    }

    // MARK: Mask Tint

    /// The stored mattes of `masks` at source second `pts` as one white picture whose alpha is the 30 % tints laid over
    /// each other (the Mac `MacMagicMasks.maskTint`).
    func maskTint(masks: [ClipMask.ID], pts: Double) -> MaskTintPicture {
        let store = engine.store
        var found: [(key: String, matte: SubjectMatte)] = []
        for id in masks {
            guard let k = model.magicCacheKey(id), let m = store.matte(key: k, pts: pts) else { continue }
            found.append(("\(k)@\(pts)", m))
        }
        var hover: SubjectMatte?
        if let h = hoverFeeder.answer, abs(h.seconds - pts) < 1e-6 { hover = h.value }
        guard let first = found.first?.matte ?? hover else { return MaskTintPicture() }
        var keys = found.map(\.key) + ["\(store.revision)"]
        if hover != nil { keys.append("hover\(hoverGeneration)") }
        if let made = tintMade, made.keys == keys { return MaskTintPicture(image: (made.image, made.generation)) }
        let w = first.width, h = first.height, n = w * h
        let layers = found.map(\.matte) + (hover.map { [$0] } ?? [])
        let strengths = Array(repeating: Float(0.3), count: found.count) + (hover == nil ? [] : [Float(0.45)])
        var inverse = [Float](repeating: 1, count: n)
        for (m, k) in zip(layers, strengths) where m.values.count == n {
            for i in 0..<n { inverse[i] *= 1 - min(max(m.values[i], 0), 1) * k }
        }
        var px = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n { px[i * 4 + 3] = UInt8(((1 - inverse[i]) * 255).rounded()) }
        tintGeneration += 1
        let image = RGBAImage(width: w, height: h, pixels: px)
        tintMade = (keys, image, tintGeneration)
        return MaskTintPicture(image: (image, tintGeneration))
    }
}

/// The file the hover reads, set on the main actor and read by the feeder's worker.
final class HoverSourceBox: @unchecked Sendable {
    struct Source { var path: String; var media: UUID }
    private let lock = NSLock()
    private var source: Source?
    func set(_ s: Source) { lock.lock(); source = s; lock.unlock() }
    func get() -> Source? { lock.lock(); defer { lock.unlock() }; return source }
}
