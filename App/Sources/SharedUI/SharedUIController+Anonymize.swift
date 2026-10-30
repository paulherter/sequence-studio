import SQAppShell
import SQCore
import SQDrawShell
import SQEditorSession

/// Clip > Video Options > Anonymize on the shared UI: the same `AnonymizeFlow` as the AppKit app, with the shared status line
/// and draw-list dialogs.
extension SharedUIController {
    func wireAnonymize() {
        shell.isAnonymizing = { AnonymizeRun.isRunning }
        shell.runAnonymize = { [weak self] in
            guard let self else { return }
            let shell = shell
            AnonymizeFlow.request(session: session, ui: AnonymizeUI(
                setJob: { [weak self] in self?.job = $0.map { SQL10n.string($0) } },
                flashLine: { text, _ in shell.onStatus?(SQL10n.string(text)) },
                warn: { shell.presentMessage($0, $1) },
                info: { shell.presentMessage($0, $1) },
                ask: { name, people, done in
                    Task { @MainActor in done(await shell.askAnonymize(clipName: name, people: people)) }
                },
                checks: { lines, go in
                    Task { @MainActor in if let t = await shell.askAnonymizeChecks(lines: lines) { go(t) } }
                }))
        }
    }
}
