import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// New Project form, checkpoints, autosave versions and the recovery prompt (the Mac `AppController+Files` flows).
@MainActor
@Suite(.serialized) struct ShellRecoveryTests {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-recovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// A session whose autosaves live in the test folder: the real store may hold another run's unclean session (the
    /// recovery question would then wait for an answer).
    static func session(_ project: Project = ShellCommandsTests.session().project) -> EditorSession {
        EditorSession(project: project, autosaveStore: AutosaveStore(base: dir.appendingPathComponent("autosave-\(UUID().uuidString)")))
    }

    /// Waits until the host shows a dialog (the flow runs in its own task).
    func waitForDialog(_ h: ShellHost) async -> ShellDialog? {
        for _ in 0..<200 {
            if let d = h.dialog { return d }
            await Task.yield()
        }
        return nil
    }

    @Test func newProjectFormResolvesTheFormatLikeTheMacSheet() throws {
        let templates = ProjectTemplate.builtIn
        let form = ShellNewProject.form(templates: templates, location: Self.dir)
        form.set("name", .text("  Trip  "))
        form.choose(row: 2, option: 4)         // "HD 1080p" fills W and H
        form.set("rate", .index(2))            // 25 fps
        form.set("audio", .index(1))           // 44.1 kHz
        form.set("timeline", .index(1))        // Fast Cut
        form.set("outside", .index(3))         // Leave in place
        let a = try #require(ShellNewProject.answer(form, templates: templates))
        #expect(a.name == "Trip")
        #expect(a.template.format.width == 1920 && a.template.format.height == 1080)
        #expect(a.template.format.frameDuration == Time(1, 25))
        #expect(a.template.format.audioSampleRate == 44_100)
        #expect(a.editMode == .magnetic && a.mode == .leave)
        #expect(a.location.path == Self.dir.path)
    }

    @Test func newProjectSizeRowSwapsAndTheHintsAndFooterFollowLikeTheMacSheet() throws {
        let templates = ProjectTemplate.builtIn
        let form = ShellNewProject.form(templates: templates, location: Self.dir, fastCut: true)
        let d = ShellDialog("New project")
        d.width = ShellNewProject.sheetWidth
        d.addButton("Create")
        d.form = form
        d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 900), measure: TextMeasure(atlas: nil, scale: 1))
        #expect(form.controlFrames[1].width == 260)                       // the 260 pt popups
        #expect(try #require(form.scrubFrames["width"]).width == 84)
        let swap = form.swapFrame(3)
        #expect(swap.minX == form.scrubFrames["width"]!.maxX + 8)         // W ⇆ H: the swap sits between the fields
        form.choose(row: 2, option: 0)                                    // Vertical video
        #expect(form.number("width") == 1080 && form.number("height") == 1920)
        #expect(form.hints["width"] == "9:16 · px")
        _ = form.mouseDown(CGPoint(x: swap.midX, y: swap.midY)); form.mouseUp()
        #expect(form.number("width") == 1920 && form.number("height") == 1080)
        #expect(form.index("size") == 4)                                  // the swapped size is HD 1080p
        form.choose(row: 1, option: 1)
        #expect(form.hints["template"] == templates[1].summary)
        #expect(form.index("timeline") == 1)
        let sum = ShellNewProject.summary(form, templates: templates)
        #expect(sum.line2.hasSuffix("Stereo · Fast Cut timeline"))
        #expect(sum.line1.hasPrefix("1920 × 1080 · ") && sum.line1.hasSuffix(" fps"))
        #expect(abs(sum.aspect - 16.0 / 9) < 0.001)
        let other = Self.dir.appendingPathComponent("Elsewhere")
        ShellNewProject.setLocation(form, other)
        #expect(try #require(ShellNewProject.answer(form, templates: templates)).location.path == other.path)
        var c = Canvas(width: 1200, height: 900, atlas: nil, scale: 1)
        d.draw(&c, theme: DrawTheme(), window: CGRect(x: 0, y: 0, width: 1200, height: 900))
    }

    /// The Mac `sizeItems` / `rateItems` / `templateItems`: group headers, the key column, the separator before Custom
    /// size, the aspect key in the closed box; the Location chip; the header close button and the footer band summary.
    @Test func newProjectPopupsChipCloseAndFooterAreTheMacSheets() throws {
        let templates = ProjectTemplate.builtIn
        let form = ShellNewProject.form(templates: templates, location: Self.dir)
        let d = ShellDialog("New project")
        d.width = ShellNewProject.sheetWidth
        d.addButton("Create")
        d.addButton("Cancel", role: .cancel)
        d.form = form
        d.closeButton = true
        var opened: [SQMenuItem] = []
        form.openPopup = { _, items, _ in opened = items }
        d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 900), measure: TextMeasure(atlas: nil, scale: 1))
        form.choose(row: 2, option: 0)                                    // Vertical video
        #expect(form.popupStyles["size"]?.boxKey == "9:16")
        _ = form.mouseDown(CGPoint(x: form.controlFrames[2].midX, y: form.controlFrames[2].midY))
        #expect(opened.first?.kind == .header && opened.first?.title == "Social")
        #expect(opened.first { $0.title == "Vertical video" }?.shortcut == "1080 × 1920")
        #expect(opened.first { $0.title == "Vertical video" }?.isChecked == true)
        let custom = try #require(opened.firstIndex { $0.title == "Custom size" })
        #expect(opened[custom - 1].kind == .separator)
        #expect(opened.filter { $0.kind == .header }.map(\.title) == ["Social", "Wide", "Cinema"])
        form.set("width", .number(1000)); form.set("height", .number(700)); form.onChange?("width", .number(1000))
        #expect(form.index("size") == ShellNewProject.sizes.count)       // Custom size
        #expect(form.popupStyles["size"]?.boxKey == "10:7")
        _ = form.mouseDown(CGPoint(x: form.controlFrames[4].midX, y: form.controlFrames[4].midY))
        #expect(opened.first { $0.title.hasPrefix("25") }?.shortcut == "PAL")
        _ = form.mouseDown(CGPoint(x: form.controlFrames[1].midX, y: form.controlFrames[1].midY))
        #expect(opened.first?.kind == .header && opened.first?.title == "Built in")
        // Location: the folder chip and the 92 pt Choose… button.
        let loc = try #require(form.rows.firstIndex { if case .buttons(id: "location", _, _, _, _) = $0 { true } else { false } })
        #expect(form.buttonFrames(loc).first?.width == 92)
        #expect(form.chips["location"]?.icon == .folder)
        // Close: 28 square, 12 from the right edge; a click answers Cancel.
        #expect(d.closeFrame.width == 28 && d.closeFrame.maxX == d.card.maxX - 12)
        var answer: ShellDialog.Response?
        d.completion = { answer = $0 }
        d.handle(.mouseDown(x: Float(d.closeFrame.midX), y: Float(d.closeFrame.midY), modifiers: []), scale: 1)
        d.handle(.mouseUp(x: Float(d.closeFrame.midX), y: Float(d.closeFrame.midY)), scale: 1)
        #expect(answer == d.model.response(forReturn: false))
        #expect(TextMeasure(atlas: nil, scale: 1).truncatedMiddle("~/Movies/Sequence Studio/Projects", width: 60, size: 12).contains("\u{2026}"))
    }

    /// `NewProjectSheet`: 56 head (title at 10, note at 31), form 20 below it, Create 104 with "⏎", Cancel 76.
    @Test func newProjectHeaderAndButtonsAreTheMacSheets() {
        let form = ShellNewProject.form(templates: ProjectTemplate.builtIn, location: Self.dir)
        let d = ShellDialog("New project", informative: "Settings can change later in Sequence Settings.")
        d.width = ShellNewProject.sheetWidth
        d.form = form
        d.headingFontSize = 15
        d.addButton("Create")
        d.addButton("Cancel", role: .cancel)
        d.buttonWidths = [0: 104, 1: 76]
        d.buttonHints = [0: "\u{23CE}"]
        d.layout(in: CGRect(x: 0, y: 0, width: 1200, height: 900), measure: TextMeasure(atlas: nil, scale: 1))
        #expect(d.formViewport.minY == d.card.minY + 76)
        #expect(d.buttonFrames[0]?.width == 104 && d.buttonFrames[1]?.width == 76)
        #expect(d.buttonFrames[0]?.maxX == d.card.maxX - 20)
        #expect(d.buttonTitle(0) == "Create  \u{23CE}" && d.buttonTitle(1) == "Cancel")
    }

    @Test func choosingATemplateTakesItsRate() {
        let templates = ProjectTemplate.builtIn
        let form = ShellNewProject.form(templates: templates, location: Self.dir)
        form.set("rate", .index(0))
        form.choose(row: 1, option: 1)
        let want = SequenceFormatPresets.frameRates.firstIndex { $0.frameDuration == templates[1].format.frameDuration }
        #expect(form.index("template") == 1)
        #expect(form.index("rate") == want)
    }

    @Test func createProjectMakesTheFolderAndNeverOverwrites() async throws {
        let h = ShellHost(session: Self.session(), map: .premiereDefault)
        h.spawn = { _ in }
        let form = ShellNewProject.form(templates: ProjectTemplate.builtIn, location: Self.dir)
        form.set("name", .text("Holiday"))
        form.set("timeline", .index(1))
        let a = try #require(ShellNewProject.answer(form, templates: ProjectTemplate.builtIn))
        await h.createProject(a)
        let file = Self.dir.appendingPathComponent("Holiday/Holiday.\(ProjectFile.fileExtension)")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent("Holiday/Files").path))
        #expect(h.session.fileURL?.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
        #expect(h.session.project.timelines.first?.editMode == .magnetic)
        #expect(h.recents.entries.contains { $0.path.hasSuffix("Holiday.\(ProjectFile.fileExtension)") })
        // Same name again: nothing is replaced.
        h.session.newProject()
        await h.createProject(a)
        #expect(h.session.fileURL == nil)
    }

    @Test func newProjectCommandAsksForTheForm() async {
        let h = ShellHost(session: Self.session(), map: .premiereDefault)
        h.newProjectLocation = Self.dir
        #expect(h.execute(.newProject))
        let d = await waitForDialog(h)
        #expect(d?.messageText == "New project")
        #expect(d?.form?.text("location") == Self.dir.path)
        d?.press(.second)
    }

    @Test func checkpointIsNamedAndRestoresFromTheMenu() async throws {
        let h = ShellHost(session: Self.session(), map: .premiereDefault)
        let t = Task { await h.saveCheckpoint() }
        let d = try #require(await waitForDialog(h))
        d.form?.set("name", .text("Rough cut"))
        d.press(.first)
        await t.value
        let v = try #require(h.session.autosaveVersions.first { $0.name == "Rough cut" })
        #expect(h.menuState().autosaveVersions.contains { $0.name == "Rough cut" && $0.path == v.url.path })
        h.session.perform("Rename") { $0.name = "Changed" }
        h.perform(.restoreAutosave(path: v.url.path))
        #expect(h.session.project.name == "P")
    }

    @Test func recoveryDialogUsesTheMacTexts() {
        let d = ShellHost.recoveryDialog(projectName: "Trip", date: Date())
        #expect(d.messageText == "Recover “Trip”?")
        #expect(d.informativeText.hasPrefix("Sequence Studio did not close cleanly."))
        #expect(d.model.buttons.map(\.title) == ["Recover", "Discard"])
    }

    @Test func noCrashMeansNoQuestion() async {
        let h = ShellHost(session: Self.session(EditorSession.makeUntitled()), map: .premiereDefault)
        let reports = CrashReportStore(directory: Self.dir.appendingPathComponent("reports"))
        await h.offerRecovery(reports: reports)
        #expect(h.dialog == nil)
    }
}

@MainActor
@Suite(.serialized) struct ShellPreferencesTests {
    @Test func pageRowsWriteBackIntoTheSettings() {
        var s = AppSettings.load(from: UserDefaults(suiteName: "sq.test.prefs.\(UUID().uuidString)")!)
        let f = ShellPreferences.form(.playback, s)
        f.set("preroll", .index(AppSettings.rollChoices.firstIndex(of: 5)!))
        f.set("scrubbing", .bool(true))
        f.set("quality", .index(2))   // 1/2
        ShellPreferences.apply(f, to: &s)
        #expect(s.prerollSeconds == 5 && s.audioScrubbing)
        #expect(!s.previewQualityAuto && s.defaultQuality == .half)
    }

    @Test func sideStoresRoundTripThroughTheirPages() {
        let defaults = UserDefaults(suiteName: "sq.test.prefs.\(UUID().uuidString)")!
        let s = AppSettings.load(from: defaults)
        var x = ShellPreferences.Extras.load(from: defaults)
        #expect(x.uiLanguage == "system" && x.transitions == .standard && x.roles == .standard)
        let general = ShellPreferences.form(.general, s, x)
        general.set("uiLanguage", .index(ShellPreferences.uiLanguages.firstIndex(of: "de")!))
        ShellPreferences.apply(general, to: &x)
        let editing = ShellPreferences.form(.editing, s, x)
        #expect(editing.number("videoTransition") == 0 && editing.number("audioTransition") == 1)
        editing.set("videoTransition", .number(12))
        editing.set("audioTransition", .number(0))   // out of range: ignored, as on the Mac
        ShellPreferences.apply(editing, to: &x)
        let audio = ShellPreferences.form(.audio, s, x)
        #expect(audio.number("offset.music") == 0.5 && audio.number("length.dialogue") == 0.1)
        audio.set("crossfade", .index(0))
        audio.set("length.music", .number(2.004))
        ShellPreferences.apply(audio, to: &x)
        x.save(to: defaults)
        let back = ShellPreferences.Extras.load(from: defaults)
        #expect(defaults.string(forKey: SQL10n.defaultsKey) == "de")
        #expect(back.transitions.videoFrames == 12 && back.transitions.audioSeconds == 1)
        #expect(back.roles.transitionSeconds[.music] == 2 && back.roles.crossfadeKind == TransitionKind.kinds(for: .audio)[0])
        x.uiLanguage = "system"
        x.save(to: defaults)
        #expect(defaults.string(forKey: SQL10n.defaultsKey) == nil)
    }

    /// The page list sits in a sidebar column left of the rows (the Mac Settings window); a click on a page answers
    /// the "page" change.
    @Test func theSidebarListsThePagesLeftOfTheRows() {
        let f = ShellPreferences.form(.audio, AppSettings.load(from: UserDefaults(suiteName: "sq.test.prefs.\(UUID().uuidString)")!))
        #expect(f.index("page") == ShellPreferences.Page.audio.rawValue)
        #expect(!f.rows.contains { if case .popup(id: "page", _, _, _) = $0 { true } else { false } })
        let h = f.layout(origin: CGPoint(x: 100, y: 50), width: 697)
        #expect(f.sidebarFrames.count == ShellPreferences.Page.allCases.count - 1)   // no Edit API: no Advanced page
        let side = f.sidebarFrames.reduce(CGRect.null) { $0.union($1) }
        #expect(side.minX >= 100 && side.maxX <= 100 + ShellForm.M.sidebarWidth && side.minY == 50)
        #expect(f.rowFrames.allSatisfy { $0.minX >= side.maxX })
        #expect(h >= side.maxY - 50)
        var picked: Int?
        f.onChange = { id, v in if id == "page", case .index(let i) = v { picked = i } }
        let editing = f.sidebarFrames[ShellPreferences.Page.editing.rawValue]
        #expect(f.mouseDown(CGPoint(x: editing.midX, y: editing.midY)))
        #expect(picked == ShellPreferences.Page.editing.rawValue && f.index("page") == picked)
    }

    @Test func changesSaveAtOnceAndTheSidebarSwapsRows() async throws {
        let defaults = UserDefaults(suiteName: "sq.test.prefs.\(UUID().uuidString)")!
        let h = ShellHost(session: ShellRecoveryTests.session(), map: .premiereDefault)
        var seen: AppSettings?
        h.onSettingsChanged = { seen = $0 }
        let t = Task { await h.showPreferences(defaults: defaults) }
        var d: ShellDialog?
        for _ in 0..<200 where d == nil { d = h.dialog; await Task.yield() }
        let dialog = try #require(d)
        #expect(dialog.form?.bool("recovery") != nil)
        dialog.form?.selectPage(ShellPreferences.Page.editing.rawValue)
        #expect(dialog.form?.index("newSequence") == 0)   // a segmented row like the Mac
        let row = try #require(dialog.form?.rows.firstIndex { if case .segmented(id: "newSequence", _, _, _, _) = $0 { true } else { false } })
        dialog.form?.choose(row: row, option: 1)
        #expect(seen?.newSequenceEditMode == .magnetic)
        #expect(AppSettings.load(from: defaults).newSequenceEditMode == .magnetic)
        dialog.press(.first)
        await t.value
    }
}
