import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQLibrary
import SQTimelineUI
import SQUIKit

/// The timeline's editor dialogs on the shared shell, translated from the Mac `EditorPanels` flows (TrackMixDialog,
/// Sequence Volume, Tone Settings, PresetSaveSheet, TransitionPresetSheet, Save Title Block / Template, ColorMatteDialog,
/// AnglesDialog, caption text): `open` answers the `TimelineEditorRequest`s it owns. Portable: the Mac shared UI uses
/// it; Windows `AppController+TimelineEditors` forwards to it too.
@MainActor
public final class TimelineEditorDialogs {
    let session: EditorSession
    unowned let shell: ShellHost
    /// The Save as Template thumbnail, asked only while the playhead is inside the selected video (the Mac renders a
    /// 320 px PNG of the Program frame); nil = no renderer, the template saves without one.
    public var templateThumbnail: (@MainActor () async -> Data?)?

    public init(session: EditorSession, shell: ShellHost) {
        self.session = session; self.shell = shell
    }

    /// Answers `r` when it is one of these dialogs; nil = not one of them.
    public func open(_ r: TimelineEditorRequest) -> Bool? {
        switch r {
        case .trackMix(let id): presentTrackMix(id); return true
        case .sequenceVolume: presentSequenceVolume(); return true
        case .toneClip(let id): return editTone(id)
        case .saveClipPreset: saveSelectedClipAsPreset(); return true
        case .saveTransitionPreset(let id): session.selectTransition(id); saveSelectedTransitionAsPreset(); return true
        case .saveTitleBlock: saveSelectionAsTitleBlock(); return true
        case .saveTemplate: saveSelectionAsTemplate(); return true
        case .newColorMatte: presentNewColorMatte(); return true
        case .createAnglesClip: requestAnglesClip(); return true
        case .captionText(let id): return editCaptionText(id)
        default: return nil
        }
    }

    /// The XS card width (360, `Theme.Modal.widthXS`; that token is AppKit-only and not on Windows).
    private static let widthXS: CGFloat = 360

    private func flash(_ s: String) { shell.onStatus?(SQL10n.string(s)) }

    // MARK: Mix

    /// The Mac `TrackMixDialog.volumeSlider`: fader range, 0.1 dB steps, "-inf" at the floor, double-click resets to 0 dB.
    private static func volumeRow(_ db: Double) -> ShellForm.Row {
        .sliderNumber(label: "Volume", .init(id: "volume", value: db, range: TrackPan.minVolumeDB...TrackPan.maxVolumeDB, step: 0.1,
                                             decimals: 1, unit: "dB", defaultValue: 0))
    }

    private static func formatVolume(_ form: ShellForm) {
        form.setFormat("volume", format: { TrackMixText.capsuleText(volumeDB: $0) }, parse: { TrackMixText.parse(volumeDB: $0) })
    }

    /// "Track Volume and Pan" (the Mac `TrackMixDialog.present`): XS card, Volume and Pan `NumericSlider`s, one undo step.
    public func presentTrackMix(_ id: Track.ID) {
        guard let track = session.activeTimeline?.tracks.first(where: { $0.id == id }) else { return }
        let d = ShellDialog("Track Volume and Pan", informative: track.name)
        d.width = Self.widthXS
        let form = ShellForm([
            Self.volumeRow(track.volumeDB),
            .sliderNumber(label: "Pan", .init(id: "pan", value: track.pan * 100, range: -100...100, defaultValue: 0)),
        ])
        Self.formatVolume(form)
        form.setFormat("pan", format: { TrackMixText.text(pan: $0) }, parse: { TrackMixText.parse(pan: $0) })
        d.form = form
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        shell.spawn { [weak self] in
            guard let self, await shell.ask(d) == .first else { return }
            _ = session.setTrackMix(id, volumeDB: form.number("volume") ?? track.volumeDB,
                                    pan: (form.number("pan") ?? track.pan * 100) / 100)
        }
    }

    /// "Sequence Volume" (the Mac `TrackMixDialog.presentSequenceVolume`): Volume, Keyframe at Playhead.
    public func presentSequenceVolume() {
        guard let t = session.activeTimeline else { return }
        let d = ShellDialog("Sequence Volume", informative: t.name.isEmpty ? "Every track of this sequence" : "Every track of \(t.name)")
        d.width = Self.widthXS
        let level = t.masterVolumeDB(at: session.playhead)
        let form = ShellForm([Self.volumeRow(level), .check(id: "animate", title: "Keyframe at Playhead", on: t.isMasterVolumeKeyed)])
        Self.formatVolume(form)
        d.form = form
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        shell.spawn { [weak self] in
            guard let self, await shell.ask(d) == .first else { return }
            _ = session.setSequenceVolume(form.number("volume") ?? level, animate: form.bool("animate") ?? false)
        }
    }

    /// The Mac "Tone Settings" sheet: frequency in Hz and level in dB, one undo step.
    public func editTone(_ id: Clip.ID) -> Bool {
        guard let spec = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id })?.tone else { return false }
        let d = ShellDialog("Tone Settings", informative: "Sine tone, 1 kHz at -12 dB by default")
        d.width = Self.widthXS
        d.form = ShellForm([.field(id: "freq", label: "Frequency", value: String(format: "%g", spec.frequencyHz), unit: "Hz"),
                            .field(id: "level", label: "Level", value: String(format: "%g", spec.levelDB), unit: "dB")])
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        shell.spawn { [weak self] in
            guard let self, await shell.ask(d) == .first, let f = d.form else { return }
            session.setTone(id, ToneSpec(frequencyHz: f.number("freq") ?? spec.frequencyHz, levelDB: f.number("level") ?? spec.levelDB))
        }
        return true
    }

    // MARK: Library presets

    /// Adds `item` to the Library (the Mac `libraryModel.savePreset`); `done` is the status line on success.
    private func savePreset(_ item: () throws -> PresetItem, done: String, failure: String) async {
        do {
            try await LibraryStores.presetStore.add(try item())
            flash(done)
        } catch {
            flash(SQL10n.format(failure, SQL10n.errorText(error)))
        }
    }

    /// "Save Preset" (the Mac `PresetSaveSheet`): name and keyframe anchor for the one selected clip, then the Library.
    public func saveSelectedClipAsPreset() {
        guard let clip = session.singleSelectedClip else { flash("Select one clip to save its settings as a preset."); return }
        guard session.presetFromSelectedClip(anchor: .start) != nil else {
            flash(SQL10n.format("“%@” has no Motion, Opacity or effect changes to save.", clip.name)); return
        }
        let anchors = PresetSaveSheet.anchorTitles
        let d = ShellDialog("Save as Preset", informative: "Saves Transform, Opacity and effects with their keyframes and easing.")
        let form = ShellForm([.field(id: "name", label: "", value: clip.name),
                              .popup(id: "anchor", label: "", options: anchors.map { SQL10n.string($0.1) }, selected: 0)])
        form.controlWidths = ["name": 400, "anchor": 400]
        d.form = form
        form.beginEditing("name")
        d.addButton("Save")
        d.addButton("Cancel", role: .cancel)
        shell.spawn { [weak self] in
            guard let self, await shell.ask(d) == .first, let f = d.form else { return }
            let name = PresetSaveSheet.resolvedName(f.text("name") ?? "", fallback: clip.name)
            let i = min(max(f.index("anchor") ?? 0, 0), anchors.count - 1)
            guard let preset = session.presetFromSelectedClip(anchor: anchors[i].0) else { return }
            await savePreset({ try EditorSession.effectPresetItem(name: name, preset: preset) },
                             done: SQL10n.format("Saved preset “%@”.", name), failure: "The preset could not be saved: %@")
        }
    }

    public func saveSelectedTransitionAsPreset() {
        guard let preset = session.presetFromSelectedTransition() else { return }
        askName("Save Transition as Preset",
                informative: "Kind, length, alignment, easing and style are saved to the Library (Presets, Transitions).",
                initial: preset.kind.name, width: 400) { [weak self] name in
            await self?.savePreset({ try EditorSession.transitionPresetItem(name: name, preset: preset) },
                                   done: SQL10n.format("Saved transition preset “%@”.", name), failure: "The preset could not be saved: %@")
        }
    }

    public func saveSelectionAsTitleBlock() {
        guard let block = session.titleBlockFromSelection() else {
            flash(session.lastError ?? "Select the title clips first."); return
        }
        askName("Save to Library", informative: "Saves the selected clips with their animations as a title block.",
                initial: session.singleSelectedClip?.name ?? "Title") { [weak self] name in
            await self?.savePreset({ try block.presetItem(name: name) },
                                   done: SQL10n.format("Saved title block “%@”.", name), failure: "The title block could not be saved: %@")
        }
    }

    public func saveSelectionAsTemplate() {
        let fallback = session.singleSelectedClip?.name ?? "Title"
        guard session.titleTemplateFromSelection(name: fallback) != nil else {
            flash(session.lastError ?? "Select the title layers first."); return
        }
        askName("Save as Template",
                informative: "Saves the selected layers as a template with editable text, color, font and size, and keeps the intro and outro when the clip is trimmed.",
                initial: fallback) { [weak self] name in
            guard let self, let template = session.titleTemplateFromSelection(name: name) else { return }
            let render = session.playheadIsInsideSelectedVideo ? templateThumbnail : nil
            session.stopPlayback()
            let thumb = await render?()
            let note = render != nil && thumb == nil ? " " + SQL10n.string("No preview image could be made.") : ""
            await savePreset({ try TitleTemplatePreset(template: template, thumbnail: thumb).presetItem(name: name) },
                             done: SQL10n.format("Saved template “%@”. Find it in the Library under Titles.", name) + note,
                             failure: "The template could not be saved: %@")
        }
    }

    /// One unlabeled name field `width` pt wide (the Mac sheets' accessory), Save / Cancel; `run` gets the trimmed name
    /// (`initial` for a blank field).
    private func askName(_ title: String, informative: String, initial: String, width: CGFloat = 260,
                         _ run: @escaping @MainActor (String) async -> Void) {
        let d = ShellDialog(title, informative: informative)
        let form = ShellForm([.field(id: "name", label: "", value: initial)])
        form.controlWidths = ["name": width]
        d.form = form
        form.beginEditing("name")
        d.addButton("Save")
        d.addButton("Cancel", role: .cancel)
        shell.spawn { [weak self] in
            guard let self, await shell.ask(d) == .first else { return }
            await run(PresetSaveSheet.resolvedName(d.form?.text("name") ?? "", fallback: initial))
        }
    }

    // MARK: Color matte, Angles clip

    private static func matteValue(_ c: ColorMatteColor) -> SQColorValue {
        SQColorValue(r: Double(c.r) / 255, g: Double(c.g) / 255, b: Double(c.b) / 255)
    }

    /// New Color Matte: name, color, duration; the matte goes on the timeline at the playhead (the Mac `ColorMatteDialog`).
    public func presentNewColorMatte() {
        guard session.activeTimeline != nil else { flash("Open a sequence first."); return }
        let d = ShellDialog("New Color Matte",
                            informative: "A flat color layer for when there is no video. It goes on the timeline at the playhead.")
        d.width = Self.widthXS
        let form = ShellForm([.field(id: "name", label: "Name", value: "Color Matte"),
                              .color(id: "color", label: "Color", value: Self.matteValue(.default)),
                              .sliderNumber(label: "Duration", .init(id: "duration", value: 5, range: 0.1...3600, step: 0.5,
                                                                     decimals: 1, unit: "s", defaultValue: 5))])
        form.controlWidths = ["name": 220]
        d.form = form
        d.addButton("Add")
        d.addButton("Cancel", role: .cancel)
        shell.spawn { [weak self] in
            guard let self, await shell.ask(d) == .first, let f = d.form else { return }
            let name = PresetSaveSheet.resolvedName(f.text("name") ?? "", fallback: "Color Matte")
            let color = TimelineEditorForms.matteColor(hex: f.color("color")?.hex ?? "") ?? .default
            let duration = TimelineEditorForms.matteDuration(seconds: f.number("duration") ?? 5)
            session.stopPlayback()
            guard session.addColorMatte(color, name: name, duration: duration) != nil else {
                if let e = session.lastError { flash(e) }
                return
            }
            session.seek(to: session.playhead)
        }
    }

    /// Create Angles Clip from the selected timeline clips: name, sync, sound angle, Audio Follows Video.
    /// The sync choices are the Mac sheet's (`AngleSyncMode.choices`); Timecode and Audio read the files through
    /// `ShellHost.anglesOrigins`.
    public func requestAnglesClip() {
        let clips = session.angleSelection
        let angles = session.angleCandidates(clips: clips)
        guard angles.count >= 2 else { flash("Select at least two clips, in the timeline or in the Project panel."); return }
        let fallback = Self.anglesName(existing: session.project.timelines.map(\.name))
        let syncs = AngleSyncMode.choices(angles: angles, fromTimeline: true)
        let d = ShellDialog("Create Angles Clip",
                            informative: SQL10n.format("%@ angles become one clip. Cut it and choose an angle per piece with the keys 1 to 9.",
                                                       String(angles.count)))
        d.form = ShellForm([
            .field(id: "name", label: "Name", value: fallback),
            .popup(id: "sync", label: "Sync by", options: syncs.map { SQL10n.string($0.title) }, selected: 0),
            .popup(id: "sound", label: "Sound from", options: angles.enumerated().map { "\($0.offset + 1)  \($0.element.name)" },
                   selected: AngleSyncMode.defaultAudioAngle(angles)),
            .check(id: "follows", title: "Audio Follows Video", on: false),
        ])
        d.form?.labeledPopupBleed = true   // the Mac formRow popups start 5 pt left of the column
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        shell.spawn { [weak self] in
            guard let self, await shell.ask(d) == .first, let f = d.form else { return }
            let name = PresetSaveSheet.resolvedName(f.text("name") ?? "", fallback: fallback)
            let sync = syncs[min(max(f.index("sync") ?? 0, 0), syncs.count - 1)]
            let audioAngle = max(f.index("sound") ?? 0, 0), follows = f.bool("follows") ?? false
            if sync == .timecode || sync == .audio { flash("Lining up the angles…") }
            let found = await shell.anglesOrigins(sync: sync, angles: angles)
            let made = session.createAnglesClip(from: clips, name: name, origins: found.origins, audioAngle: audioAngle,
                                                audioFollowsVideo: follows)
            let done = "Angles clip created: cut it and press 1 to 9 on a piece."
            flash(made == nil ? (session.lastError ?? "Could not create the Angles clip.")
                  : found.note.map { "\($0) \(done)" } ?? done)
        }
    }

    /// First free "Angles NN" (the Mac `AnglesDialog.defaultName`).
    public static func anglesName(existing: [String]) -> String { AngleSyncMode.defaultName(existing: existing) }

    // MARK: Captions

    /// The Text panel types into the caption's row (`editCaptionInPanel`); without that host: its text in one field (lines separated by " / "), one undo step.
    /// shortcut: one line field instead of the Mac in-place multi-line editor; upgrade when shell forms get a text area.
    public func editCaptionText(_ id: CaptionItem.ID) -> Bool {
        if shell.editCaptionInPanel?(id) == true { return true }
        guard let item = session.activeTimeline?.captionTracks.lazy.flatMap(\.items).first(where: { $0.id == id }) else { return false }
        session.select(clips: [], captions: [id])
        let d = ShellDialog("Edit Caption", informative: "Separate lines with \" / \".")
        d.form = ShellForm([.field(id: "text", label: "Text", value: item.lines.joined(separator: " / "))])
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        shell.spawn { [weak self] in
            guard let self, await shell.ask(d) == .first, let t = d.form?.text("text") else { return }
            let lines = t.components(separatedBy: " / ").map { $0.trimmingCharacters(in: .whitespaces) }
            session.setCaptionText(id, lines.joined(separator: "\n"))
        }
        return true
    }
}
