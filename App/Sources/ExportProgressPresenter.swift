import AppKit
import SQCore
import SQEditorUI
import SQExport
import UserNotifications

/// Shows the export progress window for every export that starts running (Export, Quick Export), mirrors the overall
/// progress in the Dock icon and posts a notification when an export ends while the app is in the background.
/// Polls the queue model at 10 Hz only while something is active.
@MainActor
final class ExportProgressPresenter {
    private let queueModel: ExportQueueModel
    private var windows: [UUID: ExportProgressWindow] = [:]
    private var seen = Set<UUID>()
    private var timer: Timer?
    private var dock: DockProgress?
    private var askedForNotifications = false
    private let notificationDelegate = ExportNotificationDelegate()

    init(queueModel: ExportQueueModel) { self.queueModel = queueModel }

    /// Call when jobs were submitted.
    func watch() {
        requestNotificationsOnce()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: ExportProgressWindow.updateInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private func poll() {
        let model = queueModel
        for row in model.jobs where row.state == .running && !seen.contains(row.id) {
            seen.insert(row.id)
            open(row)
        }
        updateDock()
        if !model.hasActiveJobs && windows.isEmpty { stop() }
    }

    /// The quiet reminder under a successful export: at most once per 7 days, off for good after "Don't show again".
    private static var supportPrompt: SupportPrompt {
        let d = UserDefaults.standard
        return SupportPrompt(
            shouldShow: {
                SupportReminder.mayShow(exportSucceeded: true, lastShown: d.object(forKey: SupportReminder.defaultsKey) as? Date,
                                        now: Date(), turnedOff: d.bool(forKey: SupportReminder.offKey))
            },
            didShow: { d.set(Date(), forKey: SupportReminder.defaultsKey) },
            open: { NSWorkspace.shared.open(SupportLinks.url) },
            turnOff: { d.set(true, forKey: SupportReminder.offKey) })
    }

    private func open(_ row: ExportQueueModel.Row) {
        let model = queueModel
        let id = row.id
        let w = ExportProgressWindow(row: row,
                                     source: { model.jobs.first { $0.id == id } },
                                     cancel: { model.cancel($0) },
                                     supportPrompt: Self.supportPrompt,
                                     onClose: { [weak self] in self?.windows[id] = nil })
        w.onFinished = { [weak self] m in self?.finished(m) }
        windows[id] = w
        w.show(near: nil)
    }

    private func finished(_ m: ExportProgressModel) {
        switch m.stage {
        case .done(let url):
            SQLog.info("export finished: \(url.lastPathComponent) in \(ExportProgressTracker.format(seconds: m.elapsed))")
            notifyIfBackground(title: "Export finished", body: url.lastPathComponent, revealing: url)
        case .failed(let msg):
            notifyIfBackground(title: "Export failed", body: "\(m.name): \(SQL10n.localized(msg))")
        default: break
        }
    }

    // MARK: Dock tile

    private func updateDock() {
        let model = queueModel
        if model.hasActiveJobs {
            if dock == nil { dock = DockProgress() }
            dock?.set(fraction: model.overallProgress)
        } else if dock != nil {
            dock?.clear(); dock = nil
        }
    }

    private func stop() { timer?.invalidate(); timer = nil; seen.removeAll() }

    // MARK: Notifications

    private func requestNotificationsOnce() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = notificationDelegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `revealing`: clicking the notification shows that file in Finder.
    private func notifyIfBackground(title: String, body: String, revealing file: URL? = nil) {
        guard !NSApp.isActive, Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        if let file { c.userInfo = [ExportNotificationDelegate.pathKey: file.path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// Click on an "Export finished" notification: shows the exported file in Finder.
final class ExportNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let pathKey = "sq.export.path"

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo[Self.pathKey] as? String else { return }
        await MainActor.run {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
        }
    }
}

/// Dock icon progress bar: the app icon with a thin bar at the bottom while exports run.
@MainActor
final class DockProgress {
    private let bar = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    private var lastDrawn = -1.0

    init() {
        let tile = NSApp.dockTile
        tile.contentView = bar
    }

    func set(fraction: Double) {
        // Redraw the tile only on a visible change (1 %).
        let q = (fraction * 100).rounded() / 100
        guard q != lastDrawn else { return }
        lastDrawn = q
        bar.fraction = q
        NSApp.dockTile.display()
    }

    func clear() {
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

private final class DockProgressView: NSView {
    var fraction = 0.0
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        let h: CGFloat = 12, inset: CGFloat = 8
        let track = NSRect(x: inset, y: 10, width: bounds.width - 2 * inset, height: h)
        Theme.Colors.overlay.setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        let w = max(track.width * CGFloat(min(max(fraction, 0), 1)), h)
        Theme.Colors.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }
}
