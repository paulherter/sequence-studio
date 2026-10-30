import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQAppShell
import SQDrawTimeline
import SQEditorSession
import SQInspectorUI
import SQLibrary
import SQMedia
import SQTimelineUI
import SQUIKit

/// Trim mode and the timeline's editor dialogs between frames (AppController's stored properties live in a file other
/// helpers edit, so one instance per process like `timelineDrags`).
@MainActor final class TimelineEditorState {
    /// Trim mode's view (SQAppShell `TrimModeHost`; the model and commands are the shell's `trim`).
    var trimHost: TrimModeHost?
    /// The shared dialogs (SQAppShell `TimelineEditorDialogs`): mix, presets, color matte, Angles clip, tone, caption text.
    var dialogs: TimelineEditorDialogs?
}

@MainActor let timelineEditors = TimelineEditorState()

/// Answers for `TimelineHost.open` on Windows, translated from the Mac `EditorPanels` flows: Trim mode
/// (EditorPanels+Trim), the Keystones card's library (EditorPanels+Keystones), Save as Preset / Title Block / Template
/// (EditorPanels+Presets, +TitleTemplates, +Transitions), New Color Matte, Create Angles Clip, the speed transition curve,
/// caption text, words and Find and Replace in Captions.
extension AppController {
    /// Called once from `configureTimelineDrags`.
    func configureTimelineEditors() {
        wireKeystoneLibrary()
        let dialogs = TimelineEditorDialogs(session: session, shell: shell)
        // The template's preview: the shown Program composite (the playhead sits in the selected clip), 320 px wide as
        // on the Mac. shortcut: the shown composite at sequence size, not a full-size render; stored-deflate PNG.
        dialogs.templateThumbnail = { [weak self] in
            self?.engine.scopePicture()?.rgbaImage.scaled(maxWidth: 320).pngData()
        }
        timelineEditors.dialogs = dialogs
        // Go to Timecode opens the monitor card's timecode field (as the Mac), not a dialog.
        shell.focusTimecode = { [weak self] in self?.monitors.focusTimecodeField() ?? false }
        timelineEditors.trimHost = TrimModeHost(shell: shell, slip: { [weak self] in self?.monitor.slip },
                                                selectEdges: { [weak self] in self?.timelinePanel.selectEdges($0) })
        // File > New > Color Matte… (the menu row; the Project panel's New Item asks through `openTimelineEditor`).
        let nextAction = shell.onAction
        shell.onAction = { [weak self] a in
            guard a == .newColorMatte, let self else { return nextAction?(a) ?? false }
            _ = timelineEditors.dialogs?.open(.newColorMatte)
            return true
        }
        // Apply Transition acts on the selected edit points; Audio Gain, Auto Duck, Remove Silences and Sync Audio read the
        // decoded waveforms (a missing one starts its FFmpeg read).
        shell.edgeSelection = { [weak self] in self?.timelinePanel.interaction.edgeSelection }
        shell.waveform = { winTimelineMedia?.waveform(media: $0) }
    }

    /// Answers the editors of `openTimelineEditor` that live here; nil = not one of these.
    func openTimelineEditorHere(_ r: TimelineEditorRequest) -> Bool? {
        switch r {
        case .trimMode(let p, let before): shell.enterTrimMode(p, pointerBefore: before); return true
        case .speedCurve(let clip, let segment, let p):
            let f = timelinePanel.frame, k = CGFloat(timelinePanel.scale)
            let w = CGPoint(x: CGFloat(f.x) / k + p.x, y: CGFloat(f.y) / k + p.y)
            inspector.openEase(SpeedRampEaseSource(session: session, clip: clip, segment: segment),
                               anchor: CGRect(x: w.x, y: w.y, width: 1, height: 1))
            return true
        case .captionWord(let ref):
            guard let a = timelinePanel.beginWordEditing(ref) else { return false }
            for x in a { applyTimeline(x) }
            return true
        case .captionFindReplace: presentCaptionFindReplace(); return true
        default: return timelineEditors.dialogs?.open(r)
        }
    }

    private func flash(_ s: String) { shell.onStatus?(SQL10n.string(s)) }

    // MARK: Trim mode (the shell runs the commands, `TrimModeHost` shows it)

    /// Lays the bar out under the timeline while Trim mode is on and returns what is left for the panel (pixels).
    func layoutTrimBar(_ area: DrawRect) -> DrawRect {
        // The shell's Trim commands (Ctrl+T, Trim Backward / Forward) need to know an edge is selected.
        shell.panels.edgeSelected = timelinePanel.interaction.edgeSelection != nil
        shell.panels.hasDeleteTarget = timelinePanel.interaction.hasDeleteTarget       // a selected gap closes on Delete
        return timelineEditors.trimHost?.layout(area, theme: screen.theme) ?? area
    }

    func drawTrimBar(_ c: inout Canvas) { timelineEditors.trimHost?.draw(&c) }

    /// True when the bar took the event (pointer moves go on).
    func handleTrimBar(_ e: InputEvent) -> Bool { timelineEditors.trimHost?.handle(e) ?? false }

    // MARK: Keystones card and its library

    private func wireKeystoneLibrary() {
        let model = timelineDrags.keystones
        let store = LibraryStores.presetStore
        model.onSave = { [weak self] k in
            Task { @MainActor in _ = await self?.storeKeystone(k) }
        }
        model.onSaveStored = { [weak self] k in await self?.storeKeystone(k) ?? false }
        model.onDelete = { [weak self] id in
            Task { @MainActor in
                try? await store.delete(id)
                await self?.reloadKeystones()
            }
        }
        Task { @MainActor [weak self] in await self?.reloadKeystones() }
    }

    /// `LibraryPanelModel.replacePreset` on the shared store, then the card's list.
    private func storeKeystone(_ k: Keystone) async -> Bool {
        let store = LibraryStores.presetStore
        do {
            let item = try KeystoneLibrary.presetItem(for: k)
            if await store.preset(item.id) != nil {
                try await store.updatePayload(item.id, payload: item.payload, version: item.payloadVersion)
                try await store.rename(item.id, to: item.name)
            } else {
                try await store.add(item)
            }
            await reloadKeystones()
            return true
        } catch {
            flash(SQL10n.format("The keystone could not be saved: %@", SQL10n.errorText(error)))
            return false
        }
    }

    private func reloadKeystones() async {
        timelineDrags.keystones.presets = await LibraryStores.presetStore.presets(kind: .keystone)
    }

    /// The card's menu actions (the Mac panel's `onApply`, `onSaveFromClip`, Edit Curve, `setEasing`, `onDelete`).
    func keystoneActions() -> KeystonePaletteActions {
        KeystonePaletteActions(
            apply: { [weak self] k in self?.applyKeystoneToSelection(k) },
            saveFromClip: { [weak self] in self?.saveKeystoneFromSelectedClip() },
            editCurve: { [weak self] k in
                guard let self else { return }
                timelineDrags.keystones.selectedID = k.id
                timelineDrags.palette.selectedID = k.id
                let card = timelineDrags.palette.frame
                inspector.openEase(KeystoneEaseSource(model: timelineDrags.keystones, id: k.id),
                                   anchor: CGRect(x: card.minX, y: card.minY + KeystonePalette.headerHeight, width: 1, height: 1))
            },
            useKeyframeEasing: { k in timelineDrags.keystones.setEasing(nil, for: k.id) },
            delete: { [weak self] k in self?.deleteKeystone(k) })
    }

    func applyKeystoneToSelection(_ ks: Keystone) {
        guard let clip = session.singleSelectedClip, clip.kind == .video else {
            status = SQL10n.format("Select a video clip to apply “%@”.", ks.name); return
        }
        // The Mac panel's apply: the keystone's own placement on the whole clip, then its bar.
        guard let landed = session.applyKeystone(ks, to: clip.id, span: nil) else {
            status = session.lastError ?? SQL10n.format("“%@” could not be applied.", ks.name); return
        }
        let now = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == clip.id }
        timelinePanel.setKeystoneBar(KeystoneBar(clip: clip.id, span: landed, name: ks.name), clip: now)
    }

    /// Delete Keystone / Reset to Built-in: only for a keystone the user saved or changed.
    func deleteKeystone(_ k: Keystone) {
        guard timelineDrags.keystones.canDelete(k.id) else { return }
        timelineDrags.keystones.onDelete?(k.id)
    }

    /// Right-click on a row (nil: on empty card space) or the header "...": the Mac panel's menus at `p` (window points).
    func showKeystoneMenu(_ k: Keystone?, options: Bool, at p: CGPoint) {
        let model = timelineDrags.keystones
        if let k { model.selectedID = k.id; timelineDrags.palette.selectedID = k.id }
        let items = options ? KeystonePalette.optionItems(selected: model.selected, keystoneActions())
            : KeystonePalette.contextItems(for: k, canDelete: k.map { model.canDelete($0.id) } ?? false, keystoneActions())
        shell.menuBar.controller.present(items: items, at: p, pointer: p)
    }

    /// The Mac "Save Keystone" sheet: a name, then the clip's Position, Scale, Rotation and Opacity keys go to the Library.
    func saveKeystoneFromSelectedClip() {
        guard let clip = session.singleSelectedClip, session.keystoneFromSelectedClip(name: "x") != nil else {
            flash("Select one video clip with at least two keyframes on Position, Scale, Rotation or Opacity."); return
        }
        let d = ShellDialog("Save Keystone", informative: "Saves the keyframes of Position, Scale, Rotation and Opacity as a reusable keystone.")
        d.form = ShellForm([.field(id: "name", label: "Name", value: clip.name)])
        d.addButton("Save")
        d.addButton("Cancel", role: .cancel)
        shell.spawn { [weak self] in
            guard let self, await shell.ask(d) == .first else { return }
            let name = PresetSaveSheet.resolvedName(d.form?.text("name") ?? "", fallback: clip.name)
            guard let k = session.keystoneFromSelectedClip(name: name) else { return }
            guard await storeKeystone(k) else { return }
            timelineDrags.keystones.selectedID = k.id
            timelineDrags.palette.selectedID = k.id
            flash(SQL10n.format("Saved keystone “%@”.", name))
        }
    }

    /// Find and Replace in Captions: find, replace, Match Case; Replace All is one undo step (the Mac popup's
    /// `replaceAll`).
    /// shortcut: Replace All only (no Next / Previous / Replace stepping through the matches); upgrade with a floating
    /// find bar on the timeline.
    func presentCaptionFindReplace() {
        let d = ShellDialog("Find and Replace in Captions")
        d.form = ShellForm([.field(id: "find", label: "Find", value: ""), .field(id: "replace", label: "Replace", value: ""),
                            .check(id: "case", title: "Match Case", on: false)])
        d.addButton("Replace All")
        d.addButton("Cancel", role: .cancel)
        shell.spawn { [weak self] in
            guard let self, await shell.ask(d) == .first, let f = d.form, let t = session.activeTimeline else { return }
            var search = CaptionSearchModel()
            search.find = f.text("find") ?? ""
            search.replacement = f.text("replace") ?? ""
            search.caseSensitive = f.bool("case") ?? false
            search.refresh(in: t)
            guard !search.find.isEmpty, let r = search.replacingAll(in: t) else { flash("No matches."); return }
            for a in timelinePanel.applyCaptionEdit(r.timeline, undoName: "Replace All in Captions",
                                                    captions: timelinePanel.captionSelection, word: nil) { applyTimeline(a) }
            flash(r.count == 1 ? "1 replaced" : "\(r.count) replaced")
        }
    }
}

// MARK: Source patching

extension AppController {
    /// The timeline's patch column follows the clip in the Source monitor (the Mac `syncSourcePatch`); chip clicks and
    /// drags come back as actions the bridge applies.
    func syncSourcePatch() {
        guard session.activeTimeline != nil, let id = source.core.mediaID, let ref = session.project.media(id) else {
            timelinePanel.sourcePatchStreams = nil
            return
        }
        var kinds: Set<TrackKind> = []
        if ref.info?.video != nil || ref.info == nil { kinds.insert(.video) }
        if ref.info?.audio != nil { kinds.insert(.audio) }
        timelinePanel.sourcePatchStreams = kinds
    }
}
