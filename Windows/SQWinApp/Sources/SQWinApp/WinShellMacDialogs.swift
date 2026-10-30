import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQPremiereImport

/// The shared dialogs the Mac helpers added (Reconnect Media with Pip, Import Checklist, Card Import, Paste Settings, Punch In
/// Cuts, Sequence Match, Anonymize, Create Captions, the color swatch picker): each opened through the shell's own entry,
/// layout-checked, photographed and closed. A dialog the demo project cannot supply is noted, not failed.
extension WinShellTest {
    func addMacDialogs() {
        /// Opens through `open`, checks, photographs `pc-shell-<name>.png`, closes with Escape.
        func screen(_ name: String, required: Bool = true, open: @escaping @MainActor (WinShellTest) -> Bool, close: (@MainActor (WinShellTest) -> Void)? = nil) {
            // The dialog opens through a Task: the next step (0.9 s later) looks for it, so no step blocks the run loop.
            add(0.4, "\(name) opens", { t in
                if !open(t) { print("shell test: skipped \(name): the demo project does not allow it"); t.skipped = name }
            })
            add(0.9, "\(name) check", { t in
                if t.skipped == name { return }
                guard t.app.shell.dialog != nil else {
                    if required { t.expect(false, "\(name) dialog opens") }
                    else { print("shell test: skipped \(name): the demo selection does not allow it") }
                    return
                }
                t.expect(true, "\(name) dialog opens")
                t.checkDialog(name); t.shot = t.folder + "\\pc-shell-\(name).png"
            })
            add(0.3, "\(name) closes", { t in
                guard t.app.shell.dialog != nil else { return }
                if let close { close(t) }
                t.closeDialog(name)
            })
        }
        func v1Clips(_ a: AppController) -> [Clip] { a.timeline.tracks.first { $0.name == "V1" }?.clips ?? [] }

        // Paste Settings: copy the first V1 clip, select the second.
        screen("pastesettings", required: false, open: { t in
            let c = v1Clips(t.app)
            guard c.count >= 2 else { return false }
            t.app.session.select(clips: [c[0].id]); _ = t.app.session.copySelection()
            t.app.session.select(clips: [c[1].id])
            t.app.shell.perform(.command(.pasteAttributes)); return true
        })
        screen("punchin", required: false, open: { t in
            let c = v1Clips(t.app)
            guard c.count >= 2 else { return false }
            t.app.session.select(clips: Set(c.map(\.id)))
            t.app.shell.perform(.command(.punchInCuts)); return true
        })
        // Reconnect Media: the first media file steps aside for the dialog (Pip in the footer), then comes back.
        // Reconnect Media: the real dialog needs offline media, and the decoder keeps the sample file open (it cannot be
        // moved here), so the same sheet (band footer, Pip) is built by hand.
        screen("reconnect", open: { t in
            let d = ShellDialog("Reconnect Media", informative: "1 file is offline. Choose a folder to search.")
            d.width = 440
            d.addButton("Locate…")
            d.addButton("Done", role: .cancel)
            d.sheetStyle = true
            d.footerMascot = true
            Task { @MainActor in _ = await t.app.shell.ask(d) }
            return true
        })
        // Import Checklist: a report with one row of each status.
        screen("importchecklist", required: false, open: { t in
            var r = PRImportReport()
            r.note("Lumetri Color", .approximated, "Curves are read as a gain.")
            r.note("Warp Stabilizer", .dropped, "Not supported.")
            r.note("Cross Dissolve", .mapped)
            t.app.shell.importChecklist = ShellImportChecklist(report: r, project: t.app.session.project, fileName: "Demo.prproj")
            t.app.shell.perform(.importChecklist); return true
        })
        // Card Import: the test folder holds the sample media.
        screen("cardimport", required: false, open: { t in
            t.app.shell.openCardImport(volume: URL(fileURLWithPath: t.folder)); return true
        }, close: { t in t.app.shell.closeCardImport(volume: URL(fileURLWithPath: t.folder)) })
        screen("sequencematch", open: { t in
            let cur = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1001, 30000))
            let new = SequenceFormat(width: 3840, height: 2160, frameDuration: Time(1, 25))
            Task { @MainActor in _ = await t.app.shell.askChangeSequenceFormat(cur, new) }; return true
        })
        screen("anonymize", open: { t in
            let people = [0, 1].map { i in
                AnonymizePerson(label: UInt8(i), point: Vec2(0.3 + 0.3 * Double(i), 0.5),
                                box: AnonymizeBox(x: 0.2 + 0.3 * Double(i), y: 0.3, width: 0.2, height: 0.5), face: nil)
            }
            Task { @MainActor in _ = await t.app.shell.askAnonymize(clipName: "Shot A", people: people, defaults: UserDefaults(suiteName: "sq.win.test") ?? .standard) }
            return true
        })
        screen("captions", open: { t in
            let styles = [ShellCaptionStyle(name: "Standard", maxChars: 42, lines: 2, minSeconds: 1, gapFrames: 2),
                          ShellCaptionStyle(name: "Social", maxChars: 20, lines: 1, minSeconds: 0.5, gapFrames: 0)]
            Task { @MainActor in _ = await t.app.shell.askCreateCaptions(styles: styles, selected: 0) }; return true
        })
        screen("replacetranscript", open: { t in
            Task { @MainActor in _ = await t.app.shell.confirmReplaceTranscript() }; return true
        })
        // The color swatch picker: New Color Matte, a click on the swatch row.
        add(0.4, "swatch dialog opens", { t in
            _ = t.app.openTimelineEditor(.newColorMatte)
        })
        add(0.5, "swatch click", { t in
            guard let f = t.app.shell.dialog?.form, let i = f.rows.firstIndex(where: { if case .color = $0 { true } else { false } }) else {
                return t.expect(false, "New Color Matte has a swatch row")
            }
            let s = t.app.timelinePanel.scale, p = CGPoint(x: f.controlFrames[i].midX, y: f.controlFrames[i].midY)
            t.app.handle(.mouseDown(x: Float(p.x) * s, y: Float(p.y) * s, modifiers: []))
            t.app.handle(.mouseUp(x: Float(p.x) * s, y: Float(p.y) * s))
        })
        add(0.8, "swatch check", { t in
            t.expect(t.app.shell.dialog?.form?.pickerOpen == true, "the swatch opens the color picker")
            t.shot = t.folder + "\\pc-shell-swatch.png"
        })
        add(0.3, "swatch closes", { t in
            t.app.handle(.keyDown(.escape, modifiers: []))
            if t.app.shell.dialog != nil { t.closeDialog("swatch") }
        })
    }
}
