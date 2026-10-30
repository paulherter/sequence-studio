import AppKit
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQInspectorUI
import SQPremiereImport
import SQTranscribe
import SQUIKit

/// The alert, report and prompt dialogs of the Mac parity audit (`render-panels.sh` `dialog-relink`, `-import-report`,
/// `-save-changes`, `-recovery`, `-notice-*`, `-confirm-destructive`, `window-card-import`), opened through the real shell
/// code paths on the demo project and shot one by one. Each one is closed again before the next.
@MainActor
extension SharedUIShot {
    static func alertSweep(_ c: SharedUIController, selected: Clip.ID, shot: (String) -> Void) async {
        func close() async {
            if let d = c.shell.dialog, let r = d.model.response(forReturn: false) { d.press(r) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        func open(_ name: String, wait: Duration = .milliseconds(400), _ body: () -> Void) async {
            await close()
            body()
            try? await Task.sleep(for: wait)
            guard c.shell.dialog != nil else { print("shared ui shot: \(name) not available"); return }
            shot("shared-dialog-\(name).png")
        }
        // Reconnect Media: the demo media is offline.
        await open("relink") { c.shell.perform(.relinkMedia) }
        // The import checklist (the Mac ImportReportSheet's rows), with the Mac fixture's three notes.
        await open("import-report") {
            var r = PRImportReport()
            r.note("Lumetri Color", .approximated, "Mapped to the color grade; curves are simplified.")
            r.note("Cross Dissolve", .mapped)
            r.note("Warp Stabilizer", .dropped, "No equivalent yet.")
            c.shell.importChecklist = ShellImportChecklist(report: r, project: c.session.project, fileName: "TikTok Schnitt-Tricks.prproj")
            c.shell.perform(.importChecklist)
        }
        c.shell.importChecklist = nil
        await open("save-changes") {
            if let clip = c.session.activeTimeline?.tracks.flatMap(\.clips).first(where: { $0.id == selected }) {
                c.session.select(clips: [selected])
                c.session.renameSelectedClip(to: clip.name + " ")
                c.session.select(clips: [])
            }
            c.shell.spawn { _ = await c.shell.confirmDiscardChanges() }
        }
        await close()
        _ = c.session.undo()
        await open("recovery") {
            c.shell.spawn {
                _ = await c.shell.ask(ShellHost.recoveryDialog(projectName: "TikTok Schnitt-Tricks", date: Date(timeIntervalSince1970: 1_790_000_000)))
            }
        }
        await open("notice-warning") {
            c.shell.presentMessage("Media offline", "2 files could not be found. Reconnect them to see the picture again.")
        }
        await open("notice-error") {
            c.shell.presentError("Project could not be saved", NSError(domain: "SQ", code: 1, userInfo: [NSLocalizedDescriptionKey: "The disk is full."]))
        }
        // Sequence Match: the demo sequence against a 1920x1080 clip (`render-panels.sh` dialog-sequence-match).
        await open("sequence-match") {
            guard let f = c.session.activeTimeline?.format else { return }
            c.shell.spawn {
                _ = await c.shell.askChangeSequenceFormat(f, SequenceFormat(width: 1920, height: 1080, frameDuration: f.frameDuration))
            }
        }
        // Create Captions and the overwrite question of the Text panel (`dialog-create-captions`, `dialog-replace-transcript`).
        await open("create-captions") {
            let model = CaptionsPanelModel(service: UnavailableTranscriptionService())
            model.frameDuration = c.session.activeTimeline?.format.frameDuration ?? model.frameDuration
            c.shell.spawn { _ = await c.shell.askCreateCaptions(styles: CaptionsHost.styles(of: model), selected: 0) }
        }
        // Anonymize: the sheet with two people found (`dialog-anonymize`).
        await open("anonymize") {
            let people = [0.2, 0.7].map { x in
                AnonymizePerson(label: 1, point: Vec2(x, 0.5), box: AnonymizeBox(x: x - 0.1, y: 0.2, width: 0.2, height: 0.7), face: nil)
            }
            c.shell.spawn { _ = await c.shell.askAnonymize(clipName: "C2156.MP4", people: people) }
        }
        await open("replace-transcript") { c.shell.spawn { _ = await c.shell.confirmReplaceTranscript() } }
        await open("confirm-destructive") {
            let d = ShellDialog("Delete preset “My Look”?", informative: "This cannot be undone.")
            d.addButton("Delete", role: .destructive)
            d.addButton("Cancel", role: .cancel)
            c.shell.spawn { _ = await c.shell.ask(d) }
        }
        await close()
        // Card import: eight demo clips C0012...C0019, three ticked (`window-card-import`).
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("SQRenderDemoMedia", isDirectory: true)
        try? await RenderDemoProject.writeMedia(into: media)
        let volume = FileManager.default.temporaryDirectory.appendingPathComponent("SQRenderCard", isDirectory: true)
        try? FileManager.default.removeItem(at: volume)
        try? FileManager.default.createDirectory(at: volume.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        let demoSources = ["C2140.MP4", "C2147.MP4", "C2152.MP4", "C2156.MP4", "C2160.MP4"]
        let newest = DateComponents(calendar: .current, year: 2026, month: 10, day: 3, hour: 14, minute: 12).date ?? Date()
        for i in 0..<8 {
            let dst = volume.appendingPathComponent("DCIM/C00\(12 + i).MP4")
            try? FileManager.default.copyItem(at: media.appendingPathComponent(demoSources[i % demoSources.count]), to: dst)
            try? FileManager.default.setAttributes([.modificationDate: newest.addingTimeInterval(-Double(i) * 300)], ofItemAtPath: dst.path)
        }
        await open("card-import", wait: .seconds(2)) { c.shell.openCardImport(volume: volume) }
        if let b = ShellCardImport.current {
            let v = b.visible
            for i in [3, 1, 0] where v.indices.contains(i) { b.click(v[i].id, toggle: true) }   // the preview ends on the first
            try? await Task.sleep(for: .milliseconds(500))
            shot("shared-dialog-card-import.png")
        }
        await close()
    }
}
