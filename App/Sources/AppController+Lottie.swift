import AppKit
import SQEditorUI
import UniformTypeIdentifiers

/// File > Import Lottie Animation…: places a Lottie .json the user picked as a clip at the playhead. Nothing is bundled:
/// the file is read once and stored inside the project.
extension AppController {

    @objc func importLottieAnimation(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Lottie animation (.json). It is stored inside the project."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLottie(at: url)
    }

    func importLottie(at url: URL) {
        if session.addLottieClip(contentsOf: url) == nil, let message = session.lastError {
            let alert = SQDialog()
            alert.style = .warning
            alert.messageText = SQL10n.format("Could not import “%@”", url.lastPathComponent)
            alert.informativeText = message
            if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
        }
    }
}
