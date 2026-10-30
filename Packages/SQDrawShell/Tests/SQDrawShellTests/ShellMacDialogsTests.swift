import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// Paste Settings, Anonymize, Sequence Match, Create Captions and Replace Transcript: the Mac dialogs as shell forms.
@MainActor
@Suite(.serialized) struct ShellMacDialogsTests {
    /// Two 4 s video clips on V1 (a at 0, b at 4 s).
    func host() -> (ShellHost, Clip, Clip) {
        let media = MediaRef(name: "a.mov", path: "/a.mov", fingerprint: MediaFingerprint(size: 3), duration: Time(10, 1),
                             info: MediaInfo(duration: Time(10, 1),
                                         video: VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: Time(1, 25), isVariableFrameRate: false),
                                         audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")))
        let a = Clip(name: "a", media: media.id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let b = Clip(name: "b", media: media.id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: Time(4, 1))
        var v = Track(kind: .video)
        try! v.overwrite(a)
        try! v.overwrite(b)
        let tl = Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [v, Track(kind: .audio)])
        let h = ShellHost(session: ShellRecoveryTests.session(Project(name: "P", media: [media], timelines: [tl])), map: .premiereDefault)
        h.startDefaults = UserDefaults(suiteName: "sq-macdlg-\(UUID().uuidString)")!
        return (h, a, b)
    }

    func waitForDialog(_ h: ShellHost) async -> ShellDialog? {
        for _ in 0..<400 {
            if let d = h.dialog { return d }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    @Test func pasteSettingsOffersTheCopiedGroupsAndRemembersScale() async throws {
        let (h, a, b) = host()
        var lines: [String] = []
        h.onStatus = { lines.append($0) }
        let defaults = UserDefaults(suiteName: "sq-paste-\(UUID().uuidString)")!
        await h.pasteSettings(defaults: defaults)
        #expect(lines.last == "Copy a clip first, then select the clips to paste its attributes onto.")
        h.session.select(clips: [a.id], captions: [])
        #expect(h.session.copySelection())
        h.session.select(clips: [b.id], captions: [])
        let t = Task { @MainActor in await h.pasteSettings(defaults: defaults) }
        let d = try #require(await waitForDialog(h))
        #expect(d.messageText == "Paste Settings")
        let f = try #require(d.form)
        // The video groups in order, all ticked, then Scale Keyframe Times off.
        #expect(f.rows.count == 5)
        #expect(f.bool("motion") == true && f.bool("effects") == true && f.bool("scaleTimes") == false)
        f.set("effects", .bool(false))
        f.set("scaleTimes", .bool(true))
        d.press(.first)
        await t.value
        #expect(defaults.bool(forKey: "sq.pasteAttributes.scaleTimes"))
    }

    @Test func pasteSettingsCancelKeepsTheRememberedScale() async throws {
        let (h, a, b) = host()
        let defaults = UserDefaults(suiteName: "sq-paste-\(UUID().uuidString)")!
        h.session.select(clips: [a.id], captions: [])
        _ = h.session.copySelection()
        h.session.select(clips: [b.id], captions: [])
        let t = Task { @MainActor in await h.pasteSettings(defaults: defaults) }
        let d = try #require(await waitForDialog(h))
        d.form?.set("scaleTimes", .bool(true))
        d.press(.second)
        await t.value
        #expect(!defaults.bool(forKey: "sq.pasteAttributes.scaleTimes"))
    }

    @Test func sequenceMatchIsTheMacConfirm() async throws {
        let (h, _, _) = host()
        let cur = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1001, 30000))
        let new = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 25))
        let t = Task { @MainActor in await h.askChangeSequenceFormat(cur, new) }
        let d = try #require(await waitForDialog(h))
        #expect(d.messageText == "This clip does not match the sequence settings.")
        #expect(d.informativeText == "Sequence: 1920×1080, 29.97 fps. Clip: 1080×1920, 25 fps. Change the sequence settings to match the clip?")
        #expect(d.model.buttons.map(\.title) == ["Change Sequence Settings", "Keep Existing Settings"])
        d.press(.first)
        #expect(await t.value)
        let k = Task { @MainActor in await h.askChangeSequenceFormat(cur, new) }
        let d2 = try #require(await waitForDialog(h))
        d2.press(.second)
        #expect(await k.value == false)
    }

    @Test func createCaptionsRefillsTheLimitsPerStyleAndReturnsTheChoice() async throws {
        let (h, _, _) = host()
        let styles = [ShellCaptionStyle(name: "Standard", maxChars: 42, lines: 2, minSeconds: 1, gapFrames: 0),
                      ShellCaptionStyle(name: "Short", maxChars: 20, lines: 1, minSeconds: 0.337, gapFrames: 3)]
        let t = Task { @MainActor in await h.askCreateCaptions(styles: styles, selected: 0) }
        let d = try #require(await waitForDialog(h))
        #expect(d.messageText == "Create Captions" && d.width == 440)
        #expect(d.informativeText == "Captions are made from the transcript of the whole sequence.")
        let f = try #require(d.form)
        #expect(f.rows.count == 5)
        #expect(f.number("chars") == 42 && f.index("lines") == 1 && f.number("minDuration") == 1 && f.number("gap") == 0)
        f.set("style", .index(1))
        f.onChange?("style", .index(1))
        #expect(f.number("chars") == 20 && f.index("lines") == 0 && f.number("minDuration") == 0.34 && f.number("gap") == 3)
        d.press(.first)
        let c = try #require(await t.value)
        #expect(c == ShellCreateCaptionsChoice(style: 1, maxChars: 20, lines: 1, minSeconds: 0.34, gapFrames: 3))
    }

    @Test func createCaptionsCancelAnswersNil() async throws {
        let (h, _, _) = host()
        let t = Task { @MainActor in await h.askCreateCaptions(styles: [ShellCaptionStyle(name: "S", maxChars: 3, lines: 1, minSeconds: 0, gapFrames: 0)], selected: 5) }
        let d = try #require(await waitForDialog(h))
        #expect(d.form?.number("chars") == 8)   // clamped to the field's range
        d.press(.second)
        #expect(await t.value == nil)
    }

    @Test func replaceTranscriptIsTheMacOverwriteQuestion() async throws {
        let (h, _, _) = host()
        let t = Task { @MainActor in await h.confirmReplaceTranscript() }
        let d = try #require(await waitForDialog(h))
        #expect(d.messageText == "Replace the transcript?")
        #expect(d.informativeText == "Transcribing again replaces the current transcript, including your edits. Media is not changed.")
        #expect(d.model.buttons.map(\.title) == ["Transcribe Again", "Cancel"])
        d.press(.first)
        #expect(await t.value)
    }

    private func people() -> [AnonymizePerson] {
        [0.2, 0.5, 0.8].map { x in AnonymizePerson(label: 1, point: Vec2(x, 0.5), box: AnonymizeBox(x: x - 0.1, y: 0.2, width: 0.2, height: 0.7), face: nil) }
    }

    @Test func anonymizeIsTheMacSheetAndRemembersTheChoice() async throws {
        let (h, _, _) = host()
        let defaults = UserDefaults(suiteName: "sq-anon-\(UUID().uuidString)")!
        let t = Task { @MainActor in await h.askAnonymize(clipName: "C2156.MP4", people: people(), defaults: defaults) }
        let d = try #require(await waitForDialog(h))
        #expect(d.messageText == "Anonymize" && d.width == 440)
        #expect(d.informativeText.hasPrefix("C2156.MP4\nEach person gets a mask"))
        let f = try #require(d.form)
        // Cover, With, the people line, three people, the hint.
        #expect(f.rows.count == 7)
        #expect(f.index("target") == 0 && f.index("cover") == 0)
        #expect(f.rows[2] == .text("3 people found on this frame, numbered left to right:"))
        #expect(f.rows[3] == .check(id: "person0", title: "Person 1 (left)", on: true))
        #expect(f.rows[4] == .check(id: "person1", title: "Person 2 (center)", on: true))
        #expect(f.rows[5] == .check(id: "person2", title: "Person 3 (right)", on: true))
        #expect(f.rows[6] == .text(AnonymizeText.hint))
        f.set("target", .index(2)); f.set("cover", .index(1)); f.set("person1", .bool(false))
        d.press(.first)
        let c = try #require(await t.value)
        #expect(c == AnonymizeChoice(target: .skin, cover: .blur, people: [0, 2]))
        #expect(AnonymizeChoice.remembered(defaults) == (.skin, .blur))
    }

#if os(macOS)
    @Test func sequenceSettingsIsAsWideAsTheMacSheet() async throws {
        let (h, _, _) = host()
        let t = Task { @MainActor in await h.sequenceSettings() }
        let d = try #require(await waitForDialog(h))
        #expect(d.messageText == "Sequence Settings" && d.width == SQModal.Size.m.width && d.width == 600)
        d.press(.second)
        await t.value
    }
#endif

    @Test func newProjectPopupsAre28PointsLikeTheMacSheet() {
        let styles = ShellNewProject.popupStyles(templates: ProjectTemplate.builtIn)
        for id in ["template", "size", "rate", "audio", "outside"] { #expect(styles[id]?.height == 28, "\(id)") }
    }

    @Test func anonymizePeopleNoteIsRegularWeightLikeFormTextNoteFalse() async throws {
        let (h, _, _) = host()
        let defaults = UserDefaults(suiteName: "sq-anon-\(UUID().uuidString)")!
        let t = Task { @MainActor in await h.askAnonymize(clipName: "a", people: Array(people().prefix(2)), defaults: defaults) }
        let d = try #require(await waitForDialog(h))
        #expect(d.form?.strongNotes.contains(2) == true)
        #expect(d.form?.plainStrongNotes.contains(2) == true)
        d.press(.second)
        _ = await t.value
    }

    @Test func newProjectChooseButtonIs28PointsLikeTheMacSheet() {
        let form = ShellForm([.buttons(id: "location", label: "Location", detail: "~/Movies", titles: ["Choose\u{2026}"])])
        form.chips["location"] = ShellForm.Chip(icon: .folder, buttonWidth: 92)
        _ = form.layout(origin: .zero, width: 600)
        #expect(form.buttonFrames(0).first?.height == 28)
    }

    @Test func anonymizeWithNobodyTickedOrCanceledAnswersNil() async throws {
        let (h, _, _) = host()
        let defaults = UserDefaults(suiteName: "sq-anon-\(UUID().uuidString)")!
        let t = Task { @MainActor in await h.askAnonymize(clipName: "a", people: Array(people().prefix(1)), defaults: defaults) }
        let d = try #require(await waitForDialog(h))
        #expect(d.form?.rows[2] == .text("One person found on this frame:"))
        d.form?.set("person0", .bool(false))
        d.press(.first)
        #expect(await t.value == nil)
        #expect(AnonymizeChoice.remembered(defaults) == (.face, .mosaic))
    }

    @Test func anonymizeChecksListCriticalFirstAndGoToFirstSeeks() async throws {
        let (h, _, _) = host()
        let lines = [AnonymizeCheckLine(time: Time(9, 1), text: "late", critical: false), AnonymizeCheckLine(time: Time(5, 1), text: "risk", critical: true),
                     AnonymizeCheckLine(time: Time(1, 1), text: "early", critical: false)]
        let t = Task { @MainActor in await h.askAnonymizeChecks(lines: lines) }
        let d = try #require(await waitForDialog(h))
        #expect(d.messageText == "Anonymize: Check These Frames" && d.width == 480)
        #expect(d.informativeText == AnonymizeText.checksText(lines) && d.informativeText.contains("may be visible"))
        #expect(d.form?.rows == [.text("risk"), .text("early"), .text("late")])
        d.press(.first)
        #expect(await t.value == Time(5, 1))
    }

    @Test func anonymizeCommandUsesTheHostAndIsEnabledWithAClip() async throws {
        let (h, a, _) = host()
        var lines: [String] = []
        h.onStatus = { lines.append($0) }
        h.session.select(clips: [a.id], captions: [])
        _ = h.execute(.anonymize)
        #expect(lines.last == "Anonymize needs the people finder, which this build does not have.")
        var ran = 0
        h.runAnonymize = { ran += 1 }
        #expect(h.execute(.anonymize))
        #expect(ran == 1)
    }
}
