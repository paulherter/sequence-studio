import AppKit
import SQCore
import SQEditorUI
import SQUIKit
import UniformTypeIdentifiers

/// W8.3 File > Style Kit: export the project's brand as a `.sqstyle`, import one (adds tokens and looks, keeps the
/// project's own brand), and put every caption in the brand caption style.
extension AppController {
    private var styleKitType: UTType { UTType(filenameExtension: StyleKitFile.fileExtension) ?? .json }

    @objc func exportStyleKit(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [styleKitType]
        panel.nameFieldStringValue = "\(session.displayName).\(StyleKitFile.fileExtension)"
        panel.message = "Export the project's fonts, colors, caption style and motion defaults"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try session.exportStyleKit(to: url) } catch { shell.statusBar.flash(SQL10n.format("Could not export the style kit: %@", SQL10n.errorText(error))) }
    }

    @objc func importStyleKit(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [styleKitType]
        panel.allowsMultipleSelection = false
        panel.message = "Import a style kit (your own fonts and colors stay)"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let r = try session.importStyleKit(from: url)
            let alert = SQDialog()
            alert.messageText = SQL10n.string(r.isEmpty ? "Nothing new in this style kit" : "Style kit imported")
            var lines: [String] = []
            if !r.addedTokens.isEmpty { lines.append("Added: \(r.addedTokens.joined(separator: ", "))") }
            if !r.addedLooks.isEmpty { lines.append("Looks: \(r.addedLooks.joined(separator: ", "))") }
            if !r.keptTokens.isEmpty { lines.append("Kept yours: \(r.keptTokens.joined(separator: ", "))") }
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton("OK")
            alert.runModal()
        } catch { shell.statusBar.flash(SQL10n.format("Could not import “%@”: %@", url.lastPathComponent, SQL10n.errorText(error))) }
    }

    @objc func useKitCaptionStyle(_ sender: Any?) {
        if !session.useKitCaptionStyle() {
            shell.statusBar.flash(SQL10n.string("This project's style kit has no caption style. Import a style kit that has one."))
        }
    }
}
