import AppKit
import SQAnalysis
import SQCore
import SQEditorUI
import SQInspectorUI

/// The Mask tool on the Program monitor (Magic / Pen / Ellipse / Rectangle; hold the tool slot for the mode): clicks make
/// masks on the selected clip. Magic segments the shown frame once while the playhead is parked (Vision, background):
/// hover highlights the object under the pointer, a click picks it (Add | Remove switch on the monitor, Option flips it,
/// Shift starts a new mask), Track Forward / Backward follows the pick and stores a matte per frame (`MagicMatteStore`).
/// A click on another tracked frame corrects the pick there (cut / grow along color edges) ; tracking on is the user's call.
extension EditorPanels {
    /// What the monitor does for a timeline tool.
    func monitorTool(for tool: TimelineTool) -> ProgramSurfaceView.Tool {
        switch tool {
        case .hand: .hand
        case .type: .type
        case .mask: .mask(timelineView.toolState.maskMode)
        default: .select
        }
    }

    func wireMaskTool() {
        let o = surface.overlay
        o.onMaskToolClick = { [weak self] p, flags in self?.maskToolClick(p, flags: flags) }
        o.onMagicHover = { [weak self] p in self?.magicTool.pointer(p) }
        o.onMaskShapeDrawn = { [weak self] kind, path in self?.maskShapeDrawn(kind, path) }
        o.onMaskSelect = { [weak self] id in
            guard let self, effectModel.clip?.id == overlayTarget?.clip else { return }
            effectModel.selectMask(id)
            updateOverlay()
        }
    }

    /// Ellipse / Rectangle dragged out on the picture: one mask, one undo step.
    private func maskShapeDrawn(_ kind: MaskShapeKind, _ path: MaskPath) {
        session.stopPlayback()
        guard effectModel.playheadInClip else { onStatus?("Put the playhead on the clip to draw a mask there."); return }
        guard effectModel.addDrawnMask(kind, path: path) != nil else { return }
        updateOverlay()
    }

    /// Called from `updateOverlay`: Magic segments the shown frame and shows the active mask's pick on it.
    func updateMagicOverlay() { magicTool.refresh(); previewMagic() }

    func updateMagicPick() { magicTool.refreshPick() }

    private func maskToolClick(_ p: Vec2, flags: NSEvent.ModifierFlags) {
        guard let mode = surface.tool.maskModeValue else { return }
        session.stopPlayback()
        if mode == .magic {
            let subtract = surface.magicMode.effective(option: flags.contains(.option)).subtracts
            let tool = magicTool
            Task { @MainActor in await tool.click(p, subtract: subtract, newMask: flags.contains(.shift)) }
            return
        }
        guard effectModel.playheadInClip else { onStatus?("Put the playhead on the clip to draw a mask there."); return }
        guard effectModel.maskToolClick(mode, at: p, subtract: flags.contains(.option), newMask: flags.contains(.shift)) != nil
        else { return }
        updateOverlay()
    }

    /// A Magic click on a tracked frame other than the pick's: the point is stored on that frame, the frames the
    /// correction does not change are kept (copied to the new pick's mattes), the frame is corrected at once and Track
    /// stays on that frame. A Face / Skin mask made by Anonymize: the click corrects the followed
    /// person; the frame is covered with the whole corrected person at once (more, never less) and narrowed again by the
    /// track that follows, which always runs, also for this one frame.
    func magicCorrect(_ id: ClipMask.ID, at p: Vec2, subtract: Bool) {
        let store = MagicMatteStore.shared
        guard let oldKey = effectModel.magicCacheKey(id), let anchor = effectModel.clip?.mask(id)?.magic?.anchorTime,
              let pts = magicTool.session.shownPTS, let before = store.matte(key: oldKey, pts: pts) else {
            onStatus?(MaskTrackActivity.shared.run.map { $0.mask == id && $0.automatic } == true
                ? "The mask is still being followed to this frame: click again in a moment."
                : "Track the Magic mask to this frame first, then click here to correct it.")
            return
        }
        // The pick's own track goes on until the correction really changes the mask (a click that picks nothing leaves
        // it running); any other track is not pushed out.
        let ownTrackRuns = { MaskTrackActivity.shared.run.map { $0.mask == id && $0.automatic } ?? false }
        guard ownTrackRuns() || !MaskTrackActivity.shared.isRunning else {
            onStatus?("Stop the running track first, then correct the mask.")
            return
        }
        // The point is stored at the clip's source time of the playhead's frame (rational). The project changes only once
        // the corrected matte is stored: a click that leaves nothing changes nothing.
        guard let edit = effectModel.magicClickEdit(at: p, subtract: subtract, newMask: false), edit.mask == id,
              let key = edit.key else { return }
        let points = edit.points
        let oldPart = effectModel.magicPartKey(id)
        // Where the face was on the person before the click: the track after it starts from there.
        let seed = oldPart.flatMap { store.matte(key: $0, pts: pts) }.map { (person: before, narrowed: $0) }
        // The corrected matte is made off the main thread; the rest follows when it arrives, unless the frame, the
        // mask or its pick changed meanwhile or a track started.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await magicTool.session.pick(points: points, key: key, start: before)
            switch result {
            case .stored: break
            case .nothing:
                onStatus?("Nothing would be left of the mask on this frame: the mask stays as it is.")
                return
            case .refused:
                onStatus?("The frame changed before the correction was ready: click again.")
                return
            case .gaveUp(let seconds):
                onStatus?(SQL10n.format("Magic got no answer for this correction within %@ seconds and gave up: click to try again.", String(Int(seconds.rounded(.up)))))
                return
            }
            guard magicTool.session.shownPTS == pts, effectModel.clip?.mask(id) != nil, effectModel.magicCacheKey(id) == oldKey,
                  ownTrackRuns() || !MaskTrackActivity.shared.isRunning else {
                // Never leaves a matte behind for a pick the project does not have.
                if key != oldKey { MatteRemovalJournal.shared.remove(key, from: store) }
                onStatus?("The mask changed before the correction was ready: click again.")
                return
            }
            // Now the pick's own track gives way (its frames are saved under the old pick's key and copied from there);
            // the correction then follows on to the clip's edges itself.
            let toEdges = ownTrackRuns() && MaskTrackActivity.shared.stopAutomatic(reason: "the mask is corrected")
            magicCorrected(id, edit: edit, key: key, oldKey: oldKey, oldPart: oldPart, pts: pts, anchor: anchor, seed: seed,
                           subtract: subtract, toEdges: toEdges)
        }
    }

    /// After a project change: a Magic track whose mask has another pick now (a new click, undo or redo of a point)
    /// is stopped, so it never stores frames for a pick the mask does not have; what it tracked is saved under its
    /// own key. The run's mask is looked up on the run's clip (the halves of a split clip share their mask ids).
    func stopTrackOfChangedPick() {
        guard MaskTrackActivity.shared.isRunning else { return }
        let project = session.project
        let key = MaskTrackActivity.shared.runKey
        let automatic = MaskTrackActivity.shared.run?.automatic == true
        if MaskTrackActivity.shared.stopIfKeyChanged(owner: session, current: { MagicPickWatch.key($1, clip: $0, in: project) }) != nil,
           let key {
            // Cut off by the project, not by the user: the pick's own track goes on when that pick comes back.
            magicPickWatch.cutOff(key, automatic: automatic)
        }
    }

    /// The Magic tool was chosen: the subject model starts loading in the background (nothing happens when it is
    /// loaded, loading, not available, or memory is short).
    func startSubjectModelLoad() { SubjectMaskEngine.shared.prewarm() }

    /// The Magic tool was left, or a run ended with the tool already left: a load of the subject model that nothing
    /// uses is stopped. While a run is live it keeps the model; the engine ignores this while a run still waits for
    /// the load (a run stopped by the tool switch leaves that wait a moment later and calls this at its end).
    func stopUnusedSubjectModelLoad() {
        guard !MaskTrackActivity.shared.isRunning else { return }
        SubjectMaskEngine.shared.cancelPrewarm()
    }

    /// After a project change: tracked frames that are only in memory (their run was stopped without saving because
    /// its mask was removed) are written once the project has that mask again (undo), so it keeps them after a
    /// relaunch. Not while a run is live: it saves its own frames.
    func saveFramesOfReturnedMasks() {
        let store = MagicMatteStore.shared
        guard !MaskTrackActivity.shared.isRunning, !store.unsavedKeys.isEmpty else { return }
        store.saveUnsaved(among: session.project.magicMatteCacheKeys)
    }

    /// The second half of `magicCorrect`, once the corrected matte of the clicked frame is stored under `key`.
    private func magicCorrected(_ id: ClipMask.ID, edit: EffectControlsModel.MagicClickEdit, key: String, oldKey: String,
                                oldPart: String?, pts: Double, anchor: Time,
                                seed: (person: SubjectMatte, narrowed: SubjectMatte)?, subtract: Bool, toEdges: Bool) {
        let store = MagicMatteStore.shared
        let points = edit.points
        effectModel.applyMagicClick(edit)
        let anchorSeconds = Double(anchor.value) / Double(max(anchor.timescale, 1))
        let forward = pts > anchorSeconds
        store.copyFrames(from: oldKey, to: key) { forward ? $0 < pts - 1e-6 : $0 > pts + 1e-6 }
        // Queued: this is the main thread and the file is the whole matte list.
        store.saveLater(key: key)
        let part = effectModel.magicPartKey(id)
        if let oldPart, let part {
            store.copyFrames(from: oldPart, to: part) { forward ? $0 < pts - 1e-6 : $0 > pts + 1e-6 }
            if let person = store.matte(key: key, pts: pts) { store.put(person, key: part, pts: pts) }
            store.saveLater(key: part)
        }
        updateOverlay()
        session.engine.redraw()
        magicHealth.forget()
        updateMagicPick()
        // A correction changes this frame only; following it on is the user's call (Track buttons).
        if part != nil {
            onStatus?("Corrected the person on this frame; narrowing the cover again…")
            runMagicTrack(id, key: key, points: points, legs: [MagicTrackLeg(from: pts, to: pts, forward: forward)], seed: seed)
        } else {
            onStatus?(subtract ? "Removed from the mask on this frame." : "Added to the mask on this frame.")
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
        guard let clip = effectModel.clip, clip.sequence == nil, !clip.isGenerator, !clip.isStill, clip.holdFrame == nil,
              let media = session.project.media(clip.media) else { onStatus?("Magic tracking needs a video clip from a file."); return }
        let forward = switch command { case .step(let f), .run(let f): f }
        guard let key = effectModel.magicCacheKey(id), let points = clip.mask(id)?.magic?.points,
              let range = effectModel.magicTrackRange(id, forward: forward) else {
            onStatus?("Pick an object with the Mask tool (Magic) first, with the playhead on the clip.")
            return
        }
        let fd = media.info?.video.map { Double($0.nominalFrameDuration.value) / Double(max($0.nominalFrameDuration.timescale, 1)) } ?? 1.0 / 30
        guard let leg = activity.magic.begin(command, playhead: range.from, edge: range.to, frame: fd) else {
            onStatus?(forward ? "The playhead is on the last frame: nothing to track forward." : "The playhead is on the first frame: nothing to track backward.")
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
    private func runMagicTrack(_ id: ClipMask.ID, key: String, points: [MagicPoint], legs: [MagicTrackLeg], automatic: Bool = false,
                               seed: (person: SubjectMatte, narrowed: SubjectMatte)? = nil, clip given: Clip? = nil, stepsPlayhead: Bool = false) {
        guard let clip = given ?? effectModel.clip, let media = session.project.media(clip.media), let first = legs.first else { return }
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
        magicPickWatch.started(key, mask: id, clip: clip.id)
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
                if let self, surface.tool.maskModeValue != .magic { stopUnusedSubjectModelLoad() }
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
                        magicHealth.forget()
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
                magicHealth.forget()
                updateMagicPick()
                updateMaskTint()
                // A one-frame track moves on with the playhead, so the next step starts from the frame just done.
                if stepsPlayhead, legs.first?.forward != nil, frames > 0 { session.stepFrames(legs[0].forward ? 1 : -1) }
                let check = unsure == 0 ? "" : " On \(unsure) of them the \(selection?.part == .skin ? "skin" : "face") was not found, so more is covered there: check them."
                // No frame at all: the start frame holds nothing to follow, or what it holds (a faint matte) was
                // not found again on any frame after it.
                if frames == 0 {
                    onStatus?(lostFrames > 0 ? "The object was not found from this frame on: click it here to pick it up again."
                                             : "Nothing to follow here: pick the object on this frame first.")
                }
                else if lostFrames > 0 {
                    onStatus?(covers
                        ? SQL10n.format("Tracked %@ frames; on %@ more the person was not found, so the cover there is an enlarged estimate: check them.", String(frames), String(lostFrames)) + check
                        : SQL10n.format("Tracked %@ frames; on %@ more the object was not found (marked on the strip): click it there to pick it up again.", String(frames), String(lostFrames)))
                }
                else { onStatus?(SQL10n.format("Tracked the Magic mask over %@ frames.", String(frames)) + check) }
            } catch is CancellationError {
                // Only the user's Stop says so; a run stopped for another reason is silent (its frames are saved unless
                // its mask is gone).
                guard MaskTrackActivity.shared.mayWrite(token) else { return }
                onStatus?("Magic tracking stopped (frames done so far are kept).")
                session.engine.redraw()
                magicHealth.forget()
                updateMagicPick()
                updateMaskTint()
            } catch {
                guard MaskTrackActivity.shared.isCurrent(token) else { return }
                onStatus?("Magic tracking failed: the file could not be read.")
            }
        }
        MaskTrackActivity.shared.attach(task, to: token)
    }

    /// The run waits for the subject model to load (`waits`), or the wait is over and it tracks. Without the model
    /// nothing is said: tracking runs on the system's segmentation. (`trackGoesOn`, `endTrackStatus`: next to the
    /// path track in EditorPanels+MaskTrack.swift.)
    private func showMagicTrackPreparing(_ waits: Bool, what: String, token: Int) {
        guard MaskTrackActivity.shared.isCurrent(token) else { return }
        trackGoesOn(waits ? TrackStatusLine.preparing : "Tracking Magic mask \(what)…", token: token)
    }

    private func showMagicTrackProgress(_ p: Double, what: String, token: Int) {
        let pct = Int((p * 100).rounded(.down))
        guard MaskTrackActivity.shared.progress(pct, token: token) else { return }
        MaskTrackActivity.shared.magic.progress(p)
        trackGoesOn("Tracking Magic mask \(what)… \(pct) % (press Stop to end it)", token: token)
    }
}

extension ProgramSurfaceView.Tool {
    /// The Mask tool's mode, nil for the other tools.
    var maskModeValue: MaskToolMode? { if case .mask(let m) = self { m } else { nil } }
}
