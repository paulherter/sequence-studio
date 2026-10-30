import AppKit
import SQCore
import SQEditorUI

extension AppController {
    /// Sequence > Audio Options > Remove Filler Words: finds "um / uh / äh / ähm" in the timed captions (language of the project's
    /// transcription), marks them as proposed cuts and tells how many. Accept All Proposed Cuts removes them in one undo step.
    /// With no caption words in the sequence yet, it transcribes and creates captions first (the filler words come from the
    /// transcript), then scans.
    func requestRemoveFillerWords() {
        let hasCaptions = session.activeTimeline?.captionTracks.contains { !$0.items.isEmpty } ?? false
        if !hasCaptions {
            guard let transcribing = transcribeAndCreateCaptions() else { return }
            Task { @MainActor [weak self] in
                guard await transcribing.value > 0 else { return }
                self?.scanFillerWords()
            }
            return
        }
        scanFillerWords()
    }

    private func scanFillerWords() {
        let language = AppSettings.captionLanguage(forProject: session.project.id)
        let scan = session.proposeFillerWordCuts(language: language)
        guard !scan.cuts.isEmpty else {
            let hasCaptions = session.activeTimeline?.captionTracks.contains { !$0.items.isEmpty } ?? false
            let hint = scan.untimedCaptions > 0 ? " " + SQL10n.string("Captions without word timings are skipped: transcribe again.") : ""
            shell.statusBar.flash(hasCaptions ? SQL10n.string("No filler words found.") + hint : "Create captions first: the filler words come from the transcript.", seconds: 4)
            return
        }
        let seconds = String(format: "%.1f", Double(scan.total.value) / Double(scan.total.timescale))
        shell.statusBar.flash(SQL10n.format(scan.count == 1 ? "%@ filler word marked (%@ s). Clip > Audio Options > Accept All Proposed Cuts removes them, or reject." : "%@ filler words marked (%@ s). Clip > Audio Options > Accept All Proposed Cuts removes them, or reject.", String(scan.count), seconds), seconds: 6)
    }
}
