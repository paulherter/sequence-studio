import Testing
import Foundation
@testable import SQCore

@Suite struct VoiceoverTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    private func timeline() -> Timeline {
        Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
    }

    @Test func scriptIsTrimmedAndBlankLinesCollapsed() {
        #expect(Voiceover.cleaned("  Hello   world \r\n\r\n\r\n\r\nSecond\t line  ") == "Hello world\n\nSecond line")
        #expect(Voiceover.cleaned(" \n ") == "")
    }

    @Test func scriptIsCappedAtTheLimit() {
        let long = String(repeating: "a", count: Voiceover.maxCharacters + 50)
        #expect(Voiceover.cleaned(long).count == Voiceover.maxCharacters)
    }

    @Test func fileNameUsesFirstWordsAndStaysUnique() {
        let text = "Welcome to the show, today we talk about cats and dogs"
        let name = Voiceover.fileName(for: text, existing: [])
        #expect(name == "Voiceover - Welcome to the show today we.caf")
        #expect(Voiceover.fileName(for: text, existing: [name]) == "Voiceover - Welcome to the show today we 2.caf")
        #expect(Voiceover.fileName(for: "!!!", existing: []) == "Voiceover.caf")
        #expect(Voiceover.fileName(for: "a/b: c", existing: []) == "Voiceover - ab c.caf")
    }

    @Test func clipNameDropsTheExtension() {
        #expect(Voiceover.clipName(fromFile: "Voiceover - Hi there.caf") == "Voiceover - Hi there")
    }

    @Test func estimateScalesWithWordsAndRate() {
        let text = String(repeating: "word ", count: 150)
        let normal = Voiceover.estimatedSeconds(of: text, rate: Voiceover.defaultRate)
        #expect(abs(normal - 60) < 6)
        #expect(Voiceover.estimatedSeconds(of: text, rate: Voiceover.maxRate) < normal)
        #expect(Voiceover.estimatedSeconds(of: "", rate: Voiceover.defaultRate) == 0)
    }

    @Test func rateIsClampedToTheRange() {
        #expect(Voiceover.clampedRate(-1) == Voiceover.minRate)
        #expect(Voiceover.clampedRate(5) == Voiceover.maxRate)
        #expect(Voiceover.clampedRate(0.5) == 0.5)
    }

    @Test func placesOnAnEmptyAudioTrackAndTagsItDialogue() throws {
        var t = timeline()
        let media = UUID()
        let r = try t.placeVoiceover(media: media, name: "VO", duration: s(4), at: s(2))
        #expect(!r.createdTrack)
        let tr = t.tracks.first { $0.id == r.track }!
        #expect(tr.kind == .audio && tr.audioRole == .dialogue)
        let c = tr.clips[0]
        #expect(c.id == r.clip && c.start == s(2) && c.timeline.duration == s(4) && c.media == media && c.kind == .audio)
        #expect(c.mediaDuration == s(4))
    }

    @Test func prefersAFreeDialogueTrackOverAnEmptyOne() throws {
        var t = timeline()
        var dlg = Track(kind: .audio)
        dlg.audioRole = .dialogue
        t.tracks.append(dlg)
        let r = try t.placeVoiceover(media: UUID(), name: "VO", duration: s(2), at: .zero)
        #expect(r.track == dlg.id)
    }

    @Test func skipsBusyLockedAndMusicTracksAndNeverOverwrites() throws {
        var t = timeline()
        let existing = Clip(name: "Music", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        try t.tracks[1].overwrite(existing)
        t.tracks[1].audioRole = .music
        var locked = Track(kind: .audio)
        locked.isLocked = true
        t.tracks.append(locked)
        let r = try t.placeVoiceover(media: UUID(), name: "VO", duration: s(3), at: s(1))
        #expect(r.createdTrack)
        #expect(t.tracks[1].clips == [existing])
        #expect(t.tracks.first { $0.id == r.track }?.audioRole == .dialogue)
        #expect(t.tracks.first { $0.id == locked.id }?.clips.isEmpty == true)
    }

    @Test func aDialogueTrackBusyElsewhereStillTakesAClipInAGap() throws {
        var t = timeline()
        var dlg = Track(kind: .audio)
        dlg.audioRole = .dialogue
        try dlg.overwrite(Clip(name: "A", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(2)), start: .zero))
        t.tracks.append(dlg)
        let r = try t.placeVoiceover(media: UUID(), name: "VO", duration: s(2), at: s(5))
        #expect(r.track == dlg.id && !r.createdTrack)
    }

    @Test func speedFactorMapsTheRateToHalfAndDouble() {
        #expect(Voiceover.speedFactor(rate: 0) == 0.5 && Voiceover.speedFactor(rate: 0.5) == 1 && Voiceover.speedFactor(rate: 1) == 2)
        for f in [0.5, 0.75, 1, 1.5, 2] { #expect(abs(Voiceover.speedFactor(rate: Voiceover.rate(forSpeedFactor: f)) - f) < 1e-9) }
        #expect(Voiceover.rate(forSpeedFactor: 9) == 1)
    }

    @Test func startIsRoundedUpToAFrameAndEmptyClipsRefused() throws {
        var t = timeline()
        let r = try t.placeVoiceover(media: UUID(), name: "VO", duration: s(1), at: Time(1, 40))
        #expect(t.tracks.flatMap(\.clips).first { $0.id == r.clip }!.start == Time(1, 30))
        #expect(throws: EditError.self) { try t.placeVoiceover(media: UUID(), name: "VO", duration: .zero, at: .zero) }
    }
}
