import Foundation
import Testing
import SQCore
import SQUIKit
import SQEditorSession
import SQPremiereImport
@testable import SQDrawShell

@MainActor
private final class FolderPicker: ShellFilePicker {
    var folder: URL?
    var save: URL?
    var suggested: String?
    var asked = 0
    func chooseProject() async -> URL? { nil }
    func chooseSaveLocation(suggestedName: String, prompt: String) async -> URL? { suggested = suggestedName; return save }
    func chooseMedia() async -> [URL] { [] }
    func chooseFolder(prompt: String) async -> URL? { asked += 1; return folder }
}

/// Sequence > Change Format / Duplicate as Format / templates, Clip > Pixel Aspect, File > Project > Reconnect Media and
/// Import Checklist in the portable shell.
@MainActor
@Suite(.serialized) struct ShellFormatTests {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-format-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func host(_ p: Project? = nil) -> ShellHost {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)),
                          tracks: [Track(kind: .video, clips: [clip]), Track(kind: .audio)])
        let h = ShellHost(session: EditorSession(project: p ?? Project(name: "P", timelines: [tl])), map: .premiereDefault)
        h.size = CGSize(width: 1000, height: 700)
        h.templateFolder = TemplateFolder(url: Self.dir.appendingPathComponent("Templates-\(UUID().uuidString)"))
        return h
    }

    /// Runs `flow` and answers each dialog it shows with the next response.
    func run(_ h: ShellHost, _ flow: @escaping @MainActor () async -> Void, answers: [ShellDialog.Response],
             edit: (ShellDialog) -> Void = { _ in }) async {
        let t = Task { @MainActor in await flow() }
        for r in answers {
            for _ in 0..<2000 where h.dialog == nil { await Task.yield() }
            guard let d = h.dialog else { break }
            edit(d)
            d.press(r)
            for _ in 0..<50 { await Task.yield() }
        }
        await t.value
    }

    @Test func formStartsOnTheFirstOtherShapeAndPresetsFillTheSize() throws {
        let f = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25))
        let form = ShellChangeFormat.form(current: f, hasSelection: false, name: nil)
        #expect(form.number("width") == 1080)
        #expect(form.number("height") == 1920)
        // One "Frame Size" row (no Width / Height rows, no note text), as on the Mac.
        #expect(form.rows.contains { if case .size(let l, _, _) = $0 { l == "Frame Size" } else { false } })
        #expect(!form.rows.contains { if case .text = $0 { true } else { false } })
        #expect(form.plainSize == ["width"] && form.controlWidths["width"] == 117)
        let square = try #require(SequenceConform.aspectPresets.firstIndex { $0.name == "1:1" })
        form.onChange?("format", .index(square))
        #expect(form.number("width") == 1080 && form.number("height") == 1080)
        form.set("width", .number(1234))
        form.onChange?("width", .number(1234))
        #expect(form.index("format") == SequenceConform.aspectPresets.count)   // Custom
        let a = try #require(ShellChangeFormat.answer(form, current: f))
        #expect(a.format.width == 1234 && a.mode == .fill && a.selectedMode == nil)
        form.set("width", .number(0))
        #expect(ShellChangeFormat.answer(form, current: f) == nil)
    }

    /// The Mac `ChangeFormatDialog` row: two 117 pt fields filling the control column, no swap button.
    @Test func frameSizeRowFillsTheControlColumnWithoutSwap() throws {
        let form = ShellChangeFormat.form(current: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)),
                                          hasSelection: false, name: nil)
        let d = ShellDialog("Change Format")
        d.width = ShellChangeFormat.sheetWidth
        d.addButton("Change")
        d.form = form
        d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 900), measure: TextMeasure(atlas: nil, scale: 1))
        let w = try #require(form.scrubFrames["width"]), h = try #require(form.scrubFrames["height"])
        #expect(w.width == 117 && h.width == 117)
        #expect(w.minX == form.controlFrames[0].minX && h.maxX == form.controlFrames[0].maxX)
        let before = (form.number("width"), form.number("height"))
        _ = form.mouseDown(CGPoint(x: (w.maxX + h.minX) / 2, y: w.midY))   // the "×": no swap
        #expect(form.number("width") == before.0 && form.number("height") == before.1)
    }

    @Test func changeFormatReframesTheActiveSequence() async {
        let h = host()
        await run(h, { await h.changeFormat(duplicate: false) }, answers: [.first])
        #expect(h.session.activeTimeline?.format.width == 1080)
        #expect(h.session.activeTimeline?.format.height == 1920)
        #expect(h.session.undoName == "Change Format")
    }

    @Test func duplicateAsFormatOpensTheCopy() async {
        let h = host()
        let original = h.session.activeTimelineID
        await run(h, { await h.changeFormat(duplicate: true) }, answers: [.first])
        #expect(h.session.project.timelines.count == 2)
        #expect(h.session.activeTimelineID != original)
        #expect(h.session.activeTimeline?.format.width == 1080)
    }

    @Test func cancelChangesNothing() async {
        let h = host()
        await run(h, { await h.changeFormat(duplicate: false) }, answers: [.second])
        #expect(h.session.activeTimeline?.format.width == 1920)
        #expect(!h.session.canUndo)
    }

    @Test func savedTemplateIsOfferedForNewSequences() async throws {
        let h = host()
        // The Mac accessories: unlabeled controls from the card's left edge, 260 pt (save) and 300 pt (new), 440 pt cards.
        func frames(_ d: ShellDialog) -> [CGRect] {
            d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 900), measure: TextMeasure(atlas: nil, scale: 1))
            return d.form?.controlFrames ?? []
        }
        var saveFrames: [CGRect] = [], newFrames: [CGRect] = [], widths: [CGFloat] = []
        await run(h, { await h.saveSequenceAsTemplate() }, answers: [.first]) { d in
            saveFrames = frames(d); widths.append(d.width)
            d.form?.set("name", .text("Reel"))
        }
        #expect(saveFrames.map(\.width) == [260])
        #expect(h.templateFolder.load().map(\.name) == ["Reel"])
        #expect(h.allTemplates.last?.name == "Reel")
        let count = h.session.project.timelines.count
        await run(h, { await h.newSequenceFromTemplate() }, answers: [.first]) { d in
            newFrames = frames(d); widths.append(d.width)
            d.form?.set("template", .index(h.allTemplates.count - 1))
            d.form?.set("name", .text("From Reel"))
        }
        #expect(h.session.project.timelines.count == count + 1)
        #expect(h.session.project.timelines.last?.name == "From Reel")
        #expect(newFrames.map(\.width) == [300, 300] && newFrames[0].minX == newFrames[1].minX && newFrames[0].minX == saveFrames[0].minX)
        #expect(widths == [440, 440])
    }

    @Test func pixelAspectRowsFollowTheProjectSelection() throws {
        let info = MediaInfo(duration: Time(2, 1), video: VideoTrackInfo(width: 1440, height: 1080, codec: "avc1", bitDepth: 8,
                                                                         chroma: "4:2:0", nominalFrameDuration: Time(1, 25),
                                                                         isVariableFrameRate: false))
        let m = MediaRef(name: "hdv", path: "/x/hdv.m2t", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1), info: info)
        var p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [Track(kind: .video)])])
        p.add(m)
        let h = host(p)
        var s = ShellMenuState()
        h.fillProjectState(&s)
        #expect(s.pixelAspect == nil)                     // nothing selected: rows disabled
        h.projectSelection = { [.media(m.id)] }
        h.fillProjectState(&s)
        let rows = try #require(s.pixelAspect)
        #expect(rows.rows.first?.checked == true)         // From File
        #expect(!rows.customChecked)
        h.perform(.pixelAspect(PixelAspect(4, 3)))
        #expect(h.session.project.media(m.id)?.info?.video?.pixelAspectOverride == PixelAspect(4, 3))
        h.fillProjectState(&s)
        #expect(s.pixelAspect?.rows.first { $0.aspect == PixelAspect(4, 3) }?.checked == true)
    }

    @Test func customPixelAspectTakesATypedRatio() async throws {
        let info = MediaInfo(duration: Time(2, 1), video: VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8,
                                                                         chroma: "4:2:0", nominalFrameDuration: Time(1, 25),
                                                                         isVariableFrameRate: false))
        let m = MediaRef(name: "v", path: "/x/v.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1), info: info)
        var p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [Track(kind: .video)])])
        p.add(m)
        let h = host(p)
        h.projectSelection = { [.media(m.id)] }
        await run(h, { await h.customSelectionPixelAspect() }, answers: [.first]) { d in d.form?.set("ratio", .text("2")) }
        #expect(h.session.project.media(m.id)?.info?.video?.pixelAspectOverride == PixelAspect(2, 1))
        var s = ShellMenuState()
        h.fillProjectState(&s)
        #expect(s.pixelAspect?.customChecked == false)    // 2:1 is a named lens squeeze
        await run(h, { await h.customSelectionPixelAspect() }, answers: [.first]) { d in d.form?.set("ratio", .text("9")) }
        #expect(h.session.project.media(m.id)?.info?.video?.pixelAspectOverride == PixelAspect(2, 1))   // out of range: kept
    }

    @Test func reconnectMediaSearchesTheChosenFolder() async throws {
        let folder = Self.dir.appendingPathComponent("found-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("sub/shot.mov"))
        let m = MediaRef(name: "shot", path: "/nowhere-\(UUID().uuidString)/shot.mov", fingerprint: MediaFingerprint(size: 3),
                         duration: Time(2, 1))
        var p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [Track(kind: .video)])])
        p.add(m)
        let h = host(p)
        let picker = FolderPicker()
        picker.folder = folder
        h.files = picker
        var s = ShellMenuState()
        h.fillProjectState(&s)
        #expect(s.canRelink)
        var title = ""
        await run(h, { await h.relinkMedia() }, answers: [.first]) { d in title = d.messageText }
        #expect(title == "1 media file is offline")
        #expect(picker.asked == 1)
        #expect(h.session.missingMedia.isEmpty)
        #expect(UserDefaults.standard.stringArray(forKey: ShellHost.relinkFoldersKey)?.first == folder.path)
    }

    @Test func relinkTextNamesWhatIsStillMissing() {
        let m = MediaRef(name: "a", path: "C:\\Footage\\a.mov", fingerprint: MediaFingerprint(size: 3), duration: Time(2, 1))
        let start = ShellHost.relinkText(missing: [m, m], total: 2, searched: 0)
        #expect(start.title == "2 media files are offline")
        #expect(start.detail.hasPrefix("Not found: a.mov, a.mov."))
        let later = ShellHost.relinkText(missing: [m], total: 2, searched: 1)
        #expect(later.title == "1 of 2 found")
        #expect(later.detail.hasPrefix("Still missing: a.mov."))
    }

    @Test func importChecklistShowsTheAffectedClips() async throws {
        let h = host()
        var s = ShellMenuState()
        h.fillProjectState(&s)
        #expect(!s.hasImportChecklist)
        let tl = try #require(h.session.activeTimeline)
        let clip = try #require(tl.tracks.first?.clips.first)
        var report = PRImportReport()
        report.note("ADBE Gaussian Blur", .approximated, "Blur radius scaled")
        report.attach("ADBE Gaussian Blur", .approximated, to: PRImportReport.Location(timeline: tl.id, clip: clip.id))
        h.importChecklist = ShellImportChecklist(report: report, project: h.session.project, fileName: "Edit.prproj")
        h.fillProjectState(&s)
        #expect(s.hasImportChecklist)
        h.session.select(clips: [])
        // The Mac sheet: dot rows, Show on the row that can act, Save Report… and Done (no Show / Close buttons).
        await run(h, { await h.showImportChecklist() }, answers: [.first]) { d in
            #expect(d.model.buttons.map(\.title) == ["Done", "Save Report…"])
            guard let content = d.content as? ShellImportReportContent else { Issue.record("no report rows"); return }
            #expect(content.rows.map(\.tone) == [.green, .yellow])
            #expect(content.rows.map(\.action) == [nil, "Show"])
            #expect(content.rows[1].head.hasPrefix("1x  "))
            content.onAction?(content.rows[1].item!)
        }
        #expect(h.session.selection == [clip.id])
    }

    @Test func saveReportKeepsTheChecklistOpenAndWritesTheSummary() async throws {
        let h = host()
        let picker = FolderPicker()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("sq-report-\(UUID().uuidString).txt")
        picker.save = out
        defer { try? FileManager.default.removeItem(at: out) }
        h.files = picker
        var report = PRImportReport()
        report.note("Lumetri Color", .approximated, "Simplified")
        h.importChecklist = ShellImportChecklist(report: report, project: h.session.project, fileName: "Edit.prproj")
        var kept = false
        await run(h, { await h.showImportChecklist() }, answers: [.first]) { d in
            d.press(.second)                       // Save Report…: the card stays
            kept = !d.finished
        }
        for _ in 0..<500 where picker.suggested == nil { await Task.yield() }
        #expect(kept)
        #expect(picker.suggested == "Edit.prproj import report.txt")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: out.path) { await Task.yield() }
        #expect((try? String(contentsOf: out, encoding: .utf8))?.contains("Lumetri Color") == true)
    }

    @Test func offlineDialogHasPipInsteadOfAFoundFileButton() async throws {
        let m = MediaRef(name: "shot", path: "/nowhere-\(UUID().uuidString)/shot.mov", fingerprint: MediaFingerprint(size: 3),
                         duration: Time(2, 1))
        var p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [Track(kind: .video)])])
        p.add(m)
        let h = host(p)
        let picker = FolderPicker()
        h.files = picker
        defer { withExtendedLifetime(picker) {} }
        var s = ShellMenuState()
        h.fillProjectState(&s)
        var mascot = CGRect.zero
        await run(h, { await h.relinkMedia() }, answers: [.second]) { d in
            #expect(!d.model.buttons.contains { $0.title.hasPrefix("Found") })
            d.layout(in: CGRect(x: 0, y: 0, width: 1440, height: 900), measure: TextMeasure(atlas: nil, scale: 1))
            mascot = d.mascotFrame
            #expect(mascot.minX == d.card.minX + 20 && mascot.width == 26)
            #expect(mascot.midY > d.card.maxY - 68 && mascot.midY < d.card.maxY)
        }
        #expect(mascot != .zero)
    }
}
