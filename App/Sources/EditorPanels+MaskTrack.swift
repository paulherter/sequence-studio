import AppKit
import SQAnalysis
import SQCore
import SQEditorUI

// The running mask track, path or Magic, lives in `MaskTrackActivity.shared` (one slot with its task): a second track
// button click while one runs stops that one, and so does removing its mask (`EditorPanels.stopTrackOfRemovedMask`).

/// Mask pen handles from the Program monitor overlay, and Track Mask Backward / Forward from the mask row in Effect
/// Controls: Vision follows the mask (Track choice: box for Position / + Scale, points for + Rotation / Perspective) from
/// the playhead to the clip's edge and keys the path per frame (one undo step "Track Mask"). Clicking a track button while a track runs stops it; nothing is written then.
// `TransformOverlayView.MaskEdit` is the shared `MaskHandleEdit` (SQDrawMonitor): its `maskID` and `editsAtPlayhead` live there.
extension EditorPanels {
    func applyMaskEdit(_ edit: TransformOverlayView.MaskEdit) {
        switch edit {
        case .tangent(let id, let v, let out, let offset, let independent):
            effectModel.moveMaskTangent(id, index: v, out: out, to: offset, independent: independent)
        case .move(let id, let delta): effectModel.moveMask(id, by: delta)
        case .insert(let id, let segment, let t): effectModel.insertMaskVertex(id, segment: segment, at: t)
        case .pen(let id, let segment, let t, let handle, let independent):
            effectModel.placeMaskVertex(id, segment: segment, at: t, handle: handle, independent: independent)
        case .remove(let id, let v): effectModel.removeMaskVertex(id, index: v)
        case .toggleSmooth(let id, let v): effectModel.toggleMaskVertexSmooth(id, index: v)
        }
    }

    func trackMask(_ id: ClipMask.ID, forward: Bool) {
        if effectModel.clip?.mask(id)?.source == .magic { trackMagicMask(id, .run(forward: forward)); return }
        if MaskTrackActivity.shared.stop(reason: "track button clicked again", keeps: true) { return }
        guard let clip = effectModel.clip, clip.sequence == nil, !clip.isGenerator, !clip.isStill, clip.holdFrame == nil,
              let media = session.project.media(clip.media) else {
            onStatus?("Mask tracking needs a video clip from a file.")
            return
        }
        guard effectModel.playheadInClip else { onStatus?("Put the playhead on the clip to track from there."); return }
        session.stopPlayback()
        let tracker = VisionMaskTracker(url: URL(fileURLWithPath: media.path), deinterlace: media.info?.video?.deinterlaceFieldOrder)
        let what = forward ? "forward" : "backward"
        let token = MaskTrackActivity.shared.start(mask: id, forward: forward, owner: session, clip: clip.id)
        trackGoesOn("Tracking mask \(what)…", token: token)
        let task = Task { @MainActor [weak self] in
            // A run that ends without a word (the tool was switched, its mask was removed, another run took the
            // slot) takes its "Tracking mask…" line with it.
            defer {
                self?.endTrackStatus(token)
                MaskTrackActivity.shared.finish(token)
            }
            guard let self else { return }
            do {
                let lookup: (Clip.ID) -> Clip? = { [weak self] cid in
                    self?.session.displayTimeline?.tracks.flatMap(\.clips).first { $0.id == cid }
                }
                let n = try await effectModel.trackMask(id, forward: forward, tracker: tracker, clipByID: lookup,
                                                        mayWrite: { MaskTrackActivity.shared.mayWrite(token) }) { p in
                    Task { @MainActor [weak self] in self?.showMaskTrackProgress(p, what: what, token: token) }
                }
                // A run that lost its slot meanwhile wrote nothing and says nothing: the newer run owns the status line.
                guard MaskTrackActivity.shared.isCurrent(token) else { return }
                onStatus?(n > 1 ? SQL10n.format("Tracked the mask over %@ frames.", String(n)) : "The mask could not be tracked from here.")
            } catch let stop as MaskTrackStopped {
                guard MaskTrackActivity.shared.mayWrite(token) else { return }
                onStatus?(stop.frames > 0 ? SQL10n.format("Mask tracking stopped; kept %@ frames.", String(stop.frames)) : "Mask tracking stopped.")
            } catch is CancellationError {
                guard MaskTrackActivity.shared.mayWrite(token) else { return }
                onStatus?("Mask tracking stopped.")
            } catch {
                guard MaskTrackActivity.shared.isCurrent(token) else { return }
                onStatus?("Mask tracking failed: the file could not be read.")
            }
        }
        MaskTrackActivity.shared.attach(task, to: token)
    }

    /// After a project change: a track whose mask no longer exists in this project (Delete Mask, undo, deleted effect
    /// or clip, removed sequence) is stopped. Nothing waits for it; it writes nothing more. A pick's own Magic track
    /// is noted as cut off: when its pick comes back (undo), it goes on (`MagicPickWatch.cutOff`). A run started
    /// with a track button is not resumed.
    func stopTrackOfRemovedMask() {
        guard MaskTrackActivity.shared.isRunning else { return }
        let project = session.project
        let key = MaskTrackActivity.shared.runKey
        let automatic = MaskTrackActivity.shared.run?.automatic == true
        if MaskTrackActivity.shared.stopIfMaskGone(owner: session, exists: { MagicPickWatch.mask($1, clip: $0, in: project) != nil }),
           let key {
            magicPickWatch.cutOff(key, automatic: automatic)
        }
    }

    private func showMaskTrackProgress(_ p: Double, what: String, token: Int) {
        let pct = Int((p * 100).rounded(.down))
        guard MaskTrackActivity.shared.progress(pct, token: token) else { return }
        trackGoesOn("Tracking mask \(what)… \(pct) % (click the track button again to stop)", token: token)
    }

    /// A line that says run `token` (path or Magic) goes on: noted, so the run's silent end clears it (`endTrackStatus`).
    func trackGoesOn(_ line: String, token: Int) {
        onStatus?(line)
        trackStatusLine.goesOn(token)
    }

    /// Run `token` ended: its going-on line, when nothing was written since, is cleared.
    func endTrackStatus(_ token: Int) {
        if trackStatusLine.ended(token) { onStatus?("") }
    }
}
