import AppKit
import SQAppShell
import SQAnalysis
import SQCore
import SQEditorSession
import SQEditorUI
import SQInspectorUI

// Track Mask Backward / Forward, Magic track controls and the click correction on the shared UI: the AppKit
// `EditorPanels+MaskTool.swift` / `+MaskTrack.swift` logic, driven by `EffectControlsModel.onTrackMask` / `onTrackMagic`.
extension MacMagicMasks {
    /// The subject model's load is stopped once nothing uses it: the tool left and no run live (a live run keeps it).
    func stopUnusedSubjectModelLoad() {
        guard !MaskTrackActivity.shared.isRunning else { return }
        SubjectMaskEngine.shared.cancelPrewarm()
    }

    /// After a project change: runs whose mask or pick is gone are stopped, tracked frames of a returned mask are saved.
    func projectChanged() {
        stopTrackOfRemovedMask()
        stopTrackOfChangedPick()
        saveFramesOfReturnedMasks()
    }

    func trackMask(_ id: ClipMask.ID, forward: Bool) {
        if model.clip?.mask(id)?.source == .magic { trackMagicMask(id, .run(forward: forward)); return }
        if MaskTrackActivity.shared.stop(reason: "track button clicked again", keeps: true) { return }
        guard let clip = model.clip, clip.sequence == nil, !clip.isGenerator, !clip.isStill, clip.holdFrame == nil,
              let media = session.project.media(clip.media) else {
            out("Mask tracking needs a video clip from a file.")
            return
        }
        guard model.playheadInClip else { out("Put the playhead on the clip to track from there."); return }
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
                let n = try await model.trackMask(id, forward: forward, tracker: tracker, clipByID: lookup,
                                                        mayWrite: { MaskTrackActivity.shared.mayWrite(token) }) { p in
                    Task { @MainActor [weak self] in self?.showMaskTrackProgress(p, what: what, token: token) }
                }
                // A run that lost its slot meanwhile wrote nothing and says nothing: the newer run owns the status line.
                guard MaskTrackActivity.shared.isCurrent(token) else { return }
                out(n > 1 ? SQL10n.format("Tracked the mask over %@ frames.", String(n)) : "The mask could not be tracked from here.")
            } catch let stop as MaskTrackStopped {
                guard MaskTrackActivity.shared.mayWrite(token) else { return }
                out(stop.frames > 0 ? SQL10n.format("Mask tracking stopped; kept %@ frames.", String(stop.frames)) : "Mask tracking stopped.")
            } catch is CancellationError {
                guard MaskTrackActivity.shared.mayWrite(token) else { return }
                out("Mask tracking stopped.")
            } catch {
                guard MaskTrackActivity.shared.isCurrent(token) else { return }
                out("Mask tracking failed: the file could not be read.")
            }
        }
        MaskTrackActivity.shared.attach(task, to: token)
    }


    func magicCorrect(_ id: ClipMask.ID, at p: Vec2, subtract: Bool) {
        let store = MagicMatteStore.shared
        guard let oldKey = model.magicCacheKey(id), let anchor = model.clip?.mask(id)?.magic?.anchorTime,
              let pts = tool.session.shownPTS, let before = store.matte(key: oldKey, pts: pts) else {
            out(MaskTrackActivity.shared.run.map { $0.mask == id && $0.automatic } == true
                ? "The mask is still being followed to this frame: click again in a moment."
                : "Track the Magic mask to this frame first, then click here to correct it.")
            return
        }
        // The pick's own track goes on until the correction really changes the mask (a click that picks nothing leaves
        // it running); any other track is not pushed out.
        let ownTrackRuns = { MaskTrackActivity.shared.run.map { $0.mask == id && $0.automatic } ?? false }
        guard ownTrackRuns() || !MaskTrackActivity.shared.isRunning else {
            out("Stop the running track first, then correct the mask.")
            return
        }
        // The point is stored at the clip's source time of the playhead's frame (rational). The project changes only once
        // the corrected matte is stored: a click that leaves nothing changes nothing.
        guard let edit = model.magicClickEdit(at: p, subtract: subtract, newMask: false), edit.mask == id,
              let key = edit.key else { return }
        let points = edit.points
        let oldPart = model.magicPartKey(id)
        // Where the face was on the person before the click: the track after it starts from there.
        let seed = oldPart.flatMap { store.matte(key: $0, pts: pts) }.map { (person: before, narrowed: $0) }
        // The corrected matte is made off the main thread; the rest follows when it arrives, unless the frame, the
        // mask or its pick changed meanwhile or a track started.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await tool.session.pick(points: points, key: key, start: before)
            switch result {
            case .stored: break
            case .nothing:
                out("Nothing would be left of the mask on this frame: the mask stays as it is.")
                return
            case .refused:
                out("The frame changed before the correction was ready: click again.")
                return
            case .gaveUp(let seconds):
                out(SQL10n.format("Magic got no answer for this correction within %@ seconds and gave up: click to try again.", String(Int(seconds.rounded(.up)))))
                return
            }
            guard tool.session.shownPTS == pts, model.clip?.mask(id) != nil, model.magicCacheKey(id) == oldKey,
                  ownTrackRuns() || !MaskTrackActivity.shared.isRunning else {
                // Never leaves a matte behind for a pick the project does not have.
                if key != oldKey { MatteRemovalJournal.shared.remove(key, from: store) }
                out("The mask changed before the correction was ready: click again.")
                return
            }
            // Now the pick's own track gives way (its frames are saved under the old pick's key and copied from there);
            // the correction then follows on to the clip's edges itself.
            let toEdges = ownTrackRuns() && MaskTrackActivity.shared.stopAutomatic(reason: "the mask is corrected")
            magicCorrected(id, edit: edit, key: key, oldKey: oldKey, oldPart: oldPart, pts: pts, anchor: anchor, seed: seed,
                           subtract: subtract, toEdges: toEdges)
        }
    }


    func stopTrackOfChangedPick() {
        guard MaskTrackActivity.shared.isRunning else { return }
        let project = session.project
        let key = MaskTrackActivity.shared.runKey
        let automatic = MaskTrackActivity.shared.run?.automatic == true
        if MaskTrackActivity.shared.stopIfKeyChanged(owner: session, current: { MagicPickWatch.key($1, clip: $0, in: project) }) != nil,
           let key {
            // Cut off by the project, not by the user: the pick's own track goes on when that pick comes back.
            pickWatch.cutOff(key, automatic: automatic)
        }
    }

    func saveFramesOfReturnedMasks() {
        let store = MagicMatteStore.shared
        guard !MaskTrackActivity.shared.isRunning, !store.unsavedKeys.isEmpty else { return }
        store.saveUnsaved(among: session.project.magicMatteCacheKeys)
    }

    /// The second half of `magicCorrect`, once the corrected matte of the clicked frame is stored under `key`.
    func magicCorrected(_ id: ClipMask.ID, edit: EffectControlsModel.MagicClickEdit, key: String, oldKey: String,
                                oldPart: String?, pts: Double, anchor: Time,
                                seed: (person: SubjectMatte, narrowed: SubjectMatte)?, subtract: Bool, toEdges: Bool) {
        let store = MagicMatteStore.shared
        let points = edit.points
        model.applyMagicClick(edit)
        onTracked()
        let anchorSeconds = Double(anchor.value) / Double(max(anchor.timescale, 1))
        let forward = pts > anchorSeconds
        store.copyFrames(from: oldKey, to: key) { forward ? $0 < pts - 1e-6 : $0 > pts + 1e-6 }
        // Queued: this is the main thread and the file is the whole matte list.
        store.saveLater(key: key)
        let part = model.magicPartKey(id)
        if let oldPart, let part {
            store.copyFrames(from: oldPart, to: part) { forward ? $0 < pts - 1e-6 : $0 > pts + 1e-6 }
            if let person = store.matte(key: key, pts: pts) { store.put(person, key: part, pts: pts) }
            store.saveLater(key: part)
        }
        
        session.engine.redraw()
        
        
        // A correction changes this frame only; following it on is the user's call (Track buttons).
        if part != nil {
            out("Corrected the person on this frame; narrowing the cover again…")
            runMagicTrack(id, key: key, points: points, legs: [MagicTrackLeg(from: pts, to: pts, forward: forward)], seed: seed)
        } else {
            out(subtract ? "Removed from the mask on this frame." : "Added to the mask on this frame.")
        }
    }

    /// The Magic mask's track controls (Effect Controls): one frame back / forward, or on to the clip's start / end (`command`),
    /// or Stop (nil). Nothing tracks unless the user asks: a pick only stores its matte on its own frame. Progress and state
    /// are `MaskTrackActivity.shared.magic`.
    func trackMagicMask(_ id: ClipMask.ID, _ command: MagicTrackControl.Command?) {
        let activity = MaskTrackActivity.shared
        guard let command else {
            if activity.magic.stop() { _ = activity.stop(reason: "Stop pressed", keeps: true) }
            return
        }
        guard !activity.magic.isTracking else { return }
        guard let clip = model.clip, clip.sequence == nil, !clip.isGenerator, !clip.isStill, clip.holdFrame == nil,
              let media = session.project.media(clip.media) else { out("Magic tracking needs a video clip from a file."); return }
        let forward = switch command { case .step(let f), .run(let f): f }
        guard let key = model.magicCacheKey(id), let points = clip.mask(id)?.magic?.points,
              let range = model.magicTrackRange(id, forward: forward) else {
            out("Pick an object with the Mask tool (Magic) first, with the playhead on the clip.")
            return
        }
        let fd = media.info?.video.map { Double($0.nominalFrameDuration.value) / Double(max($0.nominalFrameDuration.timescale, 1)) } ?? 1.0 / 30
        guard let leg = activity.magic.begin(command, playhead: range.from, edge: range.to, frame: fd) else {
            out(forward ? "The playhead is on the last frame: nothing to track forward." : "The playhead is on the first frame: nothing to track backward.")
            return
        }
        session.stopPlayback()
        var isStep = false
        if case .step = command { isStep = true }
        runMagicTrack(id, key: key, points: points, legs: [MagicTrackLeg(from: leg.from, to: leg.to, forward: leg.forward)], stepsPlayhead: isStep)
    }

    /// One direction of a Magic track, in source seconds.
    struct MagicTrackLeg { var from: Double; var to: Double; var forward: Bool }

    /// Runs Magic Track for mask `id` (pick `key` / `points`) between source seconds `from` and `to` in the shared track slot.
    /// A Face / Skin mask made by Anonymize: the person is followed under `key` and each frame narrowed again under the
    /// mask's part key, starting from the face place stored on the first frame (`seed`, else read from the store); frames
    /// the narrowing was unsure about are counted in the status line.
    /// `legs` run one after the other in the same slot (the pick's own track: forward, then backward); `seed` belongs
    /// to the first one. `automatic`: started by a pick or its correction, not by a track button. `clip`: the clip
    /// the mask is on, when it is not the one Effect Controls shows (a pick that came back).
    func runMagicTrack(_ id: ClipMask.ID, key: String, points: [MagicPoint], legs: [MagicTrackLeg], automatic: Bool = false,
                               seed: (person: SubjectMatte, narrowed: SubjectMatte)? = nil, clip given: Clip? = nil, stepsPlayhead: Bool = false) {
        guard let clip = given ?? model.clip, let media = session.project.media(clip.media), let first = legs.first else { return }
        let selection = clip.mask(id)?.magic
        let partKey = selection?.partKey(media: clip.media)
        // A stop that leaves the mask its pick saves what was tracked (the run saves again at its end): queued, the
        // stop is on the main thread and the file is the whole matte list.
        let token = MaskTrackActivity.shared.start(mask: id, forward: first.forward, owner: session, automatic: automatic, key: key,
                                                   clip: clip.id) {
            MagicMatteStore.shared.saveLater(key: key)
            if let partKey { MagicMatteStore.shared.saveLater(key: partKey) }
        }
        // Any run for this pick ends the note that its track was cut off: a Stop of this run is the user's. A hold
        // after the user's Stop ends only here, with a subject-mask run for that mask (a path track never does).
        pickWatch.started(key, mask: id, clip: clip.id)
        trackGoesOn("Tracking Magic mask \(first.forward ? "forward" : "backward")…", token: token)
        var made = MagicMaskTracker(url: URL(fileURLWithPath: media.path),
                                    pixelAspect: media.info?.video?.displayPixelAspect ?? .square,
                                    deinterlace: media.info?.video?.deinterlaceFieldOrder)
        // Program monitor menu > Subject Mask Edges (an app setting, not the project's).
        made.decide(.stored())
        let tracker = made
        let keep = MaskTrackActivity.shared.keepsFrames(token)
        let task = Task { @MainActor [weak self] in
            // The slot is free again: a pick that came back while this run had it is followed now.
            // A run that ends without a word (stopped by the tool switch, a removed mask, a changed pick) takes its
            // "Preparing…" / "Tracking…" line with it. The model's load is the tool's: with the tool left and no
            // run on it, it stops now that this run no longer waits for it.
            defer {
                self?.endTrackStatus(token)
                MaskTrackActivity.shared.finish(token)
                MaskTrackActivity.shared.magic.finish()
                if let self, !magicOn { stopUnusedSubjectModelLoad() }
            }
            guard let self else { return }
            do {
                var frames = 0, lostFrames = 0
                var unsure = 0
                // A cover mask keeps its enlarged estimate on frames without the subject; any other mask is empty there.
                let covers = partKey != nil || selection?.mustCover == true
                for (n, leg) in legs.enumerated() {
                    // Turning around: only while this run still has the slot.
                    if n > 0 {
                        guard MaskTrackActivity.shared.turn(forward: leg.forward, token: token) else { return }
                        session.engine.redraw()
                        
                    }
                    let what = leg.forward ? "forward" : "backward"
                    // One narrowing per direction: each starts from the face place stored on its first frame.
                    var refiner: AnonymizeFrameRefiner?
                    if let part = selection?.part, let partKey {
                        let store = MagicMatteStore.shared
                        let stored = store.matte(key: key, pts: leg.from).flatMap { p in
                            store.matte(key: partKey, pts: leg.from).map { (person: p, narrowed: $0) }
                        }
                        refiner = AnonymizeFrameRefiner(part: part, seed: (n == 0 ? seed : nil) ?? stored)
                    }
                    var refine: (@Sendable (CVPixelBuffer, Double, SubjectMatte) throws -> SubjectMatte)?
                    if let f = refiner { refine = { pb, pts, m in try f.apply(pb, pts, m) } }
                    let one = try await tracker.track(key: key, points: points, from: leg.from, to: leg.to, store: .shared,
                                                      refinedKey: partKey, refine: refine, marksLost: !covers, keep: keep,
                                                      preparing: { waits in
                        Task { @MainActor [weak self] in self?.showMagicTrackPreparing(waits, what: what, token: token) }
                    }) { p in
                        Task { @MainActor [weak self] in self?.showMagicTrackProgress(p, what: what, token: token) }
                    }
                    frames += one.frames
                    lostFrames += one.lostTimes.count
                    unsure += refiner?.flags.count ?? 0
                }
                // A run that lost its slot while its last frame came back (its mask was removed, another run started)
                // touches nothing: the status line and the monitor belong to whoever has the slot now.
                guard MaskTrackActivity.shared.isCurrent(token) else { return }
                session.engine.redraw()
                
                
                
                // A one-frame track moves on with the playhead, so the next step starts from the frame just done.
                if stepsPlayhead, legs.first?.forward != nil, frames > 0 { session.stepFrames(legs[0].forward ? 1 : -1) }
                out(MagicTrackSummary.message(frames: frames, lost: lostFrames, unsure: unsure, covers: covers, part: selection?.part))
            } catch is CancellationError {
                // Only the user's Stop says so; a run stopped for another reason is silent (its frames are saved unless
                // its mask is gone).
                guard MaskTrackActivity.shared.mayWrite(token) else { return }
                out("Magic tracking stopped (frames done so far are kept).")
                session.engine.redraw()
                
                
                
            } catch {
                guard MaskTrackActivity.shared.isCurrent(token) else { return }
                out("Magic tracking failed: the file could not be read.")
            }
        }
        MaskTrackActivity.shared.attach(task, to: token)
    }

    /// The run waits for the subject model to load (`waits`), or the wait is over and it tracks. Without the model
    /// nothing is said: tracking runs on the system's segmentation. (`trackGoesOn`, `endTrackStatus`: next to the
    /// path track in EditorPanels+MaskTrack.swift.)
    func showMagicTrackPreparing(_ waits: Bool, what: String, token: Int) {
        guard MaskTrackActivity.shared.isCurrent(token) else { return }
        trackGoesOn(waits ? TrackStatusLine.preparing : "Tracking Magic mask \(what)…", token: token)
    }

    func showMagicTrackProgress(_ p: Double, what: String, token: Int) {
        let pct = Int((p * 100).rounded(.down))
        guard MaskTrackActivity.shared.progress(pct, token: token) else { return }
        MaskTrackActivity.shared.magic.progress(p)
        trackGoesOn("Tracking Magic mask \(what)… \(pct) % (press Stop to end it)", token: token)
    }

    func stopTrackOfRemovedMask() {
        guard MaskTrackActivity.shared.isRunning else { return }
        let project = session.project
        let key = MaskTrackActivity.shared.runKey
        let automatic = MaskTrackActivity.shared.run?.automatic == true
        if MaskTrackActivity.shared.stopIfMaskGone(owner: session, exists: { MagicPickWatch.mask($1, clip: $0, in: project) != nil }),
           let key {
            pickWatch.cutOff(key, automatic: automatic)
        }
    }

    func showMaskTrackProgress(_ p: Double, what: String, token: Int) {
        let pct = Int((p * 100).rounded(.down))
        guard MaskTrackActivity.shared.progress(pct, token: token) else { return }
        trackGoesOn("Tracking mask \(what)… \(pct) % (click the track button again to stop)", token: token)
    }

    /// A line that says run `token` (path or Magic) goes on: noted, so the run's silent end clears it (`endTrackStatus`).
    func trackGoesOn(_ line: String, token: Int) {
        out(line)
        trackLine.goesOn(token)
    }

    /// Run `token` ended: its going-on line, when nothing was written since, is cleared.
    func endTrackStatus(_ token: Int) {
        onTracked()
        if trackLine.ended(token) { out("") }
    }
}
