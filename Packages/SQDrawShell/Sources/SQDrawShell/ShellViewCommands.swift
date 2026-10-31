import Foundation
import SQCore
import SQUIKit
import SQEditorSession
import SQExport

/// View toggles and one-click commands that need only the session, the engine and the Project list: the Mac
/// AppController+SourceFlow / +AudioGain / +Captions rows, Quick Export (ExportCoordinator.quickExport) and File > Import
/// Project (the Mac `runImportProjectPanel`).
extension ShellHost {
    /// True when `c` is one of these (run or refused with a status line).
    func performViewCommand(_ c: EditorCommand, defaults: UserDefaults = .standard) -> Bool {
        switch c {
        case .toggleAudioScrubbing:
            let on = !session.engine.audioScrubbing
            session.engine.audioScrubbing = on
            // shortcut: an engine without audio scrubbing (the protocol default) ignores the switch; upgrade when the
            // Windows engine scrubs audio.
            guard session.engine.audioScrubbing == on else { flash(ShellPlatformText.notAvailable); return true }
            var s = AppSettings.load(from: defaults)
            s.audioScrubbing = on
            s.save(to: defaults)
            flash(on ? "Audio scrubbing on" : "Audio scrubbing off")
        case .toggleCaptionsInMonitor:
            let on = !session.engine.showsCaptions
            session.engine.showsCaptions = on
            guard session.engine.showsCaptions == on else { flash(ShellPlatformText.notAvailable); return true }
            defaults.set(on, forKey: Self.captionsInMonitorKey)
            flash(on ? "Captions shown in the Program view" : "Captions hidden in the Program view")
        case .toggleSelectionFollowsPlayhead:
            let on = !session.selectionFollowsPlayhead
            session.setSelectionFollowsPlayhead(on)
            var s = AppSettings.load(from: defaults)
            s.selectionFollowsPlayhead = on
            s.save(to: defaults)
            flash(on ? "Selection follows playhead on" : "Selection follows playhead off")
        case .uiScaleLarger, .uiScaleSmaller, .uiScaleReset:
            let now = InterfaceScale.load(from: defaults)
            let next = c == .uiScaleReset ? 1.0 : InterfaceScale.stepped(from: now, delta: c == .uiScaleLarger ? 1 : -1)
            if next != now {
                InterfaceScale.store(next, in: defaults)
                NotificationCenter.default.post(name: InterfaceScale.didChange, object: nil)
                onSettingsChanged?(AppSettings.load(from: defaults))
            }
            flash(SQL10n.format("Interface size %@ %", String(Int((next * 100).rounded()))))
        case .projectListView, .projectIconView:
            guard let list = projectList else { return false }
            list.setViewMode(c == .projectListView ? .list : .icons)
        case .toggleHoverScrub:
            guard let list = projectList else { return false }
            list.setHoverScrub(!list.hoverScrubOn)
            flash(list.hoverScrubOn ? "Hover Scrub on" : "Hover Scrub off")
        case .projectThumbnailSmaller, .projectThumbnailLarger:
            // The Mac `stepThumbnailSize`: 16 points a step, icon view only.
            guard let list = projectList else { return false }
            guard list.viewMode == .icons else { return true }
            let r = ProjectListView.thumbRange
            list.thumbSize = min(max(list.thumbSize + (c == .projectThumbnailLarger ? 16 : -16), r.lowerBound), r.upperBound)
        case .playInToOutRoll:
            let st = AppSettings.load(from: defaults)
            session.playInToOut(preroll: st.preroll, postroll: st.postroll)
        case .playAround:
            let st = AppSettings.load(from: defaults)
            session.playAround(preroll: st.preroll, postroll: st.postroll)
        case .newBin:
            dock.show(.project)
            focus = dock.focused ?? focus
            guard let list = projectList else { return false }
            list.newFolder()
        case .replaceClipFromProject:
            // Clip > Replace Clip from Project (the Mac `replaceClipFromProject`): same edit as Option-drop.
            guard session.selection.count == 1, let clip = session.selection.first else { flash("Select one clip in the timeline to replace."); return true }
            let picked = projectList?.selection ?? []
            let media = picked.compactMap { if case .media(let id) = $0 { id } else { nil } }
            let seqs = picked.compactMap { if case .sequence(let id) = $0 { id } else { nil } }
            let ok: Bool
            if !media.isEmpty { ok = session.replaceMedia(of: clip, withFirstOf: media) }
            else if seqs.count == 1, let s = seqs.first { ok = session.replaceWithSequence(of: clip, with: s) }
            else { flash("Select one item in the Project panel to replace with."); return true }
            if let e = session.lastError, !ok || media.count > 1 { flash(e) }
        default: return false
        }
        return true
    }

    /// `sq.showCaptionsInMonitor`, the Mac key (AppController+Captions).
    static let captionsInMonitorKey = "sq.showCaptionsInMonitor"

    /// The saved View > Show Captions in Program Monitor choice goes back into the engine at launch (AppKit `restoreCaptionsInMonitor`).
    public func restoreCaptionsInMonitor(defaults: UserDefaults = .standard) {
        if let v = defaults.object(forKey: Self.captionsInMonitorKey) as? Bool { session.engine.showsCaptions = v }
    }

    /// The check marks of the toggles above.
    func viewChecks() -> Set<EditorCommand> {
        var s: Set<EditorCommand> = []
        if session.engine.audioScrubbing { s.insert(.toggleAudioScrubbing) }
        if session.engine.showsCaptions { s.insert(.toggleCaptionsInMonitor) }
        if session.selectionFollowsPlayhead { s.insert(.toggleSelectionFollowsPlayhead) }
        if let list = projectList {
            s.insert(list.viewMode == .list ? .projectListView : .projectIconView)
            if list.hoverScrubOn { s.insert(.toggleHoverScrub) }
        }
        return s
    }

    // MARK: Quick Export

    /// Quick Export: the active sequence with its own platform preset (or the last one used), into `Exports/` next to the
    /// project; no form. The preflight notes and the question about files already there come first (`preflightAndSubmit`).
    func quickExport(defaults: UserDefaults = .standard) async {
        guard let sources = exportSources, let queue = exportQueue else { flash("Export is not available."); return }
        let items = ExportDialogModel.sequenceItems(for: session)
        guard !items.isEmpty else { flash("Nothing to export: there is no sequence."); return }
        let model = ExportDialogModel(sequences: items, initialPreset: nil, sources: sources)
        if let id = session.activeTimelineID, items.contains(where: { $0.id == id }) {
            model.selectedID = id
            model.checkedIDs = [id]
        }
        configureExport?(model)
        QuickExport.applyPreset(to: model, lastPresetID: defaults.string(forKey: Self.lastPresetKey))
        // A preset the platform encoder does not write (HEVC 10-bit, ProRes on Windows): the first one it offers.
        let offered = ShellExport.presets(codecs: exportCodecs, fileOutputs: exportFileOutputs)
        if !offered.contains(where: { $0.id == model.presetID }), let p = offered.first { model.presetID = p.id }
        if let n = QuickExport.rangeNotice(for: model) { onStatus?(n) }
        let dir = QuickExport.directory(projectFile: session.fileURL, lastDirectory: exportDirectory.path,
                                        moviesDirectory: StorageLocations.load().exportFallbackDirectory)
        model.outputDirectory = dir
        guard model.canExport else { flash(model.validationMessages.first ?? "Cannot export this sequence."); return }
        defaults.set(model.presetID, forKey: Self.lastPresetKey)
        guard let ids = await preflightAndSubmit(model, directory: dir, queue: queue), !ids.isEmpty else { return }
        await followExports(ids, in: queue)
    }

    /// The Mac `ExportCoordinator` key of the last preset exported with.
    static let lastPresetKey = "sq.export.lastPresetID"

    // MARK: Import Project

    /// File > Import Project: another .sqproj as a bin (its media and sequences, nothing linked back).
    func importProjectAsBin() async {
        guard let model = projectModel else { flash("Import is not available yet."); return }
        guard let url = await files?.chooseProject() else { return }
        await model.importProjects([url])
        onProjectChanged?()
    }
}
