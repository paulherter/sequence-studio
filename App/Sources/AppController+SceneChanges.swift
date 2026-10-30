import AppKit
import SQEditorSession

/// Clip > Video Options > Find Scene Changes: reads the selected video clips (else the ones under the playhead) at low
/// resolution in the background and marks every shot change as a proposed cut. Accept All Proposed Cuts razors the clips
/// there; Reject removes the marks. Choosing it again while it runs cancels it (the menu item reads "Cancel Find Scene Changes").
/// The run itself is `AnalysisFlows` (SQEditorSession), shared with the shared window.
extension AppController {
    var isFindingSceneChanges: Bool { analysisFlows.isFindingSceneChanges }

    func requestFindSceneChanges() { analysisFlows.requestFindSceneChanges() }
}
