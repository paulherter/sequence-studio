import Foundation
import SQCore
import SQEditorSession
import SQUIKit

/// File > New Project, translated from the Mac `NewProjectSheet` and `AppController.createProjectFolder` / `createProject`:
/// the same rows (Name, Template with its summary, Frame size with W ⇆ H and the aspect, Frame rate, Audio, the Timeline
/// segments, Outside files, Location with Choose…), 260 pt popups in a 600 pt sheet, the footer summary, the same format
/// resolution (`NewProjectInput.resolve`) and the same `<Name>/<Name>.sqproj` + `Files/` layout that never overwrites.
/// Templates: the built-in ones, then the saved ones (`ShellHost.templateFolder`), under "Built in" / "Yours". The header
/// has the close button, the footer band the aspect preview and the two summary lines; the size popup shows its aspect key
/// and lists "1080 × 1920" keys under Social / Wide / Cinema, the rate popup its uses ("Film", "PAL").
public struct ShellNewProjectAnswer: Equatable, Sendable {
    public var name: String
    public var template: ProjectTemplate
    /// nil = the default policy (the start screen's quick create).
    public var mode: OutsideMediaMode?
    public var location: URL
    /// nil = the template's own timeline mode.
    public var editMode: TimelineEditMode?
}

@MainActor
public enum ShellNewProject {
    /// `StartTemplatesModel.outsideChoices` (SQEditorUI, not a dependency here).
    static let outsideChoices: [(OutsideMediaMode, String)] = [
        (.ask, "Ask each time"), (.copy, "Copy into project"), (.move, "Move into project"), (.leave, "Leave in place"),
    ]
    /// `NewProjectSheet.baseAudioRates`.
    static let audioRates = [48_000, 44_100, 96_000]
    /// `NewProjectSheet.sizePresets` (group, name, width, height, key); "Custom size" follows them in the popup.
    static let sizes: [(group: String, name: String, width: Int, height: Int, key: String)] = [
        ("Social", "Vertical video", 1080, 1920, "9:16"), ("Social", "Portrait post", 1080, 1350, "4:5"),
        ("Social", "Square", 1080, 1080, "1:1"), ("Social", "Portrait 3:4", 1080, 1440, "3:4"),
        ("Wide", "HD 1080p", 1920, 1080, "16:9"), ("Wide", "4K UHD", 3840, 2160, "16:9"), ("Wide", "HD 720p", 1280, 720, "16:9"),
        ("Cinema", "Ultrawide 21:9", 2560, 1080, "21:9"), ("Cinema", "Scope 2.39:1", 4096, 1716, "2.39:1"),
        ("Cinema", "DCI 4K", 4096, 2160, "1.90:1"),
    ]
    /// `NewProjectSheet.rateNotes`: the use of each frame rate, the rate popup's key column.
    static let rateNotes = ["Film NTSC", "Film", "PAL", "NTSC", "Social", "", "", ""]
    /// Popup extras of the Mac menus (`templateItems`, `sizeItems`, `rateItems`).
    static func popupStyles(templates: [ProjectTemplate]) -> [String: ShellForm.PopupStyle] {
        var size = ShellForm.PopupStyle(keys: sizes.map { "\($0.width) × \($0.height)" }, separatorBefore: [sizes.count])
        var group = ""
        for (i, p) in sizes.enumerated() where p.group != group { size.headers[i] = p.group; group = p.group }
        let builtIn = Set(ProjectTemplate.builtIn.map(\.id))
        var template = ShellForm.PopupStyle()
        if let first = templates.firstIndex(where: { builtIn.contains($0.id) }) { template.headers[first] = "Built in" }
        if let first = templates.firstIndex(where: { !builtIn.contains($0.id) }) { template.headers[first] = "Yours" }
        var rate = ShellForm.PopupStyle(keys: rateNotes)
        // `NewProjectSheet` rows are 28 pt with 28 pt popups.
        size.height = 28; template.height = 28; rate.height = 28
        size.fontSize = 12; template.fontSize = 12; rate.fontSize = 12
        let tall = ShellForm.PopupStyle(height: 28, fontSize: 12)
        return ["size": size, "template": template, "rate": rate, "audio": tall, "outside": tall]
    }
    /// `NewProjectSheet` metrics: sheet 600, popups 260, W/H fields 84, Normal | Fast Cut segments 84.
    static let sheetWidth: CGFloat = 600
    static let popWidth: CGFloat = 260
    static let sizeFieldWidth: CGFloat = 84

    static func audioTitle(_ rate: Int) -> String {
        rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)
    }

    /// `NewProjectSheet.aspectText`: "9:16", "16:9", "2.39:1".
    static func aspectText(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "" }
        var a = width, b = height
        while b != 0 { (a, b) = (b, a % b) }
        let rw = width / a, rh = height / a
        if rw <= 32, rh <= 32 { return "\(rw):\(rh)" }
        return String(format: "%.2f:1", Double(width) / Double(height))
    }

    /// `NewProjectSheet.tildePath`.
    static func tildePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    static func sizeIndex(width: Int, height: Int) -> Int {
        sizes.firstIndex { $0.width == width && $0.height == height } ?? sizes.count
    }

    /// The form for `templates`; `fastCut` is the Preferences default (`AppSettings.newSequenceEditMode`).
    public static func form(templates: [ProjectTemplate], preferred: Int = 0, location: URL, fastCut: Bool = false) -> ShellForm {
        let t = templates.indices.contains(preferred) ? templates[preferred] : templates[0]
        let rate = SequenceFormatPresets.frameRates.firstIndex { $0.frameDuration == t.format.frameDuration } ?? 4
        let audio = audioRates.firstIndex(of: t.format.audioSampleRate) ?? 0
        let dims = 1...Double(SequenceFormatPresets.maxDimension)
        let form = ShellForm([
            .field(id: "name", label: "Name", value: NewProjectInput.defaultName),
            .popup(id: "template", label: "Template", options: templates.map(\.name), selected: preferred),
            .popup(id: "size", label: "Frame size", options: sizes.map(\.name) + ["Custom size"],
                   selected: sizeIndex(width: t.format.width, height: t.format.height)),
            .size(label: "", width: .init(id: "width", value: Double(t.format.width), range: dims, defaultValue: Double(t.format.width)),
                  height: .init(id: "height", value: Double(t.format.height), range: dims, defaultValue: Double(t.format.height))),
            .popup(id: "rate", label: "Frame rate", options: SequenceFormatPresets.frameRates.map { $0.label + " fps" }, selected: rate),
            .popup(id: "audio", label: "Audio", options: audioRates.map { audioTitle($0) + " · Stereo" }, selected: audio),
            .segmented(id: "timeline", label: "Timeline", options: ["Normal", "Fast Cut"], selected: fastCut ? 1 : 0, segmentWidth: 84),
            .popup(id: "outside", label: "Outside files", options: outsideChoices.map { SQL10n.string($0.1) }, selected: 0),
            .buttons(id: "location", label: "Location", detail: tildePath(location), titles: ["Choose\u{2026}"]),
        ])
        for id in ["template", "size", "rate", "audio", "outside"] { form.controlWidths[id] = popWidth }
        form.controlWidths["width"] = sizeFieldWidth
        // `NewProjectSheet`: 24 pt side padding, 4 pt more before Frame size and Location, a 22 pt name field.
        form.sidePad = 24
        form.labelInset = 2   // `NewProjectSheet` labels are NSTextFields: 2 pt cell padding
        form.extraGapBefore = [2: 4, 8: 4]
        form.fieldHeights["name"] = 22; form.dialogFieldFontSize = 12; form.labeledFieldBleed = false
        form.popupStyles = popupStyles(templates: templates)
        form.chips["location"] = ShellForm.Chip(icon: .folder, buttonWidth: 92)
        form.swapBetween = ["width"]
        form.hints["timeline"] = "Default from Preferences › Playback"
        form.set("location", .text(location.path))
        refresh(form, templates: templates)
        // A new template brings its own size, rate and sample rate (the Mac sheet's `applyTemplate`); a size preset fills
        // W and H; typed sizes pick their preset or Custom size.
        form.onChange = { [weak form] id, v in
            guard let form else { return }
            switch (id, v) {
            case ("template", .index(let i)) where templates.indices.contains(i):
                let f = templates[i].format
                form.set("width", .number(Double(f.width))); form.set("height", .number(Double(f.height)))
                if let r = SequenceFormatPresets.frameRates.firstIndex(where: { $0.frameDuration == f.frameDuration }) { form.set("rate", .index(r)) }
                if let a = audioRates.firstIndex(of: f.audioSampleRate) { form.set("audio", .index(a)) }
            case ("size", .index(let i)) where sizes.indices.contains(i):
                form.set("width", .number(Double(sizes[i].width))); form.set("height", .number(Double(sizes[i].height)))
            default: break
            }
            refresh(form, templates: templates)
        }
        return form
    }

    /// `NewProjectSheet.refresh`: the template summary, the size preset and the aspect hint follow the choices.
    static func refresh(_ form: ShellForm, templates: [ProjectTemplate]) {
        let ti = form.index("template") ?? 0
        form.hints["template"] = templates.indices.contains(ti) ? templates[ti].summary : ""
        let w = Int((form.number("width") ?? 0).rounded()), h = Int((form.number("height") ?? 0).rounded())
        let si = sizeIndex(width: w, height: h)
        form.set("size", .index(si))
        form.hints["width"] = aspectText(width: w, height: h) + " · px"
        form.popupStyles["size"]?.boxKey = sizes.indices.contains(si) ? sizes[si].key : aspectText(width: w, height: h)
    }

    /// The footer of the Mac sheet: "1080 × 1920 · 30 fps", "9:16 · 48 kHz Stereo · Normal timeline" and the aspect box.
    public static func summary(_ form: ShellForm, templates: [ProjectTemplate]) -> ShellDialog.FooterSummary {
        guard let a = answer(form, templates: templates) else { return .init(line1: "", line2: "", aspect: 9.0 / 16) }
        let f = a.template.format
        let rate = SequenceFormatPresets.frameRates.first { $0.frameDuration == f.frameDuration }?.label ?? ""
        return .init(line1: "\(f.width) × \(f.height) · \(rate) fps",
                     line2: "\(aspectText(width: f.width, height: f.height)) · \(audioTitle(f.audioSampleRate)) Stereo · "
                         + "\(a.editMode == .magnetic ? "Fast Cut" : "Normal") timeline",
                     aspect: f.height > 0 ? CGFloat(f.width) / CGFloat(f.height) : 1)
    }

    /// A folder picked with Choose….
    static func setLocation(_ form: ShellForm, _ url: URL) {
        form.set("location", .text(url.path))
        form.setDetail("location", tildePath(url))
    }

    /// `NewProjectSheet.create`: the answer the form describes.
    public static func answer(_ form: ShellForm, templates: [ProjectTemplate]) -> ShellNewProjectAnswer? {
        let ti = form.index("template") ?? 0
        guard templates.indices.contains(ti) else { return nil }
        var template = templates[ti]
        template.format = NewProjectInput.resolve(base: template.format, width: Int((form.number("width") ?? 0).rounded()),
                                                  height: Int((form.number("height") ?? 0).rounded()),
                                                  rateIndex: form.index("rate") ?? -1,
                                                  sampleRate: audioRates[min(max(form.index("audio") ?? 0, 0), audioRates.count - 1)])
        let path = (form.text("location") ?? "").trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let outside = outsideChoices[min(max(form.index("outside") ?? 0, 0), outsideChoices.count - 1)].0
        return ShellNewProjectAnswer(name: NewProjectInput.name(typed: form.text("name") ?? ""), template: template, mode: outside,
                                     location: URL(fileURLWithPath: path, isDirectory: true),
                                     editMode: form.index("timeline") == 1 ? .magnetic : .normal)
    }
}

extension ShellHost {
    /// `createProjectFolder`: the form, then `createProject`.
    public func newProjectForm() async {
        guard await confirmDiscardChanges() else { return }
        let templates = allTemplates
        let form = ShellNewProject.form(templates: templates, location: newProjectLocation,
                                        fastCut: AppSettings.load().newSequenceEditMode == .magnetic)
        let refresh = form.onChange
        form.onChange = { [weak self, weak form] id, v in
            guard id == "location" else { refresh?(id, v); return }
            self?.spawn {
                guard let url = await self?.files?.chooseFolder(prompt: SQL10n.string("Choose")), let form else { return }
                ShellNewProject.setLocation(form, url)
            }
        }
        let d = ShellDialog("New project", informative: "Settings can change later in Sequence Settings.")
        d.width = ShellNewProject.sheetWidth
        d.form = form
        d.footerSummary = { [weak form] in
            form.map { ShellNewProject.summary($0, templates: templates) } ?? .init(line1: "", line2: "", aspect: 1)
        }
        d.closeButton = true
        d.headingFontSize = 15
        d.addButton("Create")
        d.addButton("Cancel", role: .cancel)
        d.buttonWidths = [0: 104, 1: 76]
        d.buttonHints = [0: "\u{23CE}"]
        guard await ask(d) == .first, let answer = ShellNewProject.answer(form, templates: templates) else { return }
        do { try FileManager.default.createDirectory(at: answer.location, withIntermediateDirectories: true) } catch {
            presentError("Could not create the location folder", error); return
        }
        newProjectLocation = answer.location
        await createProject(answer)
    }

    /// `createProject`: `<parent>/<Name>/<Name>.sqproj` and `Files/` from the template, then opens it. Nothing existing
    /// is overwritten.
    public func createProject(_ a: ShellNewProjectAnswer) async {
        let projectName = MediaManagement.sanitized(a.name)
        let layout = MediaManagement.layout(name: projectName, in: a.location)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: layout.folder.path) else {
            presentMessage(SQL10n.format("A folder named “%@” already exists there", projectName),
                           SQL10n.string("Choose another name or location. Nothing was changed."))
            return
        }
        do {
            try fm.createDirectory(at: layout.filesFolder, withIntermediateDirectories: true)
            var p = a.template.makeProject(name: projectName)
            if let mode = a.editMode, !p.timelines.isEmpty { p.timelines[0].editMode = mode }
            p.mediaPolicy = MediaPolicy(outside: a.mode, watchFolder: MediaSettings.defaults.watchFolder)
            session.newProject(p)
            try await session.saveAs(to: layout.projectFile)
            recents.note(layout.projectFile)
            saveRecents?(recents)
            onProjectChanged?()
        } catch { presentError("Could not create the project", error) }
    }
}
