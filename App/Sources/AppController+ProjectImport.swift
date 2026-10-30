import AppKit
import SQEditorUI

/// File > Import Project…: brings another Sequence Studio project into the current one as a bin (Project panel).
extension AppController {

    @objc func importProjectAsBin(_ sender: Any?) {
        panels.projectView.runImportProjectPanel()
    }
}
