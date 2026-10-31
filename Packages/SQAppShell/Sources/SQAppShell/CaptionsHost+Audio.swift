import Foundation
import SQCore
import SQDrawShell
import SQEditorSession
import SQInspectorUI
import SQUIKit

/// Sequence > Audio Options > Remove Filler Words and Clip > Audio Options > Disguise Voice on the shared shell: both read the
/// Text panel's transcript, as the AppKit `AppController+FillerWords` and `AppController+DisguiseVoice` do.
extension CaptionsHost {
    func registerAudioCommands() {
        shell?.commandHandlers[.removeFillerWords] = { [weak self] in self?.removeFillerWords() ?? false }
        shell?.commandHandlers[.disguiseVoice] = { [weak self] in self?.disguiseVoice() ?? false }
    }

    /// Finds "um / uh / äh / ähm" in the timed captions (language of the project's transcription), marks them as proposed cuts
    /// and tells how many. With no caption words in the sequence yet, it transcribes and creates captions first.
    func removeFillerWords() -> Bool {
        guard let shell else { return false }
        let hasCaptions = shell.session.activeTimeline?.captionTracks.contains { !$0.items.isEmpty } ?? false
        if !hasCaptions {
            guard let transcribing = autoCaptions() else { return true }
            Task { @MainActor [weak self] in
                guard await transcribing.value > 0 else { return }
                self?.scanFillerWords()
            }
            return true
        }
        scanFillerWords()
        return true
    }

    private func scanFillerWords() {
        guard let shell else { return }
        let session = shell.session
        let language = AppSettings.captionLanguage(forProject: session.project.id)
        let scan = session.proposeFillerWordCuts(language: language)
        shell.onStatus?(Self.fillerWordsText(scan, hasCaptions: session.activeTimeline?.captionTracks.contains { !$0.items.isEmpty } ?? false))
    }

    /// The status line after a filler word scan.
    static func fillerWordsText(_ scan: FillerWords.Scan, hasCaptions: Bool) -> String {
        guard !scan.cuts.isEmpty else {
            let hint = scan.untimedCaptions > 0 ? " " + SQL10n.string("Captions without word timings are skipped: transcribe again.") : ""
            return hasCaptions ? SQL10n.string("No filler words found.") + hint : SQL10n.string("Create captions first: the filler words come from the transcript.")
        }
        let seconds = String(format: "%.1f", Double(scan.total.value) / Double(scan.total.timescale))
        return SQL10n.format(scan.count == 1 ? "%@ filler word marked (%@ s). Clip > Audio Options > Accept All Proposed Cuts removes them, or reject."
                                 : "%@ filler words marked (%@ s). Clip > Audio Options > Accept All Proposed Cuts removes them, or reject.",
                             String(scan.count), seconds)
    }

    /// The Disguise Voice effect on the selected range plus captions for it from the transcript that exists. It never starts a
    /// transcription; without a current transcript it says what is missing.
    func disguiseVoice() -> Bool {
        guard let shell else { return false }
        let session = shell.session
        guard !session.selectedAudioClips.isEmpty else { shell.onStatus?(SQL10n.string("Select an audio clip first.")); return true }
        let model = panel.transcript.model
        model?.flushEdits()
        let transcript = model?.canCreateCaptions == true ? model?.transcript : nil
        session.clearError()
        guard let out = session.disguiseVoice(transcript: transcript, preset: model?.selectedPreset),
              let fd = session.activeTimeline?.frameDuration else {
            shell.onStatus?(session.lastError ?? SQL10n.string("Nothing changed: this range already has Disguise Voice."))
            return true
        }
        shell.onStatus?(out.statusText(frameDuration: fd, hasTranscript: transcript != nil))
        return true
    }
}
