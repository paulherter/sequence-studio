import AppKit
import SQCore
import SQEditorUI

/// Sequence Studio > About (windows plan section 3): the app icon, name, version, one line, link buttons, License,
/// supporters and credits in the shared modal shell. "Acknowledgments" (left in the footer) opens a second modal with
/// "Back" on the left.
extension AppController {
    @objc func showAbout(_ sender: Any?) { presentAbout() }

    private func presentAbout() {
        let d = SQDialog()
        d.messageText = ""
        d.width = SQModal.Size.sList.width
        d.accessoryView = aboutBody(width: SQModal.Size.sList.width - SQDialogMetrics.sidePad * 2)
        d.addButton("Done", role: .default)
        d.addButton("Acknowledgments", role: .normal, leading: true)
        present(d) { [weak self] r in if r == .second { self?.presentAcknowledgments() } }
    }

    private func present(_ d: SQDialog, completion: (@MainActor (SQDialog.Response) -> Void)? = nil) {
        if let w = window, w.isVisible { d.beginSheetModal(for: w, completion: completion) } else { completion?(d.runModal()) }
    }

    private func aboutBody(width: CGFloat) -> NSView {
        AboutDialog.makeBody(width: width, icon: NSApp.applicationIconImage, versionLine: AppVersion.aboutLine,
                             discord: SupportLinks.discord, supporters: Self.bundledSupporters(), target: self,
                             selector: { l in
                                 switch l {
                                 case .github: #selector(openGitHub(_:))
                                 case .support: #selector(openSupportPage(_:))
                                 case .discord: #selector(openDiscord(_:))
                                 }
                             }, supportSelector: #selector(openSupportPage(_:)))
    }

    private func presentAcknowledgments() {
        let d = SQDialog()
        d.messageText = "Acknowledgments"
        d.width = SQModal.Size.sList.width
        d.accessoryView = AboutDialog.makeAcknowledgmentsBody(width: AboutDialog.bodyWidth)
        d.addButton("Done", role: .default)
        d.addButton("Back", role: .normal, leading: true)
        present(d) { [weak self] r in if r == .second { self?.presentAbout() } }
    }
}
