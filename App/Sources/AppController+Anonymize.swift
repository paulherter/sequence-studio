import AppKit
import SQEditorSession
import SQEditorUI

/// Clip > Video Options > Anonymize on the AppKit app: the flow is `AnonymizeFlow`, the status line and sheets are ours.
extension AppController {
    var isAnonymizing: Bool { AnonymizeRun.isRunning }

    func requestAnonymize() {
        let bar = shell.statusBar
        AnonymizeFlow.request(session: session, ui: AnonymizeUI(
            setJob: { bar.setJob($0) },
            flashLine: { bar.flash($0, seconds: $1) },
            warn: { [weak self] in if let w = self?.window { SQDialog.warn($0, message: $1, in: w) } },
            info: { [weak self] in if let w = self?.window { SQDialog.info($0, message: $1, in: w) } },
            ask: { [weak self] name, people, done in
                guard let w = self?.window else { return done(nil) }
                AnonymizeDialog.present(on: w, clipName: name, people: people, completion: done)
            },
            checks: { [weak self] lines, go in
                guard let w = self?.window else { return }
                AnonymizeDialog.presentChecks(on: w, lines: lines, go: go)
            }))
    }
}
