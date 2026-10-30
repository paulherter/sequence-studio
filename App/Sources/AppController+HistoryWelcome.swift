import AppKit
import SQCore
import SQEditorUI

/// Window > History (undo steps, click to jump), the first-run welcome sheet and the update check (Help).
extension AppController {
    // MARK: History

    @objc func showHistory(_ sender: Any?) {
        guard let w = window, w.isVisible else { return }
        let width = SQModal.Size.sList.width - SQDialogMetrics.sidePad * 2
        let list = HistoryListView(list: session.historyList, width: width)
        list.onPick = { [weak self, weak list] row in
            guard let self else { return }
            self.session.jumpToHistoryRow(row)
            list?.reload(self.session.historyList)
        }
        let d = SQDialog()
        d.messageText = "History"
        d.informativeText = "Click a step to go back to it. Dimmed steps were undone."
        d.width = SQModal.Size.sList.width
        d.accessoryView = list
        d.addButton("Done", role: .default)
        d.beginSheetModal(for: w)
    }

    // MARK: First run

    /// Shows the welcome sheet once per Mac, the first time the editor window is up. The flag is written when the sheet
    /// opens, so it never comes back after a quit or a crash.
    func presentWelcomeIfNeeded() {
        guard !settings.onboardingSeen, !RenderPanels.isRequested, NSClassFromString("XCTestCase") == nil,
              let w = window, w.isVisible, w.sqAttachedSheet == nil else { return }
        settings.onboardingSeen = true
        settings.save()
        showWelcome(over: w)
    }

    @objc func showWelcomeItem(_ sender: Any?) {
        if let w = window, w.isVisible, w.sqAttachedSheet == nil { showWelcome(over: w) }
    }

    private func showWelcome(over w: NSWindow) {
        let d = SQDialog()
        d.messageText = OnboardingContent.title
        d.width = SQModal.Size.sList.width
        d.accessoryView = OnboardingDialog.makeBody(width: SQModal.Size.sList.width - SQDialogMetrics.sidePad * 2)
        d.addButton(OnboardingContent.startButton, role: .default)
        d.addButton(OnboardingContent.skipButton, role: .normal, leading: true)
        d.beginSheetModal(for: w)
    }

    // MARK: Updates

    /// At launch: asks the update address when the setting is on and an address exists; says something only when a
    /// newer version is there.
    func checkForUpdatesAtLaunch() {
        guard settings.checkForUpdates, !UpdateCheck.feedURL.isEmpty, NSClassFromString("XCTestCase") == nil else { return }
        Task { @MainActor in
            let outcome = await UpdateCheck.check(localVersion: AppVersion.display)
            if case .available = outcome { presentUpdate(outcome, silentWhenCurrent: true) }
        }
    }

    @objc func checkForUpdatesItem(_ sender: Any?) {
        guard !UpdateCheck.feedURL.isEmpty else { presentUpdate(.notConfigured, silentWhenCurrent: false); return }
        Task { @MainActor in presentUpdate(await UpdateCheck.check(localVersion: AppVersion.display), silentWhenCurrent: false) }
    }

    private func presentUpdate(_ outcome: UpdateCheck.Outcome, silentWhenCurrent: Bool) {
        let d = SQDialog()
        d.messageText = "Check for Updates"
        switch outcome {
        case .notConfigured:
            d.informativeText = "Update checking is not set up in this build. New versions come as a download from the person who sent you this one."
            d.addButton("OK", role: .default)
        case .upToDate:
            if silentWhenCurrent { return }
            d.informativeText = SQL10n.format("Sequence Studio %@ is the newest version.", AppVersion.display)
            d.addButton("OK", role: .default)
        case .failed:
            if silentWhenCurrent { return }
            d.informativeText = "The update information could not be read. Check your connection and try again later."
            d.addButton("OK", role: .default)
        case .available(let r):
            d.messageText = SQL10n.format("Version %@ is available", "\(r.version)")
            d.informativeText = (r.notes.map { $0 + "\n\n" } ?? "") + SQL10n.format("You have %@.", AppVersion.display)
            d.addButton("Download", role: .default)
            d.addButton("Later", role: .normal, leading: true)
            guard let url = URL(string: r.url) else { return }
            if let w = window, w.isVisible { d.beginSheetModal(for: w) { if $0 == .first { NSWorkspace.shared.open(url) } } }
            return
        }
        if let w = window, w.isVisible { d.beginSheetModal(for: w) } else { d.runModal() }
    }
}
