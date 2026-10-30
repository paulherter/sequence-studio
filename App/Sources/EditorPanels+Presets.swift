import AppKit
import SQCore
import SQEditorUI
import SQInspectorUI
import SQLibrary

/// Effect presets: "Save as Preset…" from the timeline menu, apply by drop onto a clip or from the Library.
extension EditorPanels {
    func wirePresets() {
        timelineView.onDropPreset = { [weak self] id, clip in
            guard let self, let item = libraryModel.presets.first(where: { $0.id == id }) else { return }
            if !session.applyPreset(item, to: [clip], mode: PresetApplyModeSetting.load()) { onStatus?(session.lastError ?? "The preset could not be applied.") }
        }
        effectView.onDropEffect = { [weak self] kind in
            guard let self, let clip = effectModel.clip?.id else { return }
            if !session.addEffect(kind: kind, to: [clip]) { onStatus?(SQL10n.format("%@ needs %@.", SQL10n.string(EffectCatalog.title(for: kind)), SQL10n.string(Self.effectTargetNoun(kind)))) }
        }
        effectView.onDropPreset = { [weak self] id in
            guard let self, let clip = effectModel.clip?.id, let item = libraryModel.presets.first(where: { $0.id == id }) else { return }
            if !session.applyPreset(item, to: [clip], mode: PresetApplyModeSetting.load()) { onStatus?(session.lastError ?? "The preset could not be applied.") }
        }
        libraryModel.onInsertTitleBlock = { [weak self] item, time in self?.insertTitleBlock(item, at: time) }
        timelineView.onDropTitleBlock = { [weak self] id, time in
            guard let self, let item = libraryModel.presets.first(where: { $0.id == id }) else { return }
            insertTitleBlock(item, at: time)
        }
        libraryModel.onApplyPreset = { [weak self] item, mode in
            guard let self else { return }
            if !session.applyPreset(item, mode: mode ?? PresetApplyModeSetting.load()) { onStatus?(session.lastError ?? "The preset could not be applied.") }
        }
    }

    /// The Library's video effect presets that carry effects, for the Graphics panel's layer Presets menu.
    func layerEffectPresets() -> [(name: String, preset: EffectPreset)] {
        libraryModel.presets.compactMap { item in
            guard item.kind == .effect,
                  let p = try? EffectPreset(payload: item.payload, version: item.payloadVersion),
                  p.trackKind == .video, !p.effects.isEmpty else { return nil }
            return (item.name, p)
        }
    }

    /// Name sheet for the selected layer's effects, then saves them to the Library as an effect preset.
    func saveLayerEffectPreset(_ preset: EffectPreset) {
        guard let window = graphicsView.window else { return }
        PresetSaveSheet.present(on: window, defaultName: graphics.selectedLayer?.name ?? "Layer Effects") { [weak self] choice in
            guard let self, let choice else { return }
            var p = preset
            p.anchor = choice.anchor
            Task { @MainActor in
                do {
                    try await self.libraryModel.savePreset(EditorSession.effectPresetItem(name: choice.name, preset: p))
                    self.onStatus?(SQL10n.format("Saved preset “%@”.", choice.name))
                } catch {
                    self.onStatus?(SQL10n.format("The preset could not be saved: %@", SQL10n.errorText(error)))
                }
            }
        }
    }

    /// Name + anchor sheet for the one selected video clip, then saves it to the Library.
    func saveSelectedClipAsPreset() {
        guard let window = timelineView.window, let clip = session.singleSelectedClip else { return }
        guard session.presetFromSelectedClip(anchor: .start) != nil else {
            onStatus?(SQL10n.format("“%@” has no Motion, Opacity or effect changes to save.", clip.name))
            return
        }
        PresetSaveSheet.present(on: window, defaultName: clip.name) { [weak self] choice in
            guard let self, let choice, let preset = session.presetFromSelectedClip(anchor: choice.anchor) else { return }
            Task { @MainActor in
                do {
                    try await libraryModel.savePreset(EditorSession.effectPresetItem(name: choice.name, preset: preset))
                    onStatus?(SQL10n.format("Saved preset “%@”.", choice.name))
                } catch {
                    onStatus?(SQL10n.format("The preset could not be saved: %@", SQL10n.errorText(error)))
                }
            }
        }
    }

    /// Name sheet for the selected text, shape and adjustment clips, then saves them to the Library as a title block.
    func saveSelectionAsTitleBlock() {
        guard let window = timelineView.window else { return }
        guard let block = session.titleBlockFromSelection() else {
            onStatus?(session.lastError ?? "Select the title clips first.")
            return
        }
        let name = session.singleSelectedClip?.name ?? "Title"
        TitleBlockSaveSheet.present(on: window, defaultName: name) { [weak self] chosen in
            guard let self, let chosen, let item = try? block.presetItem(name: chosen) else { return }
            Task { @MainActor in
                do {
                    try await libraryModel.savePreset(item)
                    onStatus?(SQL10n.format("Saved title block “%@”.", chosen))
                } catch {
                    onStatus?(SQL10n.format("The title block could not be saved: %@", SQL10n.errorText(error)))
                }
            }
        }
    }

    /// Places a saved title block or title template at `time` (default the playhead) on free tracks above
    /// (`TextTemplatePlacement.insertTitle`, shared with Windows).
    func insertTitleBlock(_ item: PresetItem, at time: Time?) {
        onStatus?(TextTemplatePlacement.insertTitle(item, at: time, session: session))
    }
}
