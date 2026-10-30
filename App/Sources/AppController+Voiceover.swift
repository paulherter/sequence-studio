import AppKit
import SQCore
import SQEditorUI
import SQMedia

extension AppController {
    /// Voiceover from Text: the sheet asks for text, voice and speed; the voice is rendered on this Mac into a CAF file, imported
    /// like any media (so it follows the project's import mode) and placed at the playhead on a free audio track.
    func requestVoiceover() {
        guard session.activeTimeline != nil else { shell.statusBar.flash("Open a sequence first."); return }
        let voices = SpeechRenderer.voices()
        let choices = voices.map {
            VoiceoverVoiceChoice(id: $0.id, title: "\($0.name) (\($0.language))" + ($0.isEnhanced ? " - enhanced" : ""))
        }
        let initial = SpeechRenderer.defaultVoiceID(in: voices, remembered: VoiceoverMemory.voice())
        VoiceoverDialog.present(on: window, voices: choices, initialVoice: initial, initialRate: VoiceoverMemory.rate()) { [weak self] request in
            guard let self, let request else { return }
            VoiceoverMemory.remember(voice: request.voiceID, rate: request.rate)
            Task { await self.insertVoiceover(request) }
        }
    }

    private func insertVoiceover(_ request: VoiceoverRequest) async {
        let start = session.playhead
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sequence Studio/Voiceovers", isDirectory: true)
        let taken = Set(session.project.media.map { ($0.path as NSString).lastPathComponent })
            .union((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let file = Voiceover.fileName(for: request.text, existing: taken)
        let url = folder.appendingPathComponent(file)
        shell.statusBar.flash("Making the voiceover…", seconds: 30)
        let length: Time
        do { length = try await SpeechRenderer.render(text: request.text, voiceID: request.voiceID, rate: request.rate, to: url) }
        catch {
            shell.statusBar.flash(error as? SpeechError == .noAudio ? "This voice made no sound. Pick another voice." : "Could not make the voiceover.", seconds: 8)
            return
        }
        mediaPlacement.markGenerated([url])
        await panels.projectModel.importFiles([url])
        guard let id = panels.projectModel.mediaID(forImported: url) else {
            shell.statusBar.flash("Could not import the voiceover.", seconds: 8); return
        }
        if session.placeVoiceover(media: id, name: Voiceover.clipName(fromFile: file), duration: length, at: start) != nil {
            shell.statusBar.flash("Voiceover added on a Dialogue track.", seconds: 4)
        }
    }
}
