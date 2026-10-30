import Foundation
import SQCore

/// Premiere-style timeline operations on the selection: clipboard, link, nudge, edge trims, gaps, markers.
extension EditorSession {
    // MARK: Clipboard

    /// Cmd+C. False when no clip is selected. Fast Cut: copied main-track clips take their attached clips along.
    @discardableResult
    public func copySelection() -> Bool {
        guard let t = activeTimeline, let cb = t.magneticClipboard(copying: selection) else { return false }
        clipboard = cb
        builtInClipboard = nil
        effectClipboard = nil                 // the latest copy wins: Cmd-V pastes clips again
        return true
    }

    /// True when an effect was copied (in Effect Controls) and a selected clip can take it.
    public var canPasteEffectClipboard: Bool {
        guard let e = effectClipboard, let t = activeTimeline else { return false }
        let ids = effectPasteTargets(e)
        return t.tracks.lazy.flatMap(\.clips).contains { ids.contains($0.id) && $0.canAcceptPastedEffect(e) }
    }

    /// Clips a pasted effect goes to: the selection; an audio effect goes to the selected audio clips and to the audio
    /// linked to a selected video clip (like dropping it from the Effects panel).
    private func effectPasteTargets(_ e: ClipEffect) -> Set<Clip.ID> {
        e.isAudio ? audioEffectTargets(for: selection) : selection
    }

    /// Cmd-V with an effect copied: adds a copy behind the effects of every selected clip that can take it (one undo step),
    /// whether or not Effect Controls is open.
    @discardableResult
    public func pasteEffectClipboard() -> Bool {
        guard canPasteEffectClipboard, let e = effectClipboard else { return false }
        let ids = effectPasteTargets(e)
        return attempt("Paste Effect") { t in
            var n = 0
            for id in ids {
                guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }), c.canAcceptPastedEffect(e) else { continue }
                if EffectCatalog.isGeneratorOwned(e.kind) {
                    var copy = e; copy.id = UUID()
                    if let i = c.effects.firstIndex(where: { $0.kind == e.kind }) { c.effects[i] = copy } else { c.effects.insert(copy, at: 0) }
                } else if !c.insertPastedEffect(e) { continue }
                try t.replaceClip(c)
                n += 1
            }
            if n == 0 { throw EditError.emptyClip }
        }
    }

    /// Cmd+X: copy, then lift (Premiere's Cut leaves a gap; Cmd+Shift+X is not bound).
    public func cutSelection() {
        guard copySelection() else { return }
        deleteSelection(ripple: false, undoName: "Cut")
    }

    /// Cmd+V (overwrite at the playhead) or Cmd+Shift+V (insert), onto the tracks the clips were copied from (Premiere
    /// 22.5+); `toTargets` is Paste to Targeted Track (lowest targeted track per kind). The pasted clips become the
    /// selection and the playhead moves to their end, so repeated pastes lay copies end to end (Premiere).
    /// `attached` (Fast Cut, Opt+V): everything lands off V1 at the playhead, attached, nothing rippling.
    public func pasteClipboard(insert: Bool = false, toTargets: Bool = false, attached: Bool = false) {
        guard let cb = clipboard, !cb.isEmpty, let tl = activeTimeline else { return }
        let at = playhead
        let lanes = toTargets ? tl.targetLanes(for: cb) : nil
        var made: [Clip.ID] = []
        var end: Time?
        let fast = tl.isFastCut
        let done = attempt(attached ? "Paste Attached" : insert ? "Paste Insert" : "Paste") {
            // Fast Cut: main-track copies insert on V1 (no hole, attached copies come along); the rest attaches.
            made = fast ? try $0.magneticPaste(cb, at: at, attached: attached)
                : try $0.paste(cb.strippingAttachments(), at: at, lanes: lanes, insert: insert)   // Normal: no attach links
            end = $0.end(of: made)
        }
        guard done else { return }
        if let end { seekSequence(to: end) }
        select(clips: Set(made))
    }

    // MARK: Link

    /// Clip > Link menu state: enabled with two or more clips or any linked clip selected; shows "Unlink" for one linked group.
    public var linkMenuState: (enabled: Bool, unlink: Bool) {
        guard let t = activeTimeline else { return (false, false) }
        let clips = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
        let links = Set(clips.map(\.link))
        return (clips.count >= 2 || clips.contains { $0.link != nil }, links.count == 1 && links.first! != nil)
    }

    /// Cmd+L: unlinks when the selection is one linked group, otherwise links the selected clips.
    public func toggleLinkSelection() {
        guard let t = activeTimeline else { return }
        let clips = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
        guard clips.count >= 2 || clips.contains(where: { $0.link != nil }) else { return }
        let ids = selection
        let links = Set(clips.map(\.link))
        if links.count == 1, links.first! != nil { attempt("Unlink") { try $0.unlink(ids) } }
        else if clips.count >= 2 { attempt("Link") { try $0.link(ids) } }
        else { attempt("Unlink") { try $0.unlink(ids) } }
    }

    /// Unlink (Final Cut's Detach Audio): the selected clips and their partners become independent. False when nothing is linked.
    @discardableResult
    public func unlinkSelection() -> Bool {
        guard let t = activeTimeline else { return false }
        let ids = selection
        guard t.tracks.flatMap(\.clips).contains(where: { ids.contains($0.id) && $0.link != nil }) else { return false }
        attempt("Unlink") { try $0.unlink(ids) }
        return true
    }

    /// Solo of the audio tracks of the selected clips (and their linked partners). nil: no audio clip selected.
    @discardableResult
    public func soloSelectedTracks() -> Bool? {
        guard !selection.isEmpty, var t = activeTimeline, let on = t.toggleSolo(forClips: selection) else { return nil }
        attempt(on ? "Solo" : "Unsolo") { _ = $0.toggleSolo(forClips: selection) }
        return on
    }

    /// Mute of the audio tracks of the selected clips (and their linked partners), toggled like Solo. nil: no audio track involved.
    @discardableResult
    public func muteSelectedTracks() -> Bool? {
        guard !selection.isEmpty, var t = activeTimeline, let on = t.toggleMute(forClips: selection) else { return nil }
        attempt(on ? "Mute" : "Unmute") { _ = $0.toggleMute(forClips: selection) }
        return on
    }

    /// Detach Audio: the audio clips linked to the selected video clips become independent clips where they are, and the
    /// selection moves to them (so they can be moved, trimmed or deleted at once). False when nothing was detachable.
    @discardableResult
    public func detachAudioSelection() -> Bool {
        guard var t = activeTimeline, let ids = try? t.detachAudio(of: selection), !ids.isEmpty else { return false }
        attempt("Detach Audio") { _ = try $0.detachAudio(of: selection) }
        select(clips: Set(ids))
        return true
    }

    /// Next / Previous Keyframe: the selected clips' keys, else the clips under the playhead. False when none lies that way.
    @discardableResult
    public func goToKeyframe(forward: Bool) -> Bool {
        guard let t = activeTimeline else { return false }
        var ids = selection
        if ids.isEmpty {
            let p = playhead
            ids = Set(t.tracks.flatMap(\.clips).filter { $0.timeline.contains(p) }.map(\.id))
        }
        guard let time = forward ? t.nextKeyframe(after: playhead, clips: ids) : t.previousKeyframe(before: playhead, clips: ids)
        else { return false }
        seekSequence(to: time)
        return true
    }

    /// Trim to In/Out: the selected clips are cut back to the In-Out range (without In/Out nothing happens). Returns the count.
    @discardableResult
    public func trimSelectionToRange() -> Int {
        guard !selection.isEmpty, let t = activeTimeline, let r = t.inOut, !r.isEmpty else { return 0 }
        let ids = selection
        var n = 0
        attempt("Trim to In/Out") { n = try $0.trimToRange(ids, range: r) }
        return n
    }

    // MARK: Nudge, edge trims, extend, gaps

    /// Cmd+Left / Cmd+Right (Shift: 10 frames, as in Final Cut): moves the selected clips by whole frames, or the selected
    /// opacity / volume line keys when keys are selected (`selectLineKeys`).
    public func nudgeSelection(frames n: Int) {
        if nudgeLineKeys(frames: n) { return }      // selected line keys move instead of the clips
        guard !selection.isEmpty, let t = activeTimeline else { return }
        let ids = selection, d = t.frameDuration * Int64(n)
        // Fast Cut: main-track clips slide between their neighbors with their attached clips; attached clips move.
        if t.isFastCut { attempt("Nudge Clips") { try $0.magneticNudge(ids, by: d) }; return }
        attempt("Nudge Clips") { try $0.editing(only: ids) { _ = try $0.nudge(ids, by: d) } }
    }

    /// Opt+Left / Opt+Right with clips selected and no edit: slips the selected clips by `n` frames (keyframes follow the media).
    public func slipSelection(frames n: Int, keyframes: SlipKeyframes = .followContent) {
        guard !selection.isEmpty, let t = activeTimeline else { return }
        let ids = selection, d = t.frameDuration * Int64(n)
        attempt("Slip") { tl in
            var seenLinks = Set<UUID>()      // a linked pair slips together: once per link, not once per selected member
            for c in tl.tracks.flatMap(\.clips) where ids.contains(c.id) {
                if let l = c.link, !seenLinks.insert(l).inserted { continue }
                _ = try tl.magneticSlip(c.id, by: d, keyframes: keyframes)      // Fast Cut: attached clips stay
            }
        }
    }

    /// Opt+Left / Opt+Right with an edit selected: moves the selected edge(s) by `n` frames.
    public func trimEdges(_ sel: EdgeSelection, frames n: Int) {
        guard let t = activeTimeline else { return }
        let edits = TimelineEdit.fastCut(TimelineEdit.scoped(EdgeEdits.trim(sel, by: t.frameDuration * Int64(n), in: t), to: sel.scope, in: t),
                                         in: t, keepAttached: keepAttachedHeld)
        run(edits, EdgeEdits.isRoll(sel, in: t) ? "Move Edit" : (sel.ripple ? "Ripple Trim" : "Trim Clip"), sel: sel)
    }

    /// E: moves the selected edit to the playhead.
    public func extendEdit(_ sel: EdgeSelection) {
        guard let t = activeTimeline else { return }
        let edits = TimelineEdit.fastCut(TimelineEdit.scoped(EdgeEdits.extend(sel, to: playhead, in: t), to: sel.scope, in: t),
                                         in: t, keepAttached: keepAttachedHeld)
        run(edits, "Extend Edit", sel: sel)
    }

    private func run(_ edits: [TimelineEdit], _ name: String, sel: EdgeSelection) {
        guard !edits.isEmpty else { return }
        attemptRipple(name) { t in for e in edits { try e.apply(to: &t) } }
    }

    /// Delete on a selected gap: ripple-deletes it. Fast Cut: a gap on V1 is a spacer (`deleteSpacer`, attached clips in
    /// it go unless ` is held); a gap between attached clips closes on its track only.
    public func closeGap(_ gap: GapSelection) {
        guard let t = activeTimeline else { return }
        let edits = TimelineEdit.fastCut([.closeGap(gap.track, at: gap.range.start)], in: t, keepAttached: keepAttachedHeld)
        attemptRipple(t.isFastCut && gap.track == t.mainTrackID ? "Delete Spacer" : "Ripple Delete") { t in
            for e in edits { try e.apply(to: &t) }
        }
    }

    // MARK: Markers

    /// M: adds a marker at the playhead. When one already sits on that frame nothing is added and its ID comes back
    /// so the host can open the marker dialog (Premiere: M twice).
    @discardableResult
    public func markAtPlayhead() -> (id: Marker.ID, openEdit: Bool)? {
        guard let t = activeTimeline else { return nil }
        var probe = t
        let r = probe.markAtPlayhead(playhead)
        if r.openEdit { return r }
        var made: Marker.ID?
        attempt("Add Marker") { made = $0.markAtPlayhead(self.playhead).id }
        return made.map { ($0, false) }
    }

    /// Marker dialog OK: name, color, comment.
    public func editMarker(_ id: Marker.ID, name: String, color: MarkerColor, comment: String) {
        attempt("Edit Marker") { t in t.updateMarker(id) { $0.name = name; $0.color = color; $0.comment = comment } }
    }

    /// Marker dialog OK with a duration: name, color, comment and range length in one undo step.
    public func editMarker(_ id: Marker.ID, name: String, color: MarkerColor, comment: String, duration: Time) {
        attempt("Edit Marker") { t in
            t.updateMarker(id) { $0.name = name; $0.color = color; $0.comment = comment }
            if !t.setMarkerDuration(id, to: duration) { throw EditError.clipNotFound }
        }
    }

    /// Drag of a range marker's end: one undo step.
    public func setMarkerDuration(_ id: Marker.ID, to duration: Time) {
        attempt("Set Marker Duration") { t in
            if !t.setMarkerDuration(id, to: duration) { throw EditError.clipNotFound }
        }
    }

    public func deleteMarker(_ id: Marker.ID) { attempt("Delete Marker") { $0.removeMarker(id) } }

    // MARK: Clip markers (flags on the clip itself; source time, so they follow trims and splits)

    /// Context menu Add Clip Marker: a marker on `clipID` at sequence time `time`.
    @discardableResult
    public func addClipMarker(to clipID: Clip.ID, at time: Time) -> Marker.ID? {
        var made: Marker.ID?
        attempt("Add Clip Marker") { t in
            made = t.addClipMarker(to: clipID, at: time)
            if made == nil { throw EditError.clipNotFound }
        }
        return made
    }

    /// Drag of a clip marker flag (one step per drag).
    public func moveClipMarker(_ id: Marker.ID, on clipID: Clip.ID, to time: Time) {
        attempt("Move Clip Marker") { t in
            if !t.moveClipMarker(id, on: clipID, to: time) { throw EditError.clipNotFound }
        }
    }

    public func editClipMarker(_ id: Marker.ID, on clipID: Clip.ID, name: String, color: MarkerColor, comment: String) {
        attempt("Edit Clip Marker") { t in
            if !t.updateClipMarker(id, on: clipID, { $0.name = name; $0.color = color; $0.comment = comment }) {
                throw EditError.clipNotFound
            }
        }
    }

    public func deleteClipMarker(_ id: Marker.ID, on clipID: Clip.ID) {
        attempt("Delete Clip Marker") { t in
            if !t.removeClipMarker(id, on: clipID) { throw EditError.clipNotFound }
        }
    }

    // MARK: Tracks

    /// New empty track of `kind` after the last one of that kind (a new top video track, a new bottom audio track).
    public func addTrack(_ kind: TrackKind) {
        attempt(kind == .video ? "Add Video Track" : "Add Audio Track") { t in
            let i = (t.tracks.lastIndex { $0.kind == kind } ?? (kind == .video ? -1 : t.tracks.count - 1)) + 1
            t.tracks.insert(Track(kind: kind), at: i)
        }
    }

    /// Sequence > Remove Empty Tracks (`Timeline.removeEmptyTracks`); the status line says what went.
    public func removeEmptyTracks() {
        guard let t = activeTimeline else { return }
        var probe = t
        let n = probe.removeEmptyTracks().count
        guard n > 0 else { setError("No empty tracks to remove."); return }
        attempt("Remove Empty Tracks") { t in _ = t.removeEmptyTracks() }
    }

    /// Sequence > Delete Track: removes the targeted tracks with their clips as one undo step (`Timeline.deleteTargetedTracks`).
    public func deleteTargetedTracks() {
        attempt("Delete Track") { t in try t.deleteTargetedTracks() }
    }

    /// Snapping and Linked Selection belong to the sequence (saved from v91) and each change is one undo step.
    /// Returns whether it changed anything. `linkedSelection` mirrors the new value for session-made selections.
    @discardableResult
    public func setSnapping(_ on: Bool) -> Bool {
        guard let t = activeTimeline, t.snappingOn != on else { return false }
        return attempt(on ? "Snapping On" : "Snapping Off") { $0.snappingOn = on }
    }

    @discardableResult
    public func setLinkedSelection(_ on: Bool) -> Bool {
        guard let t = activeTimeline, t.linkedSelectionOn != on else { return false }
        let ok = attempt(on ? "Linked Selection On" : "Linked Selection Off") { $0.linkedSelectionOn = on }
        if ok { linkedSelection = on }
        return ok
    }

    /// Deletes a track with its clips (undoable). A locked track is refused. Picture masks reading it are cleared in the
    /// same step (`Timeline.removeTrack`).
    public func deleteTrack(_ id: Track.ID) {
        attempt("Delete Track") { t in try t.removeTrack(id) }
    }

    /// Track header menu Move Up / Move Down: trades places with the next track of its kind (`Timeline.moveTrack`).
    @discardableResult
    public func moveTrack(_ id: Track.ID, up: Bool) -> Bool {
        guard let t = activeTimeline, t.track(id) != nil else { return false }
        guard t.moveTrackNeighbor(of: id, up: up) != nil else {
            setError(t.isFastCut && t.mainTrackID == id ? "The main track of a Fast Cut sequence stays at the bottom."
                     : "The track cannot go further \(up ? "up" : "down").")
            return false
        }
        return attempt(up ? "Move Track Up" : "Move Track Down") { t in t.moveTrack(id, up: up) }
    }

    public func renameTrack(_ id: Track.ID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        attempt("Rename Track") { t in
            if let i = t.tracks.firstIndex(where: { $0.id == id }) { t.tracks[i].name = n }
        }
    }

    // MARK: Rename and label

    /// Context menu Rename: the one selected clip. A blank name is ignored.
    public func renameSelectedClip(to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let id = selection.first, selection.count == 1 else { return }
        attempt("Rename Clip") { t in
            guard var c = t.tracks.lazy.compactMap({ $0.clips.first { $0.id == id } }).first else { return }
            c.name = n
            try t.replaceClip(c)
        }
    }

    /// Context menu Label: color of the selected clips (nil = back to the default of its type).
    public func setLabel(_ label: LabelColor?) {
        let ids = selection
        guard !ids.isEmpty else { return }
        attempt("Change Label") { t in
            for c in t.tracks.flatMap(\.clips) where ids.contains(c.id) && c.label != label {
                var n = c; n.label = label
                try t.replaceClip(n)
            }
        }
    }

    // MARK: Selection and marks

    /// Cmd+A: every clip of the active sequence.
    public func selectAllClips() {
        guard let t = activeTimeline else { return }
        select(clips: Set(t.tracks.flatMap(\.clips).map(\.id)))
    }

    /// Track header menu "Select All Clips on Track": every clip of that track (none on a locked track, as a marquee
    /// skips it). Linked partners on other tracks stay out: this is a track selection.
    public func selectAllClips(on track: Track.ID) {
        guard let t = activeTimeline?.track(track), !t.isLocked else { return }
        select(clips: Set(t.clips.map(\.id)))
    }

    /// D: selects the clips under the playhead on the targeted tracks (all tracks when none is targeted).
    public func selectClipAtPlayhead() {
        guard let t = activeTimeline else { return }
        let targeted = t.tracks.filter(\.isTargeted)
        let pool = targeted.isEmpty ? t.tracks : targeted
        select(clips: expandingLinks(Set(pool.flatMap(\.clips).filter { $0.timeline.contains(playhead) }.map(\.id))))
    }

    /// Shift+Up / Shift+Down: edit points of every track, ignoring targets.
    public func goToEditPointOnAnyTrack(forward: Bool) {
        guard let pts = activeTimeline?.editPoints() else { return }
        if forward, let t = pts.first(where: { $0 > playhead }) { seekSequence(to: t) }
        if !forward, let t = pts.last(where: { $0 < playhead }) { seekSequence(to: t) }
    }

    /// `/`: In/Out around the selected clips.
    public func markSelection() {
        guard let t = activeTimeline else { return }
        let ranges = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }.map(\.timeline)
        guard let lo = ranges.map(\.start).min(), let hi = ranges.map(\.end).max() else { return }
        attempt("Mark Selection") { $0.setMarkedRange(TimeRange(start: lo, end: hi)) }
    }

    /// Mark Overhang: In/Out around the lead or trail where linked clips (a J or L cut) do not line up.
    public func markOverhang() {
        guard let t = activeTimeline, let r = t.markOverhangRange(at: playhead, selection: selection) else { return }
        attempt("Mark Overhang") { $0.setMarkedRange(r) }
    }
    public var canMarkOverhang: Bool { activeTimeline?.markOverhangRange(at: playhead, selection: selection) != nil }

    public func goToNextSplitPoint() { if let t = activeTimeline?.nextSplitPoint(after: playhead) { seekSequence(to: t) } }
    public func goToPreviousSplitPoint() { if let t = activeTimeline?.previousSplitPoint(before: playhead) { seekSequence(to: t) } }

    /// Shift+M / Cmd+Shift+M.
    public func goToNextMarker() { if let m = activeTimeline?.nextMarker(after: playhead) { seekSequence(to: m.time) } }
    public func goToPreviousMarker() { if let m = activeTimeline?.previousMarker(before: playhead) { seekSequence(to: m.time) } }

    // MARK: Premiere parity (2026-10)

    /// Opt+, / Opt+. : slides the selected clips by `n` frames (neighbors give or take the time; linked pairs once).
    public func slideSelection(frames n: Int) {
        guard !selection.isEmpty, let t = activeTimeline else { return }
        let ids = selection, d = t.frameDuration * Int64(n)
        attempt("Slide") { tl in
            var seenLinks = Set<UUID>()
            for c in tl.tracks.flatMap(\.clips) where ids.contains(c.id) {
                if let l = c.link, !seenLinks.insert(l).inserted { continue }
                _ = try tl.magneticSlide(c.id, by: d)       // Fast Cut: a main clip's attached clips slide with it
            }
        }
    }

    /// Cmd+Down / Cmd+Up: the next (previous) clip on the track of the last (first) selected clip becomes the selection.
    /// False when nothing is selected or the track has no further clip.
    @discardableResult
    public func selectAdjacentClip(forward: Bool) -> Bool {
        guard let t = activeTimeline else { return false }
        let picked = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
        guard let from = forward ? picked.max(by: { $0.timeline.end < $1.timeline.end }) : picked.min(by: { $0.start < $1.start }),
              let next = t.neighbourClip(of: from.id, forward: forward) else { return false }
        select(clips: expandingLinks([next]))
        return true
    }

    /// Go to Selected Clip Start / End: moves the playhead to the edge of the selection. False without a selection.
    @discardableResult
    public func goToSelectedClipEdge(end: Bool) -> Bool {
        guard let r = activeTimeline?.extent(of: selection) else { return false }
        seekSequence(to: end ? r.end : r.start)
        return true
    }

    /// Opt+M: removes the marker on the playhead frame. False when there is none.
    @discardableResult
    public func clearMarkerAtPlayhead() -> Bool {
        guard let t = activeTimeline, t.markers.contains(where: { $0.time == max(.zero, playhead.snapped(to: t.frameDuration)) }) else { return false }
        let at = playhead
        return attempt("Clear Marker") { $0.clearMarker(at: at) }
    }

    /// Clears every sequence marker. Returns how many were removed.
    @discardableResult
    public func clearAllMarkers() -> Int {
        let n = activeTimeline?.markers.count ?? 0
        guard n > 0 else { return 0 }
        attempt("Clear All Markers") { $0.clearAllMarkers() }
        return n
    }
}
