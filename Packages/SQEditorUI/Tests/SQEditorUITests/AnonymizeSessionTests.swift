import AppKit
import Foundation
import SQCore
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

private let fd = Time(1, 30)

@MainActor private func makeSession() -> (EditorSession, Clip) {
    let info = MediaInfo(duration: Time(10, 1), video: VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8,
                                                                       chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false))
    let m = MediaRef(name: "m", path: "/nonexistent/m.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1), info: info)
    // Source 2 s...6 s of the file, placed at 1 s of the sequence.
    let c = Clip(name: "Street", media: m.id, kind: .video, source: TimeRange(start: Time(2, 1), duration: Time(4, 1)), start: Time(1, 1))
    var track = Track(kind: .video)
    try! track.overwrite(c)
    let t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [track])
    return (EditorSession(project: Project(name: "P", media: [m], timelines: [t]), engine: StubProgramEngine()), c)
}

private func pick(_ x: Double) -> MagicSelection {
    MagicSelection(points: [MagicPoint(position: Vec2(x, 0.4), subtract: false, sourceTime: Time(3, 1))], part: .face)
}

@MainActor @Suite struct AnonymizeSessionTests {
    @Test func theRequestCoversTheClipInSourceTimeAndStartsAtThePlayhead() throws {
        let (s, c) = makeSession()
        s.select(clips: [c.id])
        s.seek(to: Time(2, 1))                                   // 1 s into the clip = source 3 s
        let r = try #require(s.anonymizeRequest())
        #expect(r.clip == c.id && r.clipName == "Street" && r.path == "/nonexistent/m.mov")
        #expect(abs(r.first - 2) < 1e-6 && abs(r.last - (6 - 1.0 / 30)) < 1e-6)
        #expect(abs(r.anchor - 3) < 1e-6)
        #expect(r.pictureWidth == 1920 && r.pictureHeight == 1080)
        s.seek(to: Time(8, 1))                                   // playhead off the clip: its first frame
        #expect(abs(try #require(s.anonymizeRequest()).anchor - 2) < 1e-6)
    }

    @Test func applyIsOneUndoStep() throws {
        let (s, c) = makeSession()
        s.select(clips: [c.id])
        let r = try #require(s.anonymizeRequest())
        #expect(s.applyAnonymize([pick(0.3), pick(0.7)], target: .face, cover: .mosaic, subjectWidth: 200, request: r) == .applied)
        func clip() -> Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == c.id }! }
        #expect(clip().masks.count == 2 && clip().effects.count == 1)
        #expect(clip().effects[0].maskInput == clip().masks.map(\.id))
        #expect(s.undo())
        #expect(clip().masks.isEmpty && clip().effects.isEmpty)
    }

    @Test func aClipThatIsGoneGetsNothing() throws {
        let (s, c) = makeSession()
        s.select(clips: [c.id])
        var r = try #require(s.anonymizeRequest())
        r.clip = Clip.ID()
        #expect(s.applyAnonymize([pick(0.3)], target: .face, cover: .blur, subjectWidth: 200, request: r) == .clipGone)
    }

    /// Trimmed, slipped, retimed or reversed during the run: the followed frames are not the ones the clip shows now.
    @Test func aClipEditedDuringTheRunIsRefusedAndStaysAsItIs() throws {
        let edits: [(String, (inout Clip) -> Void)] = [
            ("trim out", { $0.source = TimeRange(start: Time(2, 1), duration: Time(5, 1)) }),
            ("slip", { $0.source = TimeRange(start: Time(3, 1), duration: Time(4, 1)) }),
            ("speed", { $0.speed = ClipSpeed(percent: 50) }),
            ("reverse", { $0.reversed = true }),
            ("ramp", { $0.setSpeedKeys(SpeedKeys(segments: [SpeedSegment(duration: Time(2, 1), from: .normal),
                                                            SpeedSegment(duration: Time(2, 1), from: .normal, reversed: true)], origin: Time(2, 1))) }),
            ("hold", { $0.holdFrame = Time(3, 1) }),
        ]
        for (name, edit) in edits {
            let (s, c) = makeSession()
            s.select(clips: [c.id])
            let r = try #require(s.anonymizeRequest())
            try s.perform("Edit") { p in
                try p.edit(r.timeline) { t in
                    var n = c
                    edit(&n)
                    var track = Track(kind: .video); try track.overwrite(n); t.tracks[0] = track
                }
            }
            let before = s.project
            let result = s.applyAnonymize([pick(0.3)], target: .face, cover: .mosaic, subjectWidth: 200, request: r)
            #expect(result == .clipRetimed, "\(name)")
            #expect(s.project == before, "\(name)")
            #expect(result.message.contains("Nothing was changed") && result.message.contains("again"))
        }
        // An edit that does not change which frames show (a move, another effect) is fine.
        let (s, c) = makeSession()
        s.select(clips: [c.id])
        let r = try #require(s.anonymizeRequest())
        try s.perform("Edit") { p in
            try p.edit(r.timeline) { t in
                var n = c
                n.opacityEnabled = false
                try t.replaceClip(n)
            }
        }
        #expect(s.applyAnonymize([pick(0.3)], target: .face, cover: .mosaic, subjectWidth: 200, request: r) == .applied)
    }

    /// A speed ramp that runs backward mid-clip shows source frames outside its edge frames' span: all are followed.
    @Test func aRampThatRunsBackwardIsFollowedOverEverySourceFrameItShows() throws {
        let (s, c) = makeSession()
        let timeline = try #require(s.activeTimeline?.id)
        try s.perform("Ramp") { p in
            try p.edit(timeline) { t in
                var n = c
                // 3 s forward from source 2 s (to 5 s), then 2 s backward (to 3 s): the last frame shows about 3 s.
                n.setSpeedKeys(SpeedKeys(segments: [SpeedSegment(duration: Time(3, 1), from: .normal),
                                                    SpeedSegment(duration: Time(2, 1), from: .normal, reversed: true)], origin: Time(2, 1)))
                var track = Track(kind: .video); try track.overwrite(n); t.tracks[0] = track
            }
        }
        s.select(clips: [c.id])
        let now = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == c.id })
        func sec(_ t: Time) -> Double { let v = now.sourceInstant(atLocal: t); return Double(v.value) / Double(v.timescale) }
        var lo = Double.infinity, hi = -Double.infinity
        var local = Time.zero
        while local < now.duration { lo = min(lo, sec(local)); hi = max(hi, sec(local)); local = local + fd }
        // The premise: the clip's edge frames do not span what it shows.
        #expect(hi > max(sec(.zero), sec(now.duration - fd)) + 0.5)
        let r = try #require(s.anonymizeRequest())
        #expect(abs(r.first - lo) < 1e-6 && abs(r.last - hi) < 1e-6)
        #expect(r.anchor >= r.first && r.anchor <= r.last)
    }

    @Test func checkLinesAreSequenceTimecodesWithACautiousReason() throws {
        let (s, c) = makeSession()
        s.select(clips: [c.id])
        let r = try #require(s.anonymizeRequest())
        let lines = s.anonymizeCheckLines([AnonymizeCheck(person: 1, reason: .noFace, from: 4, to: 4.5),
                                           AnonymizeCheck(person: 0, reason: .lost, from: 3, to: 3)], request: r)
        #expect(lines.map(\.time) == [Time(2, 1), Time(3, 1)])   // source 3 s and 4 s = sequence 2 s and 3 s
        #expect(lines[0].text == "00:00:02:00  Person 1: " + AnonymizeCheck.Reason.lost.text)
        #expect(lines[1].text.hasPrefix("00:00:03:00 to 00:00:03:15  Person 2: "))
        #expect(lines.map(\.critical) == [true, false])
    }

    /// Ranges where the person may be visible come first, whatever their time, and are never cut from the list.
    @Test func rangesWhereThePersonMayBeVisibleComeFirstAndAreNeverCut() throws {
        let (s, c) = makeSession()
        s.select(clips: [c.id])
        let r = try #require(s.anonymizeRequest())
        var checks = (0..<30).map { AnonymizeCheck(person: 0, reason: .noFace, from: 2 + Double($0) * 0.1, to: 2 + Double($0) * 0.1) }
        checks += (0..<20).map { AnonymizeCheck(person: $0, reason: .lost, from: 5.5, to: 5.9) }
        let lines = s.anonymizeCheckLines(checks, request: r)
        #expect(lines.count == 50 && lines.prefix(20).allSatisfy { $0.critical } && !lines.dropFirst(20).contains { $0.critical })
        let list = AnonymizeCheckLine.shown(lines.shuffled(), limit: AnonymizeDialog.maxLines)
        #expect(list.lines.count == 20 + AnonymizeDialog.maxLines && list.more == 30 - AnonymizeDialog.maxLines)
        #expect(list.lines.prefix(20).allSatisfy { $0.critical })
        #expect(list.lines.first?.time == Time(4, 1) + Time(15, 30))          // "Go to First" lands on a critical range
        #expect(list.lines.dropFirst(20).map(\.time) == list.lines.dropFirst(20).map(\.time).sorted())
        // The text says plainly that a person may be visible, and promises nothing.
        let text = AnonymizeDialog.checksText(lines).lowercased()
        #expect(text.contains("may be visible") && text.contains("check those first"))
        #expect(!AnonymizeDialog.checksText(Array(lines.dropFirst(20))).lowercased().contains("may be visible"))
    }

    @Test func theDialogOffersEveryPersonAndRemembersTheChoice() throws {
        let d = try #require(UserDefaults(suiteName: "sq.test.anonymize.\(UUID().uuidString)"))
        func person(_ x: Double) -> AnonymizePerson {
            AnonymizePerson(label: 1, point: Vec2(x, 0.5), box: AnonymizeBox(x: x - 0.1, y: 0.2, width: 0.2, height: 0.7), face: nil)
        }
        let people = [person(0.15), person(0.5), person(0.85)]
        #expect(people.enumerated().map { AnonymizeDialog.personLabel($0.offset, $0.element) } == ["Person 1 (left)", "Person 2 (center)", "Person 3 (right)"])
        let ui = AnonymizeDialog.makeView(people: people, defaults: d)
        #expect(ui.controller.choice == AnonymizeChoice(target: .face, cover: .mosaic, people: [0, 1, 2]))
        ui.controller.boxes[1].state = .off
        ui.controller.target.selectedSegment = 2
        ui.controller.cover.selectedSegment = 1
        let c = ui.controller.choice
        #expect(c == AnonymizeChoice(target: .skin, cover: .blur, people: [0, 2]))
        c.remember(d)
        #expect(AnonymizeChoice.remembered(d) == (.skin, .blur))
        // The sheet's text promises nothing.
        let t = AnonymizeDialog.hint.lowercased()
        for word in ["guarantee", "certain", "safe", "fully"] { #expect(!t.contains(word)) }
        #expect(t.contains("check"))
    }
}
