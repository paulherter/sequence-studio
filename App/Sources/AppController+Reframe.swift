import AppKit
import SQEditorSession

/// Clip > Video Options > Auto Reframe: Vision finds the subject in the selected clips (else the clips under the
/// playhead) and Position keys keep it in the sequence frame. Running it again while it analyzes cancels it (the menu
/// item then reads "Cancel Auto Reframe"). The run itself is `AnalysisFlows` (SQEditorSession), shared with the shared window.
extension AppController {
    var isReframing: Bool { analysisFlows.isReframing }

    func requestAutoReframe() {
        guard let what = analysisFlows.reframeSubject() else { return }
        ReframeOptionsDialog.present(on: window, subject: what) { [weak self] options in
            guard let options else { return }
            self?.analysisFlows.runAutoReframe(options: options, what: what)
        }
    }
}
