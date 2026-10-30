import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// Sequence > Change Format… and Duplicate as Format…, translated from the Mac `ChangeFormatSheet` (SQEditorUI
/// ChangeFormatDialog): Format (shape presets + Custom), Frame Size, Clips, Selected Clips when clips are selected, and
/// for the duplicate a Name. The conform itself is the session's (`changeActiveFormat`, `duplicateActiveSequence`).
@MainActor
public enum ShellChangeFormat {
    public struct Answer: Equatable, Sendable {
        public var format: SequenceFormat
        public var mode: ConformMode
        /// Mode for the selected clips; nil = same as `mode`.
        public var selectedMode: ConformMode?
        public var name: String
    }

    static var presets: [SequenceConform.AspectPreset] { SequenceConform.aspectPresets }

    /// The Mac sheet's `SQModal.Size.s` card.
    public static let sheetWidth: CGFloat = 440

    /// `name == nil`: Change Format; otherwise Duplicate as Format with that suggested name.
    public static func form(current: SequenceFormat, hasSelection: Bool, name: String?) -> ShellForm {
        // Start on the first shape that differs from the current one (the Mac sheet).
        let start = presets.firstIndex { $0.width * current.height != $0.height * current.width } ?? 0
        let dims = 1...Double(SequenceFormatPresets.maxDimension)
        var rows: [ShellForm.Row] = []
        if let name { rows.append(.field(id: "name", label: "Name", value: name)) }
        rows += [
            .popup(id: "format", label: "Format", options: presets.map { "\($0.name)  (\($0.width) × \($0.height))" } + ["Custom"],
                   selected: start),
            // The Mac "Frame Size" row: width × height in two number fields.
            .size(label: "Frame Size", width: .init(id: "width", value: Double(presets[start].width), range: dims),
                  height: .init(id: "height", value: Double(presets[start].height), range: dims)),
            .popup(id: "clips", label: "Clips", options: ConformMode.allCases.map(\.title),
                   selected: ConformMode.allCases.firstIndex(of: .fill) ?? 0),
        ]
        if hasSelection {
            rows.append(.popup(id: "selected", label: "Selected Clips", options: ["Same as all clips"] + ConformMode.allCases.map(\.title),
                               selected: 0))
        }
        // The Mac sheet has no note row: "Fill crops, Fit shows bars" is only the Clips popup's tooltip.
        let form = ShellForm(rows)
        // Board: both size fields 1fr of the 260 pt control column, minus the "×" and two gaps = 117 pt.
        form.plainSize = ["width"]
        form.controlWidths["width"] = 117
        form.onChange = { [weak form] id, v in
            guard let form else { return }
            switch id {
            case "format":
                guard case .index(let i) = v, presets.indices.contains(i) else { return }
                form.set("width", .number(Double(presets[i].width)))
                form.set("height", .number(Double(presets[i].height)))
            case "width", "height":
                let w = Int(form.number("width")?.rounded() ?? 0), h = Int(form.number("height")?.rounded() ?? 0)
                form.set("format", .index(presets.firstIndex { $0.width == w && $0.height == h } ?? presets.count))
            default: break
            }
        }
        return form
    }

    /// The chosen format and modes; nil when the size is not a valid frame.
    public static func answer(_ form: ShellForm, current: SequenceFormat) -> Answer? {
        guard let w = form.number("width"), let h = form.number("height"), w.isFinite, h.isFinite else { return nil }
        var f = current
        f.width = Int(w.rounded()); f.height = Int(h.rounded())
        guard f.isValid, f.width <= SequenceFormatPresets.maxDimension, f.height <= SequenceFormatPresets.maxDimension else { return nil }
        let modes = ConformMode.allCases
        let mode = modes[min(max(form.index("clips") ?? 0, 0), modes.count - 1)]
        let s = (form.index("selected") ?? 0) - 1
        return Answer(format: f, mode: mode, selectedMode: modes.indices.contains(s) ? modes[s] : nil, name: form.text("name") ?? "")
    }
}

extension ShellHost {
    /// Change Format (`duplicate` false) or Duplicate as Format of the active sequence.
    func changeFormat(duplicate: Bool) async {
        guard let tl = session.activeTimeline else { flash("Open a sequence first."); return }
        let form = ShellChangeFormat.form(current: tl.format, hasSelection: !session.selection.isEmpty, name: duplicate ? "" : nil)
        let d = ShellDialog(duplicate ? "Duplicate as Format" : "Change Format",
                            informative: duplicate ? "A reframed copy is added." : "Every clip is reframed for the new size.")
        d.width = ShellChangeFormat.sheetWidth
        d.form = form
        d.addButton(duplicate ? "Duplicate" : "Change")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first else { return }
        guard let a = ShellChangeFormat.answer(form, current: tl.format) else { flash("That frame size is not valid."); return }
        session.stopPlayback()
        if duplicate {
            if session.duplicateActiveSequence(as: a.format, mode: a.mode, selectedMode: a.selectedMode, name: a.name) == nil {
                flash("Could not duplicate the sequence.")
            }
        } else if a.format != tl.format, !session.changeActiveFormat(to: a.format, mode: a.mode, selectedMode: a.selectedMode) {
            flash("Could not change the format.")
        }
    }

    // MARK: Sequence templates

    /// Built-in templates first, then the saved ones (the Mac `TemplateStore.all`).
    var allTemplates: [ProjectTemplate] { ProjectTemplate.builtIn + templateFolder.load() }

    /// File > New Sequence from Template…: pick a template (built-in or saved), name the sequence; it opens next to the others.
    func newSequenceFromTemplate() async {
        let templates = allTemplates
        guard !templates.isEmpty else { return }
        // The Mac accessory box: name field over the template popup, both 300 pt, no labels.
        let form = ShellForm([
            .field(id: "name", label: "", value: session.suggestedSequenceName),
            .popup(id: "template", label: "", options: templates.map { "\($0.name) (\($0.format.width) × \($0.format.height))" },
                   selected: 0),
        ])
        form.controlWidths = ["name": 300, "template": 300]
        // `newSequenceFromTemplate`: the popup is 24 pt (`Theme.Row.controlLarge`), 8 pt under the field.
        form.popupStyles["template"] = ShellForm.PopupStyle(height: 24)
        form.extraGapBefore = [0: -4, 1: -4]   // the Mac box: field drawn 4 pt above the box top, 8 pt gap to the popup
        form.beginEditing("name")
        let d = ShellDialog("New Sequence from Template", informative: "")
        d.width = ShellChangeFormat.sheetWidth
        d.form = form
        d.addButton("Create")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first, let i = form.index("template"), templates.indices.contains(i) else { return }
        session.stopPlayback()
        _ = session.addSequence(from: templates[i], name: form.text("name") ?? "")
    }

    /// Sequence > Save Sequence as Template…: its format, track counts and variants become a template for new projects.
    func saveSequenceAsTemplate() async {
        guard let tl = session.activeTimeline else { flash("Open a sequence first."); return }
        // The Mac accessory: one 260 pt field, no label, focused.
        let form = ShellForm([.field(id: "name", label: "", value: tl.name)])
        form.controlWidths = ["name": 260]
        form.beginEditing("name")
        let d = ShellDialog("Save Sequence as Template", informative: "New projects start with its format, tracks and variants, "
                            + "its titles, emoji and adjustment layers, and this project's Looks. Footage and music are left out.")
        d.width = ShellChangeFormat.sheetWidth
        d.form = form
        d.addButton("Save")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first else { return }
        let typed = (form.text("name") ?? "").trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        let name = ProjectTemplate.freeName(typed, taken: allTemplates.map(\.name))
        do {
            try templateFolder.save(ProjectTemplate(capturing: tl, name: name, styleKit: session.project.styleKit))
            flash(SQL10n.format("Saved template “%@”.", name))
        } catch { presentError("Could not save the template", error) }
    }

    // MARK: Pixel Aspect

    /// The media items selected in the Project list.
    var selectedMediaIDs: [MediaRef.ID] {
        (projectSelection?() ?? []).compactMap { if case .media(let id) = $0 { id } else { nil } }
    }

    /// Clip > Pixel Aspect rows for the Project selection; nil (rows disabled) unless it is media with a picture.
    func pixelAspectRows() -> PixelAspectRows? {
        guard let s = PixelAspectChoices.state(project: session.project, media: selectedMediaIDs) else { return nil }
        let file = s.sharedFile.map { "From File (\(PixelAspectChoices.ratioText($0)))" } ?? "From File"
        let choice = s.sharedChoice
        var rows = [PixelAspectRows.Row(title: file, aspect: nil, checked: s.fromFile)]
        rows += PixelAspectChoices.named.map {
            PixelAspectRows.Row(title: "\($0.title) (\(PixelAspectChoices.ratioText($0.aspect)))", aspect: $0.aspect,
                                checked: choice == $0.aspect)
        }
        let custom = s.customChoice
        return PixelAspectRows(rows: rows, customTitle: custom.map { "Custom (\(PixelAspectChoices.ratioText($0)))…" } ?? "Custom Ratio…",
                               customChecked: custom != nil)
    }

    /// Sets the pixel aspect of the selected media (nil = From File): one undo step.
    func setSelectionPixelAspect(_ a: PixelAspect?) {
        let ids = selectedMediaIDs, refs = ids.map { BinItemRef.media($0) }
        guard !refs.isEmpty else { flash("Select a clip in the Project panel first."); return }
        if let projectModel { _ = projectModel.setPixelAspect(a, for: refs); return }
        session.perform("Set Pixel Aspect") { p in for id in ids { _ = p.setPixelAspect(a, for: id) } }
    }

    /// Custom Ratio…: width divided by height of one pixel, 0.25 to 4.
    func customSelectionPixelAspect() async {
        let ids = selectedMediaIDs
        guard !ids.isEmpty else { flash("Select a clip in the Project panel first."); return }
        let first = ids.lazy.compactMap { self.session.project.pixelAspect(of: $0) }.first ?? .square
        let form = ShellForm([.field(id: "ratio", label: "Ratio", value: PixelAspectChoices.ratioText(first))])
        let d = ShellDialog("Custom Pixel Aspect", informative: "Width divided by height of one pixel. 1 is square, 2 is a 2x anamorphic lens.")
        d.width = 360
        d.form = form
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first else { return }
        guard let v = form.number("ratio"), PixelAspectChoices.ratioRange.contains(v), let a = PixelAspectChoices.aspect(fromRatio: v)
        else { flash("Type a ratio from 0.25 to 4."); return }
        setSelectionPixelAspect(a)
    }
}
