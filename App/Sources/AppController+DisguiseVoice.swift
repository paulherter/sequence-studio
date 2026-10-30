import AppKit
import SQCore
import SQEditorUI

extension AppController {
    /// Clip > Audio Options > Disguise Voice: the Disguise Voice effect on the selected range plus captions for it from the
    /// transcript that exists. It never starts a transcription; without a current transcript it says what is missing.
    /// Every message ends with the note that this is not a guarantee.
    func requestDisguiseVoice() {
        guard !session.selectedAudioClips.isEmpty else { shell.statusBar.flash("Select an audio clip first."); return }
        let model = panels.textView.captionsModel
        model?.flushEdits()
        let transcript = model?.canCreateCaptions == true ? model?.transcript : nil
        session.clearError()
        guard let out = session.disguiseVoice(transcript: transcript, preset: model?.selectedPreset),
              let fd = session.activeTimeline?.frameDuration else {
            // A refusal says why itself (locked track, locked linked audio); otherwise the effect was there already.
            shell.statusBar.flash(session.lastError ?? "Nothing changed: this range already has Disguise Voice.", seconds: 6)
            return
        }
        shell.statusBar.flash(out.statusText(frameDuration: fd, hasTranscript: transcript != nil), seconds: 8)
    }
}
