import Foundation
import SQCore
import SQEditorSession
import SQUIKit

/// The app menu's About and the Help menu rows on the canvas, translated from the Mac AppController+About / +Help /
/// +HistoryWelcome: About (name, version line, tagline, Support and GitHub), the support pages, Send Feedback (prefilled
/// mail), Reveal Logs and Reports and Check for Updates (`UpdateCheck`). Links open through `ShellHost.openURL`.
/// shortcut: About shows no app icon, supporters list or Acknowledgments page (the Mac `AboutDialog` body is AppKit);
/// upgrade by drawing that body with the canvas image slots.
extension ShellHost {
    /// The Help and About rows; false for other actions.
    func performHelp(_ a: ShellAction) -> Bool {
        switch a {
        case .about: spawn { await self.showAbout() }
        case .support(let e): if let u = SupportLinks.url(for: e) { openURL?(u) }
        case .sendFeedback:
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            #if os(Windows)
            let system = "Windows " + os
            #else
            let system = "macOS " + os
            #endif
            if let u = FeedbackLinks.mailURL(appVersion: AppVersion.display, build: AppVersion.build, os: system) { openURL?(u) }
        case .revealLogs: revealLogs()
        case .checkForUpdates: spawn { await self.checkForUpdates() }
        default: return false
        }
        return true
    }

    /// The app log in the file browser (the Mac also selects the newest crash report; Windows writes none yet).
    public func revealLogs() {
        SQLog.shared.flush()
        let log = SQLog.shared.currentFile
        if FileManager.default.fileExists(atPath: log.path) {
            revealFile?(log)
        } else {
            try? FileManager.default.createDirectory(at: SQLog.directory, withIntermediateDirectories: true)
            openURL?(SQLog.directory)
        }
    }

    /// Help > Check for Updates (`checkForUpdatesItem` / `presentUpdate`).
    public func checkForUpdates() async {
        let outcome: UpdateCheck.Outcome = UpdateCheck.feedURL.isEmpty ? .notConfigured
            : await UpdateCheck.check(localVersion: AppVersion.display)
        let d = ShellDialog("Check for Updates")
        switch outcome {
        case .notConfigured:
            d.informativeText = "Update checking is not set up in this build. New versions come as a download from the person who sent you this one."
        case .upToDate:
            d.informativeText = SQL10n.format("Sequence Studio %@ is the newest version.", AppVersion.display)
        case .failed:
            d.informativeText = "The update information could not be read. Check your connection and try again later."
        case .available(let r):
            d.messageText = SQL10n.format("Version %@ is available", "\(r.version)")
            d.informativeText = (r.notes.map { $0 + "\n\n" } ?? "") + SQL10n.format("You have %@.", AppVersion.display)
            d.addButton("Download")
            d.addButton("Later", leading: true)
            if await ask(d) == .first, let u = URL(string: r.url) { openURL?(u) }
            return
        }
        d.addButton("OK")
        _ = await ask(d)
    }
}
