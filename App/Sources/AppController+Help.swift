import AppKit
import SQCore
import SQEditorUI

extension AppController {
    @objc func openSupportPage(_ sender: Any?) { NSWorkspace.shared.open(SupportLinks.url) }
    @objc func openDiscord(_ sender: Any?) { if let u = SupportLinks.discord { NSWorkspace.shared.open(u) } }
    @objc func openGitHub(_ sender: Any?) { NSWorkspace.shared.open(SupportLinks.github) }

    /// Rows of the top-bar heart popover: a wrapping caption, a separator, then the entries with leading icons.
    func supportMenuItems() -> [SQMenuItem] {
        var items: [SQMenuItem] = [.caption(SupportLinks.tagline), .separator]
        for e in SupportLinks.entries {
            let run: @MainActor () -> Void
            switch e {
            case .support: run = { [weak self] in self?.openSupportPage(nil) }
            case .discord: run = { [weak self] in self?.openDiscord(nil) }
            case .github: run = { [weak self] in self?.openGitHub(nil) }
            }
            items.append(SQMenuItem(title: e.menuTitle, action: run)
                .withLeading(symbol: SQIcon(rawValue: e.symbol) ?? .unknown, tint: e == .support ? Theme.Colors.support : nil))
        }
        return items
    }

    @objc func showSupportMenu(_ sender: NSView) { SQContextMenu.popUp(items: supportMenuItems(), belowTrailing: sender) }

    static func bundledSupporters() -> [String] {
        guard let url = Bundle.main.url(forResource: SupportersList.fileName, withExtension: SupportersList.fileExtension),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return SupportersList.parse(text)
    }

    @objc func sendFeedback(_ sender: Any?) {
        let v = AppVersion.display
        let b = AppVersion.build
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        if let url = FeedbackLinks.mailURL(appVersion: v, build: b, os: "macOS " + os) { NSWorkspace.shared.open(url) }
    }

    /// Shows the app log (`sq.log`) in Finder, with the newest Sequence Studio crash report selected next to it if there is one.
    @objc func revealLogs(_ sender: Any?) {
        let fm = FileManager.default
        SQLog.shared.flush()
        let reports = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let files = (try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newestCrash = files.filter { $0.lastPathComponent.hasPrefix("Sequence Studio") }
            .max { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                 < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var items: [URL] = []
        if fm.fileExists(atPath: SQLog.shared.currentFile.path) { items.append(SQLog.shared.currentFile) }
        if let newestCrash { items.append(newestCrash) }
        if items.isEmpty {
            try? fm.createDirectory(at: SQLog.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(SQLog.directory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(items)
        }
    }
}
