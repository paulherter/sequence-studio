import AppKit
import SQCore
import SQEditorUI
import SQLibrary

/// G1 Keystones: the panel (kept in step with the Library), drops on the timeline and Effect Controls, the stretch bar.
extension EditorPanels {
    func wireKeystones() {
        observeKeystonePresets()
        keystonesModel.onSave = { [weak self] k in
            guard let self else { return }
            Task { @MainActor in
                do { try await libraryModel.replacePreset(try KeystoneLibrary.presetItem(for: k)) } catch {
                    onStatus?(SQL10n.format("The keystone could not be saved: %@", SQL10n.errorText(error)))
                }
            }
        }
        // A Custom animation saved from a text inspector: answers once the Library holds the keystone (its list is
        // brought up to date first), so the inspector shows the new preset only when it is stored.
        keystonesModel.onSaveStored = { [weak self] k in
            guard let self else { return false }
            do {
                try await libraryModel.replacePreset(try KeystoneLibrary.presetItem(for: k))
                keystonesModel.presets = libraryModel.presets.filter { $0.kind == .keystone }
                return true
            } catch {
                onStatus?(SQL10n.format("The keystone could not be saved: %@", SQL10n.errorText(error)))
                return false
            }
        }
        keystonesModel.onDelete = { [weak self] id in
            guard let self else { return }
            Task { @MainActor in await libraryModel.deletePreset(id) }
        }
        keystonesView.onApply = { [weak self] k in
            guard let self else { return }
            guard let clip = session.singleSelectedClip, clip.kind == .video else {
                onStatus?(SQL10n.format("Select a video clip to apply “%@”.", k.name)); return
            }
            applyKeystone(k, to: clip.id, span: nil)
        }
        keystonesView.onSaveFromClip = { [weak self] in self?.saveKeystoneFromSelectedClip() }
        timelineView.onDropKeystone = { [weak self] k, clip, span in self?.applyKeystone(k, to: clip, span: span) }
        effectView.onDropKeystone = { [weak self] k in
            guard let self, let clip = effectModel.clip?.id else { return }
            applyKeystone(k, to: clip, span: nil)
        }
        timelineView.onRestretchKeystone = { [weak self] clip, old, new in
            guard let self else { return }
            if session.restretchKeystone(on: clip, old, to: new) {
                keystoneBarClip = currentClip(clip)
            } else {
                syncTimeline()
                if let e = session.lastError { onStatus?(e) }
            }
        }
    }

    private func applyKeystone(_ k: Keystone, to clip: Clip.ID, span: KeystoneSpan?) {
        guard let landed = session.applyKeystone(k, to: clip, span: span) else {
            onStatus?(session.lastError ?? SQL10n.format("“%@” could not be applied.", k.name)); return
        }
        keystoneBarClip = currentClip(clip)
        timelineView.keystoneBar = KeystoneBar(clip: clip, span: landed, name: k.name)
    }

    private func currentClip(_ id: Clip.ID) -> Clip? {
        session.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id }
    }

    /// Hides the bar once its clip changed by anything but the bar itself (undo, another edit, deleted).
    func syncKeystoneBar() {
        guard let bar = timelineView.keystoneBar else { return }
        if currentClip(bar.clip) != keystoneBarClip {
            timelineView.keystoneBar = nil
            keystoneBarClip = nil
        }
    }

    private func observeKeystonePresets() {
        keystonesModel.presets = libraryModel.presets.filter { $0.kind == .keystone }
        withObservationTracking { _ = libraryModel.presets } onChange: { [weak self] in
            Task { @MainActor in self?.observeKeystonePresets() }
        }
    }

    /// Name prompt, then the selected clip's keyed Position/Scale/Rotation/Opacity go to the Library as a keystone.
    func saveKeystoneFromSelectedClip() {
        guard let window = keystonesView.window ?? timelineView.window else { return }
        guard let clip = session.singleSelectedClip, session.keystoneFromSelectedClip(name: "x") != nil else {
            onStatus?("Select one video clip with at least two keyframes on Position, Scale, Rotation or Opacity.")
            return
        }
        let alert = SQDialog()
        alert.messageText = "Save Keystone"
        alert.informativeText = "Saves the keyframes of Position, Scale, Rotation and Opacity as a reusable keystone."
        let field = SQDialog.makeField(clip.name)
        alert.accessoryView = field
        alert.addButton("Save")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .first else { return }
                let name = PresetSaveSheet.resolvedName(field.stringValue, fallback: clip.name)
                guard let k = self.session.keystoneFromSelectedClip(name: name) else { return }
                self.keystonesModel.onSave?(k)
                self.keystonesModel.selectedID = k.id
                self.onStatus?(SQL10n.format("Saved keystone “%@”.", name))
            }
        }
    }
}
