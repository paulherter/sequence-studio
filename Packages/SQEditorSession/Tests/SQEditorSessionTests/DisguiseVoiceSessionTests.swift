import Foundation
import Testing
import SQCore
import SQTranscribe
@testable import SQEditorSession

@MainActor @Suite struct DisguiseVoiceSessionTests {
    private static let fd = Time(1, 30)

    private static func ms(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: Time(a, 1000), end: Time(b, 1000)) }

    private static let transcript = Transcript(language: "en-US", words: [
        TranscriptWord(text: "before", range: ms(1000, 1500)),
        TranscriptWord(text: "straddle", range: ms(1900, 2300)),
        TranscriptWord(text: "hello", range: ms(2500, 3000)),
        TranscriptWord(text: "there", range: ms(3000, 3500)),
        TranscriptWord(text: "ending", range: ms(4800, 5400)),
        TranscriptWord(text: "after", range: ms(6000, 6500)),
    ])

    private static func session(inOut: TimeRange?) -> (EditorSession, Clip) {
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        var tr = Track(kind: .audio)
        try! tr.overwrite(a)
        var tl = Timeline(name: "T", frameDuration: fd, tracks: [tr])
        tl.inOut = inOut
        let sess = EditorSession(project: Project(name: "P", timelines: [tl]))
        sess.select(clips: [a.id], captions: [])
        return (sess, a)
    }

    private static func captions(_ s: EditorSession) -> [CaptionItem] { s.activeTimeline!.captionTracks.flatMap(\.items) }

    @Test func oneUndoStepDisguisesTheRangeAndCaptionsStayInsideIt() {
        let range = TimeRange(start: Time(2, 1), end: Time(5, 1))
        let (sess, _) = Self.session(inOut: range)
        let depth = sess.undoDepth
        let out = sess.disguiseVoice(transcript: Self.transcript)
        #expect(out?.range == range)
        #expect(out?.clips == 1)
        #expect(sess.undoDepth == depth + 1)

        let clips = sess.activeTimeline!.tracks[0].clips
        #expect(clips.count == 3)
        let disguised = clips.filter(\.hasDisguiseVoice)
        #expect(disguised.count == 1)
        #expect(disguised.first?.timeline == range)

        let items = Self.captions(sess)
        #expect(!items.isEmpty)
        #expect(out?.captions == items.count)
        #expect(items.allSatisfy { $0.range.start >= range.start && $0.range.end <= range.end && !$0.range.isEmpty })
        let text = items.flatMap(\.lines).joined(separator: " ")
        #expect(text.contains("hello") && text.contains("there") && text.contains("straddle") && text.contains("ending"))
        #expect(!text.contains("before") && !text.contains("after"))

        sess.undo()
        #expect(sess.activeTimeline!.tracks[0].clips.count == 1)
        #expect(sess.activeTimeline!.tracks[0].clips.allSatisfy { !$0.hasDisguiseVoice })
        #expect(Self.captions(sess).isEmpty)
    }

    @Test func withoutATranscriptOnlyTheEffectIsApplied() {
        let (sess, a) = Self.session(inOut: nil)
        let depth = sess.undoDepth
        let out = sess.disguiseVoice(transcript: nil)
        #expect(out?.range == a.timeline)          // no In/Out: the selected clip's own span
        #expect(out?.captions == 0)
        #expect(sess.undoDepth == depth + 1)
        #expect(sess.activeTimeline!.tracks[0].clips.count == 1)
        #expect(sess.activeTimeline!.tracks[0].clips[0].hasDisguiseVoice)
        #expect(Self.captions(sess).isEmpty)
    }

    @Test func inOutOutsideTheSelectionFallsBackToTheClips() {
        let (sess, a) = Self.session(inOut: TimeRange(start: Time(20, 1), end: Time(30, 1)))
        #expect(sess.disguiseVoiceRange == a.timeline)
    }

    // MARK: Review of the first version

    private static func audio(_ start: Int64, _ dur: Int64, link: UUID? = nil) -> Clip {
        Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(dur, 1)), start: Time(start, 1), link: link)
    }

    private static func session(_ tl: Timeline, select ids: Set<Clip.ID>) -> EditorSession {
        let sess = EditorSession(project: Project(name: "P", timelines: [tl]))
        sess.select(clips: ids, captions: [])
        return sess
    }

    /// In and Out between frames: the range grows to whole frames, so no part of a frame keeps the original voice.
    @Test func rangeIsWidenedToWholeFrames() {
        let (sess, _) = Self.session(inOut: Self.ms(2_010, 4_990))
        #expect(sess.disguiseVoiceRange == TimeRange(start: Time(2, 1), end: Time(5, 1)))
        let (near, _) = Self.session(inOut: Self.ms(2_020, 4_980))       // nearest frames would be 61 and 149: too narrow
        #expect(near.disguiseVoiceRange == TimeRange(start: Time(2, 1), end: Time(5, 1)))
    }

    /// An In/Out left from other work reaches only one of the two selected clips: the selection decides.
    @Test func inOutThatMissesASelectedClipDoesNotDecide() {
        let a = Self.audio(0, 10), b = Self.audio(12, 8)
        var tr = Track(kind: .audio)
        try! tr.overwrite(a); try! tr.overwrite(b)
        var tl = Timeline(name: "T", frameDuration: Self.fd, tracks: [tr])
        tl.inOut = TimeRange(start: Time(2, 1), end: Time(5, 1))
        let sess = Self.session(tl, select: [a.id, b.id])
        #expect(sess.disguiseVoiceRange == TimeRange(start: .zero, end: Time(20, 1)))
        let out = sess.disguiseVoice(transcript: nil)
        #expect(out?.clips == 2)
        #expect(sess.activeTimeline!.tracks[0].clips.map(\.hasDisguiseVoice) == [true, true])
        // In/Out across both wins.
        tl.inOut = TimeRange(start: Time(8, 1), end: Time(14, 1))
        #expect(Self.session(tl, select: [a.id, b.id]).disguiseVoiceRange == tl.inOut)
    }

    @Test func lockedCaptionTrackSkipsCaptionsButStillDisguises() {
        let a = Self.audio(0, 10)
        var tr = Track(kind: .audio)
        try! tr.overwrite(a)
        var tl = Timeline(name: "T", frameDuration: Self.fd, tracks: [tr])
        tl.inOut = TimeRange(start: Time(2, 1), end: Time(5, 1))
        tl.captionTracks = [CaptionTrack(name: "C", isLocked: true)]
        let sess = Self.session(tl, select: [a.id])
        let out = sess.disguiseVoice(transcript: Self.transcript)
        #expect(out?.captionTrackLocked == true && out?.captions == 0 && out?.clips == 1)
        #expect(sess.activeTimeline!.tracks[0].clips.map(\.hasDisguiseVoice) == [false, true, false])
        #expect(Self.captions(sess).isEmpty)
        let text = out?.statusText(frameDuration: Self.fd, hasTranscript: true) ?? ""
        #expect(text.contains("caption track is locked"))
        #expect(text.hasSuffix(AudioDisguiseValues.hint))
    }

    @Test func lockedLinkedAudioRefusesAndSaysWhy() {
        let link = UUID()
        let a1 = Self.audio(0, 10, link: link), a2 = Self.audio(0, 10, link: link)
        var t1 = Track(kind: .audio), t2 = Track(kind: .audio)
        try! t1.overwrite(a1); try! t2.overwrite(a2)
        t2.isLocked = true
        var tl = Timeline(name: "T", frameDuration: Self.fd, tracks: [t1, t2])
        tl.inOut = TimeRange(start: Time(2, 1), end: Time(5, 1))
        let sess = Self.session(tl, select: [a1.id])
        let depth = sess.undoDepth
        #expect(sess.disguiseVoice(transcript: Self.transcript) == nil)
        #expect(sess.undoDepth == depth)
        #expect(sess.lastError?.contains("locked track") == true)
        #expect(sess.activeTimeline!.tracks[0].clips == [a1])
    }

    @Test func statusNamesTheRangeAndTheClips() {
        let out = EditorSession.DisguiseVoiceOutcome(range: TimeRange(start: Time(2, 1), end: Time(5, 1)), clips: 2, captions: 3)
        let text = out.statusText(frameDuration: Self.fd, hasTranscript: true)
        #expect(text.hasPrefix("Disguise Voice on 2 clips, 00:00:02:00 to 00:00:05:00. 3 captions created."))
        #expect(text.hasSuffix(AudioDisguiseValues.hint))
        let one = EditorSession.DisguiseVoiceOutcome(range: out.range, clips: 1, captions: 0)
        #expect(one.statusText(frameDuration: Self.fd, hasTranscript: false).contains("on 1 clip, "))
        #expect(one.statusText(frameDuration: Self.fd, hasTranscript: false).contains("need a current transcript"))
        for word in ["anonym", "safe", "secure", "unrecognizable", "protected"] { #expect(!text.lowercased().contains(word)) }
    }

    @Test func nothingSelectedDoesNothing() {
        let (sess, _) = Self.session(inOut: nil)
        sess.select(clips: [], captions: [])
        let depth = sess.undoDepth
        #expect(sess.disguiseVoice(transcript: Self.transcript) == nil)
        #expect(sess.undoDepth == depth)
    }

    @Test func existingCaptionsOutsideTheRangeAreKept() {
        let range = TimeRange(start: Time(2, 1), end: Time(5, 1))
        let (sess, _) = Self.session(inOut: range)
        let outside = CaptionItem(lines: ["kept"], range: TimeRange(start: Time(7, 1), end: Time(8, 1)))
        let inside = CaptionItem(lines: ["replaced"], range: TimeRange(start: Time(3, 1), end: Time(4, 1)))
        #expect(sess.addCaptions([outside, inside]))
        _ = sess.disguiseVoice(transcript: Self.transcript)
        let text = Self.captions(sess).flatMap(\.lines).joined(separator: " ")
        #expect(text.contains("kept") && !text.contains("replaced") && text.contains("hello"))
    }

    @Test func captionItemsAreOnFramesInsideTheRangeWithWordsInsideTheCaption() {
        let range = TimeRange(start: Time(2, 1), end: Time(5, 1))
        let items = DisguiseVoiceCaptions.items(transcript: Self.transcript, preset: .standard, range: range, frameDuration: Self.fd)
        #expect(!items.isEmpty)
        for it in items {
            #expect(it.range.start >= range.start && it.range.end <= range.end)
            #expect(it.range.start == it.range.start.snapped(to: Self.fd) && it.range.end == it.range.end.snapped(to: Self.fd))
            #expect(it.words.allSatisfy { $0.range.start >= .zero && $0.range.end <= it.range.duration })
        }
        for (a, b) in zip(items, items.dropFirst()) { #expect(a.range.end <= b.range.start) }
        let none = DisguiseVoiceCaptions.items(transcript: Self.transcript, preset: .standard,
                                               range: TimeRange(start: Time(8, 1), end: Time(9, 1)), frameDuration: Self.fd)
        #expect(none.isEmpty)
    }
}
