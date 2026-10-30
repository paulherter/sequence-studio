import Foundation
import SQUIKit
import SQCore

// Fast Cut (docs/research/FCP-MAGNETIC-TIMELINE.md, docs/ARCHITECTURE.md "Fast Cut operations"): the mode switch and the
// Fast Cut-only commands. Every other edit command picks its Fast Cut verb itself (Delete, Q/W, Cmd+K, paste, nudge,
// ranges, source edits...), so a Fast Cut sequence never runs a plain Normal edit. Each command is ONE undo step and
// returns the status line the app shows.

extension EditorSession {
    /// Switches the active sequence between Normal and Fast Cut: ONE undo step that moves no clip (`Project.setEditMode`).
    /// False when the sequence already is in `mode` (no step) or there is no sequence.
    @discardableResult
    public func setTimelineEditMode(_ mode: TimelineEditMode) -> Bool {
        guard let id = activeTimelineID, let t = activeTimeline, t.editMode != mode else { return false }
        do { try perform(mode == .magnetic ? "Switch to Fast Cut" : "Switch to Normal") { try $0.setEditMode(mode, of: id) } } catch {
            setError(Self.message(for: error)); return false
        }
        return true
    }

    /// Enabled state of a Fast Cut command: only in Fast Cut, and only with the right selection.
    public func fastCutCommandEnabled(_ c: EditorCommand) -> Bool {
        guard let t = activeTimeline, t.editMode == .magnetic else { return false }
        let main = t.mainTrackIndex
        let rows = t.tracks.indices.flatMap { i in t.tracks[i].clips.filter { selection.contains($0.id) }.map { _ in i } }
        switch c {
        case .appendToMainTrack, .insertSpacer: return main != nil
        case .liftOffMainTrack: return rows.contains { $0 == main }
        case .putOnMainTrack: return rows.contains { $0 != main }
        case .setAttachPoint: return selection.contains { t.isAttachable($0) }
        case .createStoryline:
            let picks = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && t.isAttachable($0.id) }
            return picks.count >= 2 && Set(picks.map(\.kind)).count == 1
        case .storylineRippleDelete: return selection.contains { t.storyline(containing: $0) != nil }
        case .moveClipLeft, .moveClipRight: return selection.contains { t.mainClip(of: $0) != nil }
        case .deleteSelectionOnly: return main != nil && (!selection.isEmpty || !captionSelection.isEmpty)
        case .pasteAttached: return clipboard.map { !$0.isEmpty } ?? false
        case .attachBacktimed: return main != nil        // the app adds the "has a source" check
        default: return false
        }
    }

    /// Default length of Insert Spacer (FCP's gap default).
    public static let defaultSpacerLength = Time(3, 1)

    /// Append to Main Track (Ctrl+E): `media` (the Source clip, else the media selected in the Project panel) goes to the
    /// end of V1 one item after another, video with its sound linked; audio-only items attach at the playhead. Source
    /// marks are honored. The playhead moves to the end of what was appended.
    @discardableResult
    public func appendToMainTrack(media ids: [MediaRef.ID], streams: SourceStreams = .both) -> String {
        guard let t = activeTimeline else { return "Open a sequence first." }
        let refs = ids.compactMap { project.media($0) }
        guard !refs.isEmpty else { return "Open a clip in the Source view or select media in the Project panel first." }
        let adopts = !t.formatLocked && t.tracks.allSatisfy { $0.clips.isEmpty }
        let marks = project.sourceMarks
        var end: Time?
        let at = playhead
        let done = attempt("Append to Main Track") { tl in
            if adopts, let v = refs[0].info?.video {
                let still = refs[0].info?.isStill == true
                tl.format = SequenceFormat(width: v.displayWidth, height: v.displayHeight,
                                           frameDuration: still ? tl.format.frameDuration : v.nominalFrameDuration,
                                           audioSampleRate: tl.format.audioSampleRate).sanitized(fallback: tl.format)
            }
            for ref in refs {
                let still = ref.info?.isStill == true
                guard let total = still ? Time(5, 1) : (ref.info?.duration ?? ref.duration) else { continue }
                guard let range = still ? TimeRange(start: .zero, duration: total)
                        : Timeline.sourceEditRange(marks: marks[ref.id] ?? SourceMarks(), total: total) else { continue }
                let source = TimeRange(start: range.start, duration: range.duration.snapped(to: tl.frameDuration))
                guard !source.isEmpty else { continue }
                let video = (ref.info?.video != nil || ref.info == nil) && streams.includesVideo
                let audio = ref.info?.audio != nil && streams.includesAudio
                let link: UUID? = video && audio ? UUID() : nil
                var clips: [Clip] = []
                if video {
                    var c = Clip(name: ref.name, media: ref.id, kind: .video, source: source, start: .zero, link: link,
                                 mediaDuration: still ? nil : total, isStill: still)
                    let fit = ref.info?.video.map { tl.format.fitScale(width: $0.displayWidth, height: $0.displayHeight) } ?? 1
                    if abs(fit - 1) > 1e-12 { c.animation.scale = AnimatedProperty(Vec2(fit, fit)) }
                    clips.append(c)
                }
                if audio {
                    clips.append(Clip(name: ref.name, media: ref.id, kind: .audio, source: source, start: .zero, link: link,
                                      mediaDuration: total))
                }
                guard !clips.isEmpty else { continue }
                let made = try tl.appendToMainTrack(clips, playhead: at)
                end = tl.tracks.flatMap(\.clips).filter { made.contains($0.id) }.map(\.timeline.end).max()
            }
            if end == nil { throw EditError.emptyClip }
        }
        guard done else { return lastError ?? "Nothing to append." }
        if let end { seekSequence(to: end) }
        return SQL10n.plural(refs.count, one: "Appended to the main track.", other: "Appended %@ clips to the main track.")
    }

    /// Insert Spacer (Ctrl+W): a hole of `defaultSpacerLength` at the playhead on V1 (at its end when the playhead is past
    /// it); everything later ripples with its attached clips.
    @discardableResult
    public func insertSpacer() -> String {
        guard let t = activeTimeline else { return "Open a sequence first." }
        let at = playhead.snapped(to: t.frameDuration), d = Self.defaultSpacerLength.snapped(to: t.frameDuration)
        return attempt("Insert Spacer") { try $0.insertSpacer(at: at, duration: d) } ? "Spacer inserted." : (lastError ?? "No spacer inserted.")
    }

    /// Replace with Spacer (Shift+Delete in Fast Cut): the selected main-track clips leave a hole; attached clips stay
    /// on their frame. Selected attached clips are removed, selected captions deleted (same step).
    @discardableResult
    public func replaceSelectionWithSpacer() -> String {
        guard !selection.isEmpty || !captionSelection.isEmpty else { return "Select clips first." }
        let ids = selection, captions = captionSelection.sorted { $0.uuidString < $1.uuidString }
        guard attempt(ids.isEmpty ? "Delete" : "Replace with Spacer", { t in
            if !ids.isEmpty { try t.replaceWithSpacer(ids) }
            for c in captions { try t.deleteCaption(c) }
        }) else { return lastError ?? "Nothing replaced." }
        select(clips: [])                         // clears the caption selection too
        return ids.isEmpty ? "Deleted." : "Replaced with a spacer."
    }

    /// Move Clip Left / Right (Ctrl+Cmd+Left/Right): each selected main-track clip (once per linked group) swaps with its
    /// neighbor on V1; linked partners and attached clips travel with their host. One undo step.
    @discardableResult
    public func moveSelectedMainClips(_ step: Int) -> String {
        guard let t = activeTimeline else { return "Open a sequence first." }
        var picks: [Clip.ID] = []
        for id in selection { if let m = t.mainClip(of: id), !picks.contains(m) { picks.append(m) } }
        let order = t.mainTrackIndex.map { i in t.tracks[i].clips.map(\.id) } ?? []
        picks.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        if step > 0 { picks.reverse() }               // the one in front goes first, so a run keeps its order
        guard !picks.isEmpty else { return "Select a main-track clip first." }
        guard attempt(step < 0 ? "Move Clip Left" : "Move Clip Right", { tl in for id in picks { try tl.magneticMove(id, step: step) } }) else {
            return lastError ?? (step < 0 ? "Already first." : "Already last.")
        }
        return step < 0 ? "Moved left." : "Moved right."
    }

    /// Delete Selection Only (Cmd+Opt+Delete): like Delete, but the attached clips of the removed main-track clips stay on
    /// their frame and re-attach to the clip now under them (the same as holding ` while deleting).
    @discardableResult
    public func deleteSelectionOnly() -> String {
        guard !selection.isEmpty || !captionSelection.isEmpty else { return "Select clips first." }
        let was = keepAttachedHeld
        keepAttachedHeld = true
        defer { keepAttachedHeld = was }
        deleteSelection(ripple: true, undoName: "Delete Selection Only")
        return "Deleted, attached clips kept."
    }

    /// Lift off Main Track (Opt+Cmd+Up): the selected V1 clips go to the lowest free track above at the same time and
    /// become attached; a spacer stays on V1, attached clips stay on their frame.
    @discardableResult
    public func liftOffMainTrack() -> String {
        let ids = selection
        return attempt("Lift off Main Track") { try $0.liftOffMainTrack(ids) } ? "Lifted off the main track." : (lastError ?? "Nothing lifted.")
    }

    /// Put on Main Track (Opt+Cmd+Down): the selected attached video clips overwrite V1 at their own position.
    @discardableResult
    public func putOnMainTrack() -> String {
        let ids = selection
        return attempt("Put on Main Track") { try $0.putOnMainTrack(ids) } ? "Put on the main track." : (lastError ?? "Nothing moved.")
    }

    /// Set Attach Point: every selected attached clip (once per linked group) attaches at the playhead (clamped into
    /// the clip) to the main clip under it.
    @discardableResult
    public func setAttachPoint() -> String {
        guard let t = activeTimeline else { return "Open a sequence first." }
        let at = playhead
        var seen = Set<UUID>()
        let picks = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && t.isAttachable($0.id) }
            .filter { seen.insert($0.link ?? $0.id).inserted }.map(\.id)
        guard !picks.isEmpty else { return "Select a clip above or below the main track first." }
        return attempt("Set Attach Point") { tl in for id in picks { try tl.setAttachPoint(id, at: at) } }
            ? "Attach point set." : (lastError ?? "Attach point not set.")
    }

    /// Create Storyline (Ctrl+G): the selected attached clips of one kind join the lane of the earliest one on their own
    /// frames and connect into one storyline.
    @discardableResult
    public func createStoryline() -> String {
        guard let t = activeTimeline else { return "Open a sequence first." }
        let ids = Set(t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && t.isAttachable($0.id) }.map(\.id))
        guard ids.count >= 2 else { return "Select two or more connected clips first." }
        return attempt("Create Storyline") { try $0.createStoryline(ids) } ? "Storyline created." : (lastError ?? "No storyline created.")
    }

    /// Ripple Delete in Storyline (Ctrl+Shift+Delete): the selected storyline clips leave and the later clips of that
    /// storyline close up; the main track and everything outside the run stay. One undo step for all.
    @discardableResult
    public func storylineRippleDelete() -> String {
        guard let t = activeTimeline else { return "Open a sequence first." }
        let picks = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && t.storyline(containing: $0.id) != nil }
            .sorted { $0.start > $1.start }.map(\.id)       // latest first: earlier clips keep their frames while deleting
        guard !picks.isEmpty else { return "Select clips inside a storyline first." }
        guard attempt("Ripple Delete in Storyline", { tl in for id in picks { try tl.storylineRippleDelete(id) } }) else {
            return lastError ?? "Nothing deleted."
        }
        select(clips: [])
        return "Deleted from the storyline."
    }

    /// Cmd+Opt+click on an attached clip: its attach point moves to the clicked time.
    @discardableResult
    public func setAttachPoint(clip id: Clip.ID, at time: Time) -> Bool {
        guard let t = activeTimeline, t.isFastCut, t.isAttachable(id) else { return false }
        let at = time.snapped(to: t.frameDuration)
        return attempt("Set Attach Point") { try $0.setAttachPoint(id, at: at) }
    }
}

extension EditorCommand {
    /// The Fast Cut commands; enabled only in a Fast Cut sequence (`EditorSession.fastCutCommandEnabled`).
    public static let fastCutCommands: [EditorCommand] = [.appendToMainTrack, .insertSpacer, .liftOffMainTrack, .putOnMainTrack, .setAttachPoint, .pasteAttached, .attachBacktimed, .createStoryline, .storylineRippleDelete, .moveClipLeft, .moveClipRight, .deleteSelectionOnly]
}
