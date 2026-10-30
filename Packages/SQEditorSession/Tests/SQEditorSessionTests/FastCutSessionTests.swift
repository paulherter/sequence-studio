import Foundation
import SQCore
import Testing
@testable import SQEditorSession

// Fast Cut session commands (docs/ARCHITECTURE.md "Fast Cut operations"): every command picks its magnetic verb in a
// Fast Cut sequence, is ONE undo step and leaves V1 without holes unless a spacer was asked for.

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(10), duration: s(dur)), start: s(start),
         link: link, mediaDuration: s(100))
}
private func find(_ t: Timeline?, _ id: Clip.ID) -> Clip? { t?.tracks.lazy.compactMap { $0.clips.first { $0.id == id } }.first }
private func span(_ t: Timeline?, _ id: Clip.ID) -> [Int64]? {
    guard let c = find(t, id) else { return nil }
    return [c.start.value / c.start.timescale, c.timeline.end.value / c.timeline.end.timescale]
}
private func row(_ t: Timeline?, _ id: Clip.ID) -> Int? { t?.tracks.firstIndex { $0.clips.contains { $0.id == id } } }
/// V1 as [start, end] pairs in seconds.
private func mainSpans(_ t: Timeline?) -> [[Int64]] { t?.tracks[0].clips.compactMap { span(t, $0.id) } ?? [] }

/// V1: A[0-4] B[4-8] C[8-12] (each linked to its sound on A1). V2: X[9-11], attached to C.
@MainActor
struct FastCutSessionTests {
    let la = UUID(), lb = UUID(), lc = UUID()
    let a: Clip, b: Clip, c: Clip, aa: Clip, ab: Clip, ac: Clip, x: Clip

    init() {
        a = clip(0, 4, link: la); b = clip(4, 4, link: lb); c = clip(8, 4, link: lc)
        aa = clip(0, 4, kind: .audio, link: la); ab = clip(4, 4, kind: .audio, link: lb); ac = clip(8, 4, kind: .audio, link: lc)
        x = clip(9, 2)
    }

    private func session(_ mode: TimelineEditMode = .magnetic) -> EditorSession {
        var t = Timeline(name: "t", frameDuration: Time(1, 24),
                         tracks: [Track(kind: .video, clips: [a, b, c]), Track(kind: .video, clips: [x]),
                                  Track(kind: .audio, clips: [aa, ab, ac]), Track(kind: .audio)])
        t.setEditMode(mode)
        return EditorSession(project: Project(name: "P", timelines: [t]))
    }

    /// Runs `body` and checks it made exactly one undo step that restores the timeline.
    private func oneStep(_ ses: EditorSession, _ body: () -> Void) throws {
        let before = try #require(ses.activeTimeline)
        let depth = ses.history.undoDepth
        body()
        #expect(ses.history.undoDepth == depth + 1)
        ses.undo()
        #expect(ses.activeTimeline == before)
        ses.redo()
    }

    // MARK: Selected unlinked

    @Test func movingOnlyTheSoundOfAMainClipLeavesV1Alone() throws {
        var t = try #require(session().activeTimeline)
        let edits = TimelineEdit.scoped([.move(ab.id, to: s(14), track: nil)], to: [ab.id], in: t)
        let mapped = TimelineEdit.fastCut(edits, in: t)
        for e in mapped { try e.apply(to: &t) }
        #expect(mainSpans(t) == [[0, 4], [4, 8], [8, 12]])
        #expect(span(t, ab.id) == [14, 18])
        #expect(span(t, b.id) == [4, 8] && span(t, x.id) == [9, 11])
    }

    // MARK: Spacers

    @Test func shiftDeleteReplacesWithASpacer() throws {
        let ses = session()
        ses.select(clips: [b.id, ab.id])
        try oneStep(ses) { #expect(ses.replaceSelectionWithSpacer() == "Replaced with a spacer.") }
        let t = ses.activeTimeline
        #expect(span(t, b.id) == nil)
        #expect(span(t, c.id) == [8, 12] && span(t, x.id) == [9, 11])
        #expect(ses.selection.isEmpty)
    }

    @Test func shiftDeleteWithACaptionSelectedDeletesTheCaption() throws {
        let ses = session()
        _ = ses.addCaptionTrack()
        let id = try #require(ses.addCaptionAtPlayhead())
        #expect(ses.captionSelection == [id])
        try oneStep(ses) { #expect(ses.replaceSelectionWithSpacer() == "Deleted.") }
        #expect(ses.captionSelection.isEmpty)
        #expect(ses.activeTimeline?.captionTracks.flatMap(\.items).isEmpty == true)
        #expect(mainSpans(ses.activeTimeline) == [[0, 4], [4, 8], [8, 12]])
    }

    @Test func insertSpacerRipplesV1AndItsAttachedClips() throws {
        let ses = session()
        ses.seek(to: s(4))
        try oneStep(ses) { #expect(ses.insertSpacer() == "Spacer inserted.") }
        let t = ses.activeTimeline
        #expect(span(t, b.id) == [7, 11] && span(t, c.id) == [11, 15])
        #expect(span(t, x.id) == [12, 14])
        #expect(span(t, ab.id) == [7, 11])
    }

    @Test func closeGapAtThePlayheadDeletesTheSpacer() throws {
        let ses = session()
        ses.seek(to: s(4))
        ses.insertSpacer()
        ses.seek(to: s(5))
        try oneStep(ses) { #expect(ses.closeGapAtPlayhead()) }
        #expect(mainSpans(ses.activeTimeline) == [[0, 4], [4, 8], [8, 12]])
        #expect(span(ses.activeTimeline, x.id) == [9, 11])
        ses.seek(to: s(2))
        #expect(!ses.closeGapAtPlayhead())
        #expect(ses.lastError == "No spacer at the playhead.")
    }

    // MARK: Trims and cuts

    @Test func qAndWRippleV1AndCarryTheAttachedClips() throws {
        let ses = session()
        ses.seek(to: s(6))
        try oneStep(ses) { ses.rippleTrimToPlayhead(.tail) }
        let t = ses.activeTimeline
        #expect(span(t, b.id) == [4, 6] && span(t, c.id) == [6, 10])
        #expect(span(t, x.id) == [7, 9])
    }

    @Test func addEditCutsTheMainClipOnlyAndJoinUndoesIt() throws {
        let ses = session()
        ses.seek(to: s(10))
        try oneStep(ses) { ses.addEditAtPlayhead() }
        let t = ses.activeTimeline
        #expect(mainSpans(t) == [[0, 4], [4, 8], [8, 10], [10, 12]])
        #expect(span(t, x.id) == [9, 11])                          // attached clips are not cut
        ses.select(clips: [])
        try oneStep(ses) { #expect(ses.joinCutsInSelection() >= 1) }
        #expect(mainSpans(ses.activeTimeline) == [[0, 4], [4, 8], [8, 12]])
    }

    @Test func nudgeOfAMainClipCarriesItsAttachedClip() throws {
        let ses = session()
        ses.select(clips: [c.id])
        try oneStep(ses) { ses.nudgeSelection(frames: 24) }
        #expect(span(ses.activeTimeline, x.id).map { $0[0] } == span(ses.activeTimeline, c.id).map { $0[0] + 1 })
    }

    // MARK: Clipboard

    @Test func pasteInsertsCopiedMainClipsOnV1() throws {
        let ses = session()
        ses.select(clips: [c.id, ac.id, x.id])
        #expect(ses.copySelection())
        ses.seek(to: .zero)
        try oneStep(ses) { ses.pasteClipboard() }
        let t = ses.activeTimeline
        #expect(span(t, a.id) == [4, 8])                           // V1 rippled: nothing overwritten
        #expect(t?.tracks[0].clips.count == 4)
        #expect(span(t, x.id) == [13, 15])                         // follows C
    }

    @Test func pasteAttachedPutsMainClipsOffV1WithoutRippling() throws {
        let ses = session()
        ses.select(clips: [b.id])
        #expect(ses.copySelection())
        ses.seek(to: s(1))
        try oneStep(ses) { ses.pasteClipboard(attached: true) }
        let t = ses.activeTimeline
        #expect(mainSpans(t) == [[0, 4], [4, 8], [8, 12]])         // V1 untouched
        let made = ses.selection
        #expect(made.count == 2)                                   // B and its linked sound
        let m = try #require(made.first { find(t, $0)?.kind == .video })
        #expect(row(t, m) != 0)
        #expect(span(t, m) == [1, 5])
        #expect(find(t, m)?.attachment != nil)
        #expect(ses.fastCutCommandEnabled(.pasteAttached))
    }

    @Test func pasteAttachedIsOffWithoutAClipboardOrInNormal() {
        let ses = session()
        #expect(!ses.fastCutCommandEnabled(.pasteAttached))        // nothing copied
        ses.select(clips: [b.id]); _ = ses.copySelection()
        #expect(ses.fastCutCommandEnabled(.pasteAttached))
        #expect(!session(.normal).fastCutCommandEnabled(.pasteAttached))
    }

    @Test func duplicateInsertsAfterTheSelection() throws {
        let ses = session()
        ses.select(clips: [b.id, ab.id])
        try oneStep(ses) { ses.duplicateSelection() }
        let t = ses.activeTimeline
        #expect(mainSpans(t) == [[0, 4], [4, 8], [8, 12], [12, 16]])
        #expect(span(t, c.id) == [12, 16] && span(t, x.id) == [13, 15])
    }

    // MARK: Main track

    @Test func liftOffAndPutOnTheMainTrack() throws {
        let ses = session()
        ses.select(clips: [b.id])
        try oneStep(ses) { #expect(ses.liftOffMainTrack() == "Lifted off the main track.") }
        var t = ses.activeTimeline
        #expect(row(t, b.id) != 0 && span(t, b.id) == [4, 8])
        #expect(span(t, c.id) == [8, 12])                          // a spacer stays on V1
        #expect(find(t, b.id)?.attachment != nil)
        ses.select(clips: [b.id])
        try oneStep(ses) { #expect(ses.putOnMainTrack() == "Put on the main track.") }
        t = ses.activeTimeline
        #expect(row(t, b.id) == 0 && span(t, b.id) == [4, 8])
    }

    @Test func moveClipRightSwapsWithTheNeighborInOneStep() throws {
        let ses = session()
        ses.select(clips: [b.id])
        #expect(ses.fastCutCommandEnabled(.moveClipRight))
        try oneStep(ses) { #expect(ses.moveSelectedMainClips(1) == "Moved right.") }
        let t = ses.activeTimeline
        #expect(span(t, b.id) == [8, 12] && span(t, c.id) == [4, 8])
        #expect(span(t, ab.id) == [8, 12])                         // sound travels
        #expect(span(t, x.id) == [5, 7])                           // attached to C: follows it
    }

    @Test func moveClipAtTheEndsSaysSoAndChangesNothing() {
        let ses = session()
        ses.select(clips: [a.id])
        let depth = ses.history.undoDepth
        #expect(ses.moveSelectedMainClips(-1) != "Moved left.")
        #expect(ses.history.undoDepth == depth)
    }

    @Test func deleteSelectionOnlyKeepsTheAttachedClipsAndRestoresHold() throws {
        let ses = session()
        ses.select(clips: [c.id])
        #expect(ses.fastCutCommandEnabled(.deleteSelectionOnly))
        try oneStep(ses) { ses.deleteSelectionOnly() }
        #expect(span(ses.activeTimeline, x.id) == [9, 11])
        #expect(find(ses.activeTimeline, c.id) == nil)
        #expect(!ses.keepAttachedHeld)
    }

    @Test func optDownOnAnAttachedClipPutsItOnTheMainTrack() throws {
        let ses = session()
        ses.select(clips: [x.id])
        try oneStep(ses) { #expect(ses.moveSelectionLane(up: false)) }
        let t = ses.activeTimeline
        #expect(row(t, x.id) == 0 && span(t, x.id) == [9, 11])
    }

    @Test func optQOnTheMainTrackClosesV1() throws {
        let ses = session()
        ses.seek(to: s(6))
        try oneStep(ses) { ses.trimToPlayhead(.tail, mode: .plain) }
        let t = ses.activeTimeline
        #expect(mainSpans(t) == [[0, 4], [4, 6], [6, 10]])
        #expect(span(t, x.id) == [7, 9])
    }

    @Test func slowerSpeedRipplesV1AndCarriesTheAttachedClip() throws {
        let ses = session()
        ses.select(clips: [c.id, ac.id])
        try oneStep(ses) { #expect(ses.applySpeed(SpeedChange(speed: ClipSpeed(percent: 50)))) }
        var t = ses.activeTimeline
        #expect(span(t, c.id) == [8, 16] && span(t, ac.id) == [8, 16])
        ses.select(clips: [b.id, ab.id])
        try oneStep(ses) { #expect(ses.applySpeed(SpeedChange(speed: ClipSpeed(percent: 200)))) }
        t = ses.activeTimeline
        #expect(mainSpans(t) == [[0, 4], [4, 6], [6, 14]])
        #expect(span(t, x.id) == [7, 9])
        ses.select(clips: [b.id])
        try oneStep(ses) { #expect(ses.setReversed(true)) }
        #expect(mainSpans(ses.activeTimeline) == [[0, 4], [4, 6], [6, 14]])
    }

    @Test func fastCutCopyPastedIntoNormalLosesItsAttachments() throws {
        let ses = session()
        ses.select(clips: [c.id, ac.id, x.id])
        #expect(ses.copySelection())
        #expect(ses.setTimelineEditMode(.normal))
        ses.seek(to: s(20))
        ses.pasteClipboard()
        let t = try #require(ses.activeTimeline)
        let pasted = t.tracks.flatMap(\.clips).filter { $0.start >= s(20) }
        #expect(pasted.count == 3)
        #expect(pasted.allSatisfy { $0.attachment == nil })
    }

    @Test func liftOffWithOptCmdUpGoesThroughMoveSelectionLane() throws {
        let ses = session()
        ses.select(clips: [b.id])
        #expect(ses.moveSelectionLane(up: true))
        #expect(row(ses.activeTimeline, b.id) != 0)
        #expect(span(ses.activeTimeline, c.id) == [8, 12])
    }

    @Test func setAttachPointByCommandAndByClick() throws {
        let ses = session()
        ses.select(clips: [x.id])
        ses.seek(to: s(10))
        try oneStep(ses) { #expect(ses.setAttachPoint() == "Attach point set.") }
        #expect(find(ses.activeTimeline, x.id)?.attachment?.point == s(1))
        try oneStep(ses) { #expect(ses.setAttachPoint(clip: x.id, at: s(9))) }
        #expect(find(ses.activeTimeline, x.id)?.attachment?.point == .zero)
        #expect(!ses.setAttachPoint(clip: c.id, at: s(9)))         // a main clip has no attach point
    }

    @Test func fastCutCommandsSayWhatTheyDid() {
        let ses = session()
        ses.select(clips: [])
        #expect(ses.replaceSelectionWithSpacer() == "Select clips first.")
        #expect(ses.setAttachPoint() == "Select a clip above or below the main track first.")
        #expect(ses.appendToMainTrack(media: []).hasPrefix("Open a clip"))
    }

    // MARK: Ranges

    @Test func deleteRangeClosesV1AndCarriesTheAttachedClips() throws {
        let ses = session()
        ses.setInPoint(at: s(4)); ses.setOutPoint(at: s(8) - Time(1, 24))
        try oneStep(ses) { ses.extractRange() }
        let t = ses.activeTimeline
        #expect(span(t, c.id) == [4, 8])
        #expect(span(t, x.id) == [5, 7])
    }

    @Test func clearRangeLeavesASpacer() throws {
        let ses = session()
        ses.setInPoint(at: s(4)); ses.setOutPoint(at: s(8) - Time(1, 24))
        try oneStep(ses) { ses.liftRange() }
        let t = ses.activeTimeline
        #expect(span(t, b.id) == nil)
        #expect(span(t, c.id) == [8, 12] && span(t, x.id) == [9, 11])
    }

    // MARK: Source edits

    private func media(_ ses: EditorSession, _ name: String = "m", dur: Int64 = 3) -> MediaRef { media(ses, name, duration: s(dur)) }

    private func media(_ ses: EditorSession, _ name: String, duration: Time) -> MediaRef {
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 24), isVariableFrameRate: false)
        let m = MediaRef(name: name, path: "/nonexistent/\(name).mov", fingerprint: MediaFingerprint(size: 1),
                         duration: duration, info: MediaInfo(duration: duration, video: v,
                                                           audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")))
        ses.perform("Import") { $0.add(m) }
        return m
    }

    @Test func appendGoesToTheEndOfV1WithItsSound() throws {
        let ses = session()
        let m = media(ses)
        try oneStep(ses) { #expect(ses.appendToMainTrack(media: [m.id]) == "Appended to the main track.") }
        let t = ses.activeTimeline
        #expect(mainSpans(t).last == [12, 15])
        #expect(t?.tracks[2].clips.last.map { span(t, $0.id) } == [12, 15])
        #expect(ses.playhead == s(15))
    }

    @Test func insertFromTheProjectPanelRipplesV1AndItsAttachedClips() throws {
        let ses = session()
        let m = media(ses)
        ses.seek(to: s(5))
        try oneStep(ses) { #expect(ses.placeMedia([m.id], mode: .insert)) }
        let t = ses.activeTimeline
        let spans = mainSpans(t)
        #expect(spans.contains([5, 8]))                            // at the playhead (B is cut there, FCP insert)
        for (l, r) in zip(spans, spans.dropFirst()) { #expect(l[1] == r[0]) }   // no hole, no overlap
        #expect(span(t, c.id) == [11, 15] && span(t, x.id) == [12, 14])
    }

    @Test func overwriteOnV1KeepsItWithoutHoles() throws {
        let ses = session()
        let m = media(ses)
        ses.seek(to: s(5))
        #expect(ses.placeMedia([m.id], mode: .overwrite))
        let spans = mainSpans(ses.activeTimeline)
        for (l, r) in zip(spans, spans.dropFirst()) { #expect(l[1] <= r[0]) }
        #expect(spans.last?[1] == 12)
    }

    @Test func attachBacktimedEndsAtThePlayheadAndAttachesAtItsLastFrame() throws {
        let ses = session()
        let m = media(ses)                                         // 3 s
        ses.seek(to: s(11))
        try oneStep(ses) { #expect(ses.placeMedia([m.id], placeOnTop: true, backtimed: true)) }
        let t = ses.activeTimeline
        let placed = t?.tracks.flatMap(\.clips).filter { $0.media == m.id && $0.kind == .video } ?? []
        let p = try #require(placed.first)
        #expect(span(t, p.id) == [8, 11])                          // ends at the playhead
        #expect(row(t, p.id) != 0)
        #expect(p.attachment?.host == c.id)
        #expect(p.attachment?.point == s(3) - Time(1, 24))
    }

    /// No room before the sequence start: the head is cut, the clip starts at 0 and still ends at the playhead.
    @Test func attachBacktimedCutsTheHeadAtTheSequenceStart() throws {
        let ses = session()
        let m = media(ses)                                         // 3 s
        ses.seek(to: s(1))
        #expect(ses.placeMedia([m.id], placeOnTop: true, backtimed: true))
        let p = try #require(ses.activeTimeline?.tracks.flatMap(\.clips).first { $0.media == m.id && $0.kind == .video })
        #expect(span(ses.activeTimeline, p.id) == [0, 1])
        #expect(p.source == TimeRange(start: s(2), duration: s(1)))
        #expect(p.attachment?.point == s(1) - Time(1, 24))         // still the last frame
    }

    /// Several items form one run that ends exactly on the playhead, in selection order, also with odd durations.
    @Test func attachBacktimedRunEndsOnThePlayheadWithOddDurations() throws {
        let ses = session()
        let a = media(ses, "odd1", duration: Time(202, 100)), b = media(ses, "odd2", duration: Time(202, 100))
        ses.seek(to: s(10))                                         // inside V1 (12 s): beyond it Fast Cut closes the gap
        let head = ses.playhead                                     // seek clamps to the sequence length
        try oneStep(ses) { #expect(ses.placeMedia([a.id, b.id], placeOnTop: true, backtimed: true)) }
        let t = ses.activeTimeline
        let clips = t?.tracks.flatMap(\.clips).filter { ($0.media == a.id || $0.media == b.id) && $0.kind == .video }.sorted { $0.start < $1.start } ?? []
        #expect(clips.count == 2)
        #expect(clips.last?.timeline.end == head && head > s(0))                 // exactly on the playhead
        #expect(clips.first?.timeline.end == clips.last?.start)    // back to back, no gap
        let fd = Time(1, 24)
        for c in clips { #expect(c.start == c.start.snapped(to: fd) && c.timeline.duration == c.timeline.duration.snapped(to: fd)) }
        #expect(clips.first?.media == a.id)                        // selection order
        #expect(ses.undoName == "Attach Backtimed")
    }

    /// Playhead beyond the end of V1: the run ends at the V1 end and attaches above V1, never on the main track.
    @Test func attachBacktimedBeyondTheMainTrackEndClampsAndStaysOffV1() throws {
        let ses = session()
        let m = media(ses, dur: 5)
        ses.seek(to: s(20))
        try oneStep(ses) { #expect(ses.placeMedia([m.id], placeOnTop: true, backtimed: true)) }
        let t = try #require(ses.activeTimeline)
        let p = try #require(t.tracks.flatMap(\.clips).first { $0.media == m.id && $0.kind == .video })
        #expect(p.timeline.end == s(12) && p.timeline.start == s(7))
        #expect(!t.tracks[0].clips.contains { $0.id == p.id })
        #expect(p.attachment != nil)
    }

    @Test func sourceEditBacktimedBeyondTheMainTrackEndStaysOffV1() throws {
        let ses = session()
        let m = media(ses, dur: 5)
        ses.seek(to: s(20))
        #expect(ses.sourceEdit(media: m.id, mode: .overwrite, placeOnTop: true, backtimed: true))
        let t = try #require(ses.activeTimeline)
        let p = try #require(t.tracks.flatMap(\.clips).first { $0.media == m.id && $0.kind == .video })
        #expect(p.timeline.end == s(12) && !t.tracks[0].clips.contains { $0.id == p.id })
    }

    @Test func placeOnTopNeverLandsOnTheMainTrackInFastCut() throws {
        let ses = session()
        let m = media(ses, dur: 3)
        ses.seek(to: s(20))
        #expect(ses.placeMedia([m.id], placeOnTop: true))
        let t = try #require(ses.activeTimeline)
        #expect(!t.tracks[0].clips.contains { $0.media == m.id })
    }

    @Test func attachBacktimedWithAnEmptyMainTrackIsRefused() throws {
        let ses = EditorSession(project: Project(name: "P", timelines: [{
            var t = Timeline(name: "t", frameDuration: Time(1, 24), tracks: [Track(kind: .video), Track(kind: .audio)])
            t.setEditMode(.magnetic); return t }()]))
        let m = media(ses, dur: 3)
        ses.seek(to: s(2))
        let depth = ses.history.undoDepth
        #expect(!ses.placeMedia([m.id], placeOnTop: true, backtimed: true))
        #expect(!ses.sourceEdit(media: m.id, mode: .overwrite, placeOnTop: true, backtimed: true))
        #expect(ses.history.undoDepth == depth)
    }

    private func emptyMainSession() -> EditorSession {
        var t = Timeline(name: "t", frameDuration: Time(1, 24), tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
        t.setEditMode(.magnetic)
        return EditorSession(project: Project(name: "P", timelines: [t]))
    }

    /// Empty main track: Place on Top puts the clip on V1 from the playhead's magnetic position, never unattached above it.
    @Test func placeOnTopWithAnEmptyMainTrackLandsOnTheMainTrack() throws {
        let ses = emptyMainSession()
        let m = media(ses, dur: 3)
        ses.seek(to: s(5))
        try oneStep(ses) { #expect(ses.placeMedia([m.id], placeOnTop: true)) }
        let t = try #require(ses.activeTimeline)
        #expect(t.tracks[0].clips.contains { $0.media == m.id })
        #expect(t.tracks[1].clips.isEmpty)
        #expect(t.tracks[0].clips.first?.start == .zero)
    }

    @Test func sourceEditPlaceOnTopWithAnEmptyMainTrackLandsOnTheMainTrack() throws {
        let ses = emptyMainSession()
        let m = media(ses, dur: 3)
        ses.seek(to: s(5))
        try oneStep(ses) { #expect(ses.sourceEdit(media: m.id, mode: .overwrite, placeOnTop: true)) }
        let t = try #require(ses.activeTimeline)
        #expect(t.tracks[0].clips.contains { $0.media == m.id } && t.tracks[1].clips.isEmpty)
        #expect(t.tracks[0].clips.first?.start == .zero)
    }

    /// Playhead at 0: nothing to place, no undo step, no format change.
    @Test func attachBacktimedAtZeroFromTheProjectPanelMakesNoUndoStep() throws {
        let ses = session()
        let m = media(ses, dur: 3)
        let before = ses.activeTimeline
        let depth = ses.history.undoDepth
        ses.seek(to: .zero)
        #expect(!ses.placeMedia([m.id], placeOnTop: true, backtimed: true))
        #expect(ses.history.undoDepth == depth && ses.activeTimeline == before)
    }

    /// A 5 s still in a 29.97 sequence is 150 whole frames, so every start of the run is on the grid.
    @Test func stillLengthSnapsToTheSequenceFrameGrid() throws {
        let fd = Time(1001, 30000)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video), Track(kind: .audio)])
        let base = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(20, 1)), start: .zero)
        try t.tracks[0].overwrite(base)
        t.setEditMode(.magnetic)
        let ses = EditorSession(project: Project(name: "P", timelines: [t]))
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "png", bitDepth: 8, chroma: "4:4:4",
                               nominalFrameDuration: fd, isVariableFrameRate: false)
        let m = MediaRef(name: "still", path: "/nonexistent/still.png", fingerprint: MediaFingerprint(size: 1),
                         duration: Time(5, 1), info: MediaInfo(duration: Time(5, 1), video: v, isStill: true))
        ses.perform("Import") { $0.add(m) }
        ses.seek(to: Time(10, 1))
        #expect(ses.placeMedia([m.id, m.id], placeOnTop: true, backtimed: true))
        let clips = (ses.activeTimeline?.tracks.flatMap(\.clips) ?? []).filter { $0.media == m.id }.sorted { $0.start < $1.start }
        #expect(clips.count == 2)
        for c in clips { #expect(c.start == c.start.snapped(to: fd) && c.timeline.duration == fd * 150) }
    }

    /// Source monitor path: the sequence In/Out play no part; the source In..Out is the length, the playhead the end.
    @Test func sourceEditBacktimedIgnoresTheSequenceInOut() throws {
        let ses = session()
        let m = media(ses, dur: 10)
        ses.setSourceMarks(SourceMarks(markIn: s(2), markOut: s(5)), for: m.id)
        ses.seek(to: s(3)); ses.markIn()
        ses.seek(to: s(4)); ses.markOut()                          // a 1 s sequence range that must not matter
        ses.seek(to: s(11))
        try oneStep(ses) { #expect(ses.sourceEdit(media: m.id, mode: .overwrite, placeOnTop: true, backtimed: true)) }
        let p = try #require(ses.activeTimeline?.tracks.flatMap(\.clips).first { $0.media == m.id && $0.kind == .video })
        #expect(span(ses.activeTimeline, p.id) == [8, 11])
        #expect(p.source == TimeRange(start: s(2), duration: s(3)))
        #expect(p.attachment?.host == c.id && p.attachment?.point == s(3) - Time(1, 24))
        #expect(ses.playhead == s(11))
        #expect(ses.undoName == "Attach Backtimed")
    }

    @Test func sourceEditBacktimedCutsTheHeadWhenItDoesNotFit() throws {
        let ses = session()
        let m = media(ses, dur: 10)
        ses.seek(to: s(2))
        #expect(ses.sourceEdit(media: m.id, mode: .overwrite, placeOnTop: true, backtimed: true))
        let p = try #require(ses.activeTimeline?.tracks.flatMap(\.clips).first { $0.media == m.id && $0.kind == .video })
        #expect(span(ses.activeTimeline, p.id) == [0, 2])
        #expect(p.source == TimeRange(start: s(8), duration: s(2)))   // the last 2 s of the source
        #expect(p.attachment?.point == s(2) - Time(1, 24))
    }

    @Test func attachBacktimedDoesNothingInNormal() {
        let ses = session(.normal)
        let m = media(ses)
        let before = ses.activeTimeline
        ses.seek(to: s(11))
        #expect(!ses.placeMedia([m.id], placeOnTop: true, backtimed: true))
        #expect(!ses.sourceEdit(media: m.id, mode: .overwrite, placeOnTop: true, backtimed: true))
        #expect(ses.activeTimeline == before)
    }

    @Test func attachBacktimedIsAFastCutCommand() {
        #expect(EditorCommand.fastCutCommands.contains(.attachBacktimed))
        #expect(EditorCommand.fastCutCommands.contains(.pasteAttached))
    }

    // MARK: Nest

    @Test func nestKeepsV1Closed() throws {
        let ses = session()
        ses.select(clips: [b.id, ab.id])
        #expect(ses.nestSelection(name: "N") != nil)
        let t = ses.activeTimeline
        #expect(mainSpans(t) == [[0, 4], [4, 8], [8, 12]])
        #expect(span(t, x.id) == [9, 11])
    }

    @Test func unnestKeepsV1GaplessWhenTheNestedContentHasAHole() throws {
        let ses = session()
        ses.select(clips: [b.id, ab.id])
        let seq = try #require(ses.nestSelection(name: "N"))
        // The nested sequence's own V1 starts 2 s late: the content would leave a hole at the nest's start.
        try ses.perform("Edit nested") { p in
            let i = try #require(p.timelines.firstIndex { $0.id == seq })
            for k in p.timelines[i].tracks.indices where !p.timelines[i].tracks[k].clips.isEmpty {
                let first = p.timelines[i].tracks[k].clips[0]
                p.timelines[i].tracks[k].remove(first.id)
                var late = first
                late.start = s(2)
                late.source = TimeRange(start: first.source.start, duration: s(2))
                try p.timelines[i].tracks[k].overwrite(late)
            }
        }
        let nest = try #require(ses.activeTimeline?.tracks[0].clips.first { $0.sequence == seq })
        ses.select(clips: [nest.id])
        try oneStep(ses) { #expect(ses.unnestSelection(), "\(ses.lastError ?? "")") }
        let t = ses.activeTimeline
        let v1 = mainSpans(t).sorted { $0[0] < $1[0] }
        #expect(v1.first == [0, 4])
        for (x, y) in zip(v1, v1.dropFirst()) { #expect(x[1] == y[0]) }   // no hole
        #expect(span(t, c.id)?[1] == 10 && span(t, x.id) != nil)
    }

    // MARK: Gesture-built edits (no gap behind a moved main clip)

    @Test func movedMainClipWithItsSoundLeavesNoGap() throws {
        let ses = session()
        let t = try #require(ses.activeTimeline)
        let v1 = t.tracks[0].id, a1 = t.tracks[2].id
        let edits: [TimelineEdit] = [.moveGroup(a.id, to: s(9), track: v1, partners: [aa.id: a1]),
                                     .move(aa.id, to: s(9), track: a1)]
        let mapped = TimelineEdit.fastCut(edits, in: t)
        #expect(mapped.count == 1)
        let out = try TimelineEdit.apply(mapped, to: t)
        #expect(mainSpans(out) == [[0, 4], [4, 8], [8, 12]])
        #expect(span(out, a.id) == [4, 8])
        #expect(span(out, aa.id) == [4, 8])
        #expect(span(out, x.id) == [9, 11])
    }

    @Test func unlinkedMainClipMoveLeavesNoGap() throws {
        let ses = session()
        let t = try #require(ses.activeTimeline)
        let v1 = t.tracks[0].id
        let mapped = TimelineEdit.fastCut([.only([a.id], [.move(a.id, to: s(9), track: v1)])], in: t)
        let out = try TimelineEdit.apply(mapped, to: t)
        #expect(mainSpans(out) == [[0, 4], [4, 8], [8, 12]])
    }
}
