import Foundation
import SQCore
import SQTranscribe

extension CaptionsPanelModel {
    /// Sequence > Transcribe and Create Captions: one command for "transcribe the whole timeline, add as captions". A
    /// transcript that still matches the sequence is reused (its typed corrections stay); otherwise the sequence is
    /// transcribed first (no overwrite question: the command asked for it). Then Create Captions runs with the selected
    /// preset, which the host sets to the default caption look. Returns the captions handed to `onCreateCaptions`;
    /// empty when transcription failed or found no words (`state` says why).
    @discardableResult
    public func transcribeAndCreateCaptions() async -> [Caption] {
        flushEdits()
        if case .transcribing = state { await waitForTranscription() }
        if transcript == nil || isOutdated || state != .ready {
            guard canTranscribe else { return [] }
            transcribe(confirmed: true)
            await waitForTranscription()
        }
        return createCaptions()
    }

    /// Selects the preset Create Captions would pick in the Captions tab: the project's kit caption, else the default
    /// caption look (the last look saved as default), else Standard.
    public func useDefaultCaptionLook(kit: StyleKit?) {
        NamedLookPreset.install(into: self, library: .shared, kit: kit)
    }
}
