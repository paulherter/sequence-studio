import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
import SQExport
@testable import SQDrawShell

@MainActor
final class ExportPicker: ShellFilePicker {
    var exportURL: URL?
    var file: URL?
    var asked: [(name: String, ext: String)] = []
    func chooseProject() async -> URL? { nil }
    func chooseSaveLocation(suggestedName: String, prompt: String) async -> URL? { nil }
    func chooseMedia() async -> [URL] { [] }
    func chooseFile(prompt: String, directory: URL?) async -> URL? { file }
    func chooseExportLocation(suggestedName: String, fileExtension: String, prompt: String) async -> URL? {
        asked.append((suggestedName, fileExtension)); return exportURL
    }
}

/// The Mac dialogs translated to shell forms (`ShellSequenceDialogs`, `ShellClipDialogs`, `ShellInterchange`).
@MainActor
@Suite(.serialized) struct ShellDialogCommandsTests {
    static let defaults: UserDefaults = {
        let d = UserDefaults(suiteName: "sq-shell-dialogs-\(UUID().uuidString)")!
        return d
    }()

    /// One 4 s video clip at 0 on V1 of a 25 fps sequence.
    func host() -> (ShellHost, Clip) {
        let media = MediaRef(name: "a.mov", path: "/a.mov", fingerprint: MediaFingerprint(size: 3), duration: Time(10, 1),
                             info: MediaInfo(duration: Time(10, 1), audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")))
        let clip = Clip(name: "a", media: media.id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        var v = Track(kind: .video)
        try! v.overwrite(clip)
        let tl = Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [v, Track(kind: .audio)])
        let s = ShellRecoveryTests.session(Project(name: "P", media: [media], timelines: [tl]))
        let h = ShellHost(session: s, map: .premiereDefault)
        h.startDefaults = Self.defaults
        return (h, clip)
    }

    func waitForDialog(_ h: ShellHost) async -> ShellDialog? {
        for _ in 0..<400 {
            if let d = h.dialog { return d }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func waitUntil(_ f: () -> Bool) async {
        for _ in 0..<400 where !f() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func sequenceSettingsPresetFillsTheFieldsAndBadSizesKeepTheDialogOpen() throws {
        let settings = SequenceSettings(name: "Main", format: SequenceFormat(width: 1000, height: 700, frameDuration: Time(1, 25)))
        let s = ShellSequenceSettings.make(settings: settings, isNew: true)
        #expect(s.form.index("preset") == 0)                                  // Custom
        let n = try #require(SequenceFormatPresets.named.first)
        s.form.choose(row: 2, option: 1)
        #expect(s.form.number("width") == Double(n.format.width) && s.form.number("height") == Double(n.format.height))
        let r = try #require(ShellSequenceSettings.answer(s, settings: settings, projectDucking: nil))
        #expect(r.settings.format.width == n.format.width && r.settings.deliveryTarget == n.deliveryTarget)
        s.form.set("width", .text("abc"))
        #expect(ShellSequenceSettings.answer(s, settings: settings, projectDucking: nil) == nil)
    }

    @Test func newSequenceAddsOneAndSettingsChangeTheSize() async throws {
        let (h, _) = host()
        #expect(h.execute(.newSequence))
        var d = try #require(await waitForDialog(h))
        d.press(.first)
        await waitUntil { h.session.project.timelines.count == 2 }
        #expect(h.session.project.timelines.count == 2)
        await waitUntil { h.dialog == nil }
        #expect(h.execute(.sequenceSettings))
        d = try #require(await waitForDialog(h))
        d.form?.set("width", .text("1280"))
        d.form?.set("height", .text("720"))
        d.press(.first)
        await waitUntil { h.session.activeTimeline?.format.width == 1280 }
        #expect(h.session.activeTimeline?.format.height == 720)
    }

    @Test func speedHalvesAndTheDurationFollows() async throws {
        let (h, clip) = host()
        h.session.select(clips: [clip.id], captions: [])
        #expect(h.execute(.speedDuration))
        let d = try #require(await waitForDialog(h))
        let form = try #require(d.form)
        form.set("speed", .number(50))
        form.onChange?("speed", .number(50))        // what a committed number field sends
        #expect(form.number("duration") == 200)                 // 8 s at 25 fps
        d.press(.first)
        await waitUntil { h.session.activeTimeline?.tracks[0].clips.first?.duration == Time(8, 1) }
        #expect(h.session.activeTimeline?.tracks[0].clips.first?.duration == Time(8, 1))
    }

    @Test func goToTimecodeMovesThePlayheadAndRejectsText() async throws {
        let (h, _) = host()
        var status: [String] = []
        h.onStatus = { status.append($0) }
        #expect(h.execute(.goToTimecode))
        var d = try #require(await waitForDialog(h))
        d.form?.set("tc", .text("00:00:02:00"))
        d.press(.first)
        await waitUntil { h.session.playhead == Time(2, 1) }
        #expect(h.session.playhead == Time(2, 1))
        await waitUntil { h.dialog == nil }
        _ = h.execute(.goToTimecode)
        d = try #require(await waitForDialog(h))
        d.form?.set("tc", .text("soon"))
        d.press(.first)
        await waitUntil { status.contains("That is not a timecode.") }
        #expect(status.contains("That is not a timecode."))
    }

    /// A host with the monitor's timecode field opens that instead of the dialog (the Mac `focusTimecodeField`).
    @Test func goToTimecodeOpensTheMonitorFieldWhenTheHostHasOne() async throws {
        let (h, _) = host()
        var focused = 0
        h.focusTimecode = { focused += 1; return true }
        #expect(h.execute(.goToTimecode))
        await waitUntil { focused == 1 }
        #expect(focused == 1)
        #expect(h.dialog == nil)
    }

    /// Edit > Find (the Mac `showFind`): the dialog, then the matches selected in the Project panel with their bins open.
    @Test func findSelectsTheMatchesAndOpensTheirBins() async throws {
        let beach = MediaRef(name: "beach.mov", path: "/beach.mov", fingerprint: MediaFingerprint(size: 3), duration: Time(2, 1))
        let other = MediaRef(name: "city.mov", path: "/city.mov", fingerprint: MediaFingerprint(size: 3), duration: Time(2, 1))
        var p = Project(name: "P", media: [beach, other])
        let footage = Bin(name: "Footage", children: [.media(beach.id)])
        p.rootBin.children = [.bin(footage), .media(other.id)]
        let s = ShellRecoveryTests.session(p)
        let h = ShellHost(session: s, map: .premiereDefault)
        h.startDefaults = Self.defaults
        h.projectModel = ProjectPanelModel(project: s.project, probe: ShellImportTests.fakeProbe, onEdit: { _, _ in })
        let list = ProjectListView(host: h, defaults: UserDefaults(suiteName: "sq.test.find.\(UUID())")!)
        var status: [String] = []
        h.onStatus = { status.append($0) }
        #expect(h.execute(.find))
        await waitUntil { h.dialog != nil }
        #expect(h.dialog?.messageText == "Find")
        h.dialog?.form?.set("text", .text("beach"))
        h.dialog?.press(.first)
        await waitUntil { !status.isEmpty }
        #expect(list.selection == [.media(beach.id)])
        #expect(list.expanded.contains(footage.id))
        #expect(status.last == "1 match.")
        h.selectFound(.init(text: "nothing here"))
        #expect(status.last == "No match.")
        h.selectFound(.init())
        #expect(status.last == "Nothing to find.")
    }

    /// The Mac `executeSourceFlowCommand(.find)`: with the timeline focused Find opens the caption search when the host
    /// has one to show; without captions (or focus elsewhere) the Project Find dialog opens.
    @Test func findWithTheTimelineFocusedOpensTheCaptionSearch() async {
        let (h, _) = host()
        var asked = 0
        var answer = true
        h.showCaptionSearch = { asked += 1; return answer }
        h.dock.focused = .timeline
        #expect(h.execute(.find))
        #expect(asked == 1 && h.dialog == nil)
        answer = false
        #expect(h.execute(.find))
        await waitUntil { h.dialog != nil }
        #expect(asked == 2 && h.dialog?.messageText == "Find")
        h.dialog?.press(.second)
        await waitUntil { h.dialog == nil }
        h.dock.focused = .project
        #expect(h.execute(.find))
        #expect(asked == 2)
        await waitUntil { h.dialog != nil }
    }

    @Test func edlExportWritesTheFileWithTheSequenceName() async throws {
        let (h, _) = host()
        let picker = ExportPicker()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-edl-\(UUID().uuidString).edl")
        picker.exportURL = url
        h.files = picker
        var status: [String] = []
        h.onStatus = { status.append($0) }
        await h.exportInterchange(.exportEDL)
        #expect(picker.asked.first?.name == "Main.edl" && picker.asked.first?.ext == "edl")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("TITLE: Main"))
        #expect(status.last?.hasPrefix("Exported ") == true)
    }

    @Test func fcpxmlRemembersVersionAndTarget() async throws {
        let (h, _) = host()
        Self.defaults.removeObject(forKey: ShellHost.fcpxmlVersionKey)
        let flow = Task { await h.askFCPXMLOptions() }
        let d = try #require(await waitForDialog(h))
        #expect(d.form?.index("version") == 0 && d.form?.index("target") == 0)        // 1.8 for DaVinci Resolve
        d.form?.choose(row: 0, option: 2)
        d.form?.choose(row: 1, option: 1)
        d.press(.first)
        let r = await flow.value
        #expect(r?.0 == .v1_13 && r?.1 == .finalCut)
        #expect(Self.defaults.string(forKey: ShellHost.fcpxmlVersionKey) == "1.13")
    }

    @Test func otioScopeIsAskedOnlyForSeveralSequences() async throws {
        let (h, _) = host()
        #expect(await h.askOTIOScope() == .activeSequence)
    }

    @Test func interchangeMediaIsFoundNextToTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-ix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent("clip.mov"))
        let r = ShellHost.locateInterchangeMedia(["/gone/clip.mov", "C:\\gone\\clip.mov", "/gone/other.mov"],
                                                 nextTo: dir.appendingPathComponent("cut.edl"), searchFolders: [])
        #expect(r["/gone/clip.mov"] == dir.appendingPathComponent("clip.mov").path)
        #expect(r["C:\\gone\\clip.mov"] == dir.appendingPathComponent("clip.mov").path)
        #expect(r["/gone/other.mov"] == nil)
    }

    @Test func savedTemplatesRenameAndDelete() async throws {
        let (h, _) = host()
        h.templateFolder = TemplateFolder(url: FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-tpl-\(UUID().uuidString)"))
        let t = ProjectTemplate(id: "user-a", name: "Old", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)))
        try h.templateFolder.save(t)
        let flow = Task { await h.renameTemplate(t) }
        let d = try #require(await waitForDialog(h))
        d.form?.set("name", .text("Reels"))
        d.press(.first)
        await flow.value
        #expect(h.templateFolder.load().map(\.name) == ["Reels"])
        h.deleteTemplate(t)
        #expect(h.templateFolder.load().isEmpty)
    }

    @Test func reconnectFromOneFoundFileShowsTheChecklistAndAppliesTheTickedRows() async throws {
        let locate = ShellLocateTests()
        let (h, picker, media) = try locate.host()
        // Two folders deep, so the scan's parent level is the test folder, not the whole temp folder.
        let deep = locate.dir.appendingPathComponent("card/clips")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for n in ["a.wav", "b.wav"] { try FileManager.default.moveItem(at: locate.dir.appendingPathComponent(n), to: deep.appendingPathComponent(n)) }
        picker.file = deep.appendingPathComponent("a.wav")
        var status: [String] = []
        h.onStatus = { status.append($0) }
        let flow = Task { await h.reconnectFromFoundFile(volumes: []) }
        var dialog: ShellDialog?
        for _ in 0..<2000 where dialog == nil { dialog = h.dialog; try? await Task.sleep(for: .milliseconds(5)) }
        let d = try #require(dialog, "status: \(status)")
        #expect(d.messageText == "Found 2 of 2 missing files")
        let form = try #require(d.form)
        form.set("p0", .bool(true)); form.set("p1", .bool(false))
        d.press(.first)
        #expect(await flow.value == 1)
        #expect(h.session.missingMedia.count == 1)
        #expect(media.count == 2)
    }

    @Test func checkCutsMarksFindingsAndThePlatformRerunsAndIsRemembered() async throws {
        let (h, _) = host()
        Self.defaults.removeObject(forKey: ShellHost.cutCheckPlatformKey)
        #expect(h.execute(.checkCuts))
        let d = try #require(await waitForDialog(h))
        let form = try #require(d.form)
        #expect(form.index("platform") == 0)
        guard case .segmented(_, "Safe Zone", _, _, _)? = form.rows.first else { Issue.record("no Safe Zone segments"); return }
        guard case .chart(let summary, "Shot length", let bars)? = form.rows.last else { Issue.record("no shot-length chart"); return }
        #expect(summary.hasPrefix("1 shots"))
        #expect(bars.reduce(0) { $0 + $1.count } == 1)    // the Mac histogram: one bar per bucket, the one shot counted
        form.choose(row: 0, option: 2)
        guard case .chart(_, _, let rerun)? = form.rows.last else { Issue.record("the rerun dropped the chart"); return }
        #expect(rerun.count == bars.count)
        #expect(Self.defaults.string(forKey: ShellHost.cutCheckPlatformKey) == CutCheckPlatform.shorts.rawValue)
        d.press(.first)
        await waitUntil { h.dialog == nil }
        #expect(h.dialog == nil)
    }

    /// File > Project Notes: the Mac `ProjectNotesDialog` box (180 pt, caret in it); OK writes the lines as one undo step.
    @Test func projectNotesIsAMultiLineBoxWithTheCaret() async throws {
        let (h, _) = host()
        #expect(h.execute(.projectNotes))
        let d = try #require(await waitForDialog(h))
        let form = try #require(d.form)
        guard case .textBox("notes", _, 180)? = form.rows.first else { Issue.record("no notes box"); return }
        #expect(form.isEditing)
        form.set("notes", .text("one\ntwo"))
        d.press(.first)
        await waitUntil { h.session.project.notes == "one\ntwo" }
        #expect(h.session.project.notes == "one\ntwo")
    }

    /// The Mac `PunchInCutsSheetView`: Pattern segments, Ease popup, the four zoom levels (Zoom label on the first, 115 % ticked).
    @Test func punchInCutsIsTheMacSheetAndAppliesTheTickedLevels() async throws {
        let media = MediaRef(name: "a.mov", path: "/a.mov", fingerprint: MediaFingerprint(size: 3), duration: Time(10, 1),
                             info: MediaInfo(duration: Time(10, 1), audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")))
        let a = Clip(name: "a", media: media.id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let b = Clip(name: "b", media: media.id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: Time(4, 1))
        var v = Track(kind: .video)
        try v.overwrite(a)
        try v.overwrite(b)
        let tl = Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [v, Track(kind: .audio)])
        let h = ShellHost(session: ShellRecoveryTests.session(Project(name: "P", media: [media], timelines: [tl])), map: .premiereDefault)
        h.startDefaults = Self.defaults
        h.session.select(clips: [a.id, b.id], captions: [])
        let defaults = UserDefaults(suiteName: "sq-punch-\(UUID().uuidString)")!
        let t = Task { @MainActor in await h.punchInCuts(defaults: defaults) }
        let d = try #require(await waitForDialog(h))
        #expect(d.messageText == "Punch In Cuts" && d.width == 360)
        let f = try #require(d.form)
        #expect(f.rows.count == 6)
        #expect(f.checkLabels["zoom0"] == "Zoom" && f.checkLabels["zoom1"] == "")
        #expect(f.bool("zoom2") == true && f.bool("zoom0") == false)
        f.set("zoom3", .bool(true))
        d.press(.first)
        await t.value
        #expect(defaults.array(forKey: "sq.punchInCuts.scales") as? [Double] == [115, 126.5])
        #expect(defaults.string(forKey: "sq.punchInCuts.pattern") == "alternate")
    }

    @Test func punchInCutsNeedsTwoShots() async {
        let (h, _) = host()
        var lines: [String] = []
        h.onStatus = { lines.append($0) }
        await h.punchInCuts(defaults: UserDefaults(suiteName: "sq-punch-\(UUID().uuidString)")!)
        #expect(lines.last == "Select two or more video clips, or target a video track with several shots.")
    }
}
