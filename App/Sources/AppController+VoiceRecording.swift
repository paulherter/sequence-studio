import AppKit
import SQCore
import SQEditorUI
import SQPlayback

extension AppController {
    var isRecordingVoiceOver: Bool { session.voiceRecorder.isBusy }

    /// Record Voice-Over: the status line shows the countdown and the running time. The take is imported like any media (so it
    /// follows the project's import mode) and placed at the playhead where recording began, on a free Dialogue track.
    func requestRecordVoiceOver() {
        guard session.activeTimeline != nil || isRecordingVoiceOver else { shell.statusBar.flash("Open a sequence first."); return }
        let bar = shell.statusBar
        session.voiceRecorder.onChange = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .idle: bar.setJob(nil)
                case .requestingAccess: bar.setJob("Voice-over: waiting for the microphone…")
                case .countdown(let n): bar.setJob("Voice-over starts in \(n)… (press again to cancel)")
                case .recording: self?.trackVoiceRecordingTime()
                }
            }
        }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sequence Studio/Voiceovers", isDirectory: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let step = await session.toggleVoiceRecording(folder: folder) { [weak self] url in
                guard let self else { return nil }
                mediaPlacement.markGenerated([url])
                await panels.projectModel.importFiles([url])
                return panels.projectModel.mediaID(forImported: url)
            }
            switch step {
            case .started, .canceled: break
            case .placed: bar.flash("Voice-over added on a Dialogue track.", seconds: 4)
            case .denied:
                bar.flash("The microphone is off for Sequence Studio. Turn it on in System Settings > Privacy & Security > Microphone.", seconds: 10)
            case .failed(let why): bar.flash(why, seconds: 6)
            }
        }
    }

    /// Updates the status line with the recorded time until recording ends.
    private func trackVoiceRecordingTime() {
        let bar = shell.statusBar
        Task { @MainActor [weak self] in
            while let self, session.voiceRecorder.state == .recording {
                let s = Int(session.voiceRecorder.elapsed)
                bar.setJob(String(format: "Recording voice-over %d:%02d (press again to stop)", s / 60, s % 60))
                try? await Task.sleep(for: .milliseconds(250))
            }
            bar.setJob(nil)
        }
    }
}
