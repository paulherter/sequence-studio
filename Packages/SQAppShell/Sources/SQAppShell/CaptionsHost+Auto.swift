import Foundation
import SQCore
import SQDrawShell
import SQEditorSession
import SQInspectorUI
import SQUIKit

extension CaptionsHost {
    /// Shows the Text panel's List tab and starts typing into the caption's row (AppKit `TextPanelView.editCaption`).
    @discardableResult
    public func editCaption(_ id: CaptionItem.ID) -> Bool {
        guard let shell, shell.session.activeTimeline?.captionTracks.contains(where: { $0.items.contains { $0.id == id } }) == true
        else { return false }
        shell.dock.show(.text)
        panel.select(.captions)
        if frame.width > 0 { panel.size = frame.size }
        panel.captions.beginEditing(id)
        return true
    }

    /// Sequence > Transcribe and Create Captions (the AppKit `AppController.transcribeAndCreateCaptions`): opens the Text panel on
    /// its Transcribe tab, then transcribes the sequence and creates captions with the default caption look in one go. The
    /// outcome is said in the status line. Nil (after saying why) when there is nothing to start; otherwise the running task
    /// (the count of captions made).
    @discardableResult
    public func autoCaptions() -> Task<Int, Never>? {
        guard let shell else { return nil }
        guard panel.tabs.contains(.transcript), let model = panel.transcript.model else {
            shell.onStatus?(SQL10n.string("Open a sequence first.")); return nil
        }
        if case .transcribing = model.state { shell.onStatus?(SQL10n.string("Transcription is already running.")); return nil }
        model.useDefaultCaptionLook(kit: shell.session.project.styleKit)
        shell.dock.show(.text)
        panel.select(.transcript)
        shell.onStatus?(SQL10n.string("Transcribing the sequence…"))
        return Task { @MainActor [weak shell] in
            let made = await model.transcribeAndCreateCaptions()
            guard made.isEmpty else { return made.count }
            if case .failed(let message) = model.state { shell?.onStatus?(message) }
            else { shell?.onStatus?(SQL10n.string("No speech found: no captions were created.")) }
            return 0
        }
    }
}
