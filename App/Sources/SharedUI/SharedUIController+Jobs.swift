import AppKit
import Foundation
import SQAnalysis
import SQAppShell
import SQCore
import SQDrawShell
import SQEditorSession
import SQEditorUI
import SQInspectorUI
import UserNotifications

/// Background work of the shared UI, as `AppController.setUpJobCenter` and its proxy service: long-GOP proxies, and the
/// Jobs popover (status ring) listing proxies, transcription, mask tracking, Stabilizer, Anonymize, Conform and Gyroflow
/// with Cancel, like the AppKit task popover (exports have their own list).
extension SharedUIController {
    func wireJobs() {
        // Proxies of heavy sources for every monitor (export always reads the originals); they wait while a monitor plays or an
        // export runs. The cache sits in the folder Settings > Media chose and honors its size cap.
        let settings = AppSettings.load()
        let engine = engine
        session.autoProxy = AutoProxyService.make(resolver: media, engines: [engine], directory: settings.proxyCacheDirectory) {
            [weak self] in
            guard let self else { return false }
            return self.engine.rate != .zero || self.shell.exportProgress != nil
        }
        session.autoProxy?.applyCacheCap(bytes: settings.cacheCapBytes)
        settings.locations.applyWaveformDirectory()

        let center = jobCenter
        if let q = session.autoProxy?.queue { center.register(ProxyJobSource(queue: q)) }
        center.register(TranscriptionJobSource(model: { [weak self] in self?.captions.panel.transcript.model }))
        center.register(MaskTrackJobSource { MaskTrackActivity.shared.stop(reason: "canceled in Background Jobs", keeps: true) })
        center.register(DeferredJobSource { [weak self] in self.map { StabilizeJobSource(model: $0.inspector.model) } })
        center.register(AnonymizeRun.source)
        center.register(ConformJobSource(runner: conformRunner))
        center.register(GyroflowJobSource(engine: GyroflowEngine.shared) { r in
            GyroflowEngine.shared.cancel(path: r.path, options: r.options)
        })
        shell.backgroundJobs = { [center] in
            await center.refresh()
            return center.otherJobs.map { ExportQueuePopover.Background(id: $0.id, title: $0.title, progress: $0.progress) }
        }
        shell.cancelBackgroundJob = { [center] in center.cancel($0) }
        center.startPolling()
        shell.onExportsFinished = { [exportNotifier] done, failed in exportNotifier.finished(done: done, failed: failed) }
    }
}

/// A job source made on first use (the Controls model is built lazily, after the shell is wired).
@MainActor
private final class DeferredJobSource: BackgroundJobSource {
    private let make: @MainActor () -> (any BackgroundJobSource)?
    private var source: (any BackgroundJobSource)?
    init(_ make: @escaping @MainActor () -> (any BackgroundJobSource)?) { self.make = make }

    func currentJobs() async -> [BackgroundJob] {
        if source == nil { source = make() }
        return await source?.currentJobs() ?? []
    }
}

/// What the AppKit `ExportProgressPresenter` does besides its window: the Dock icon shows the overall export progress and a
/// notification (click = show the file) is posted when an export ends while the app is in the background.
@MainActor
final class ExportNotifier {
    private var dock: DockProgress?
    private var asked = false
    private let delegate = ExportNotificationDelegate()

    /// Called every frame with the status ring's value; nil = nothing exports.
    func update(progress: Double?) {
        if let progress {
            if dock == nil { dock = DockProgress(); requestOnce() }
            dock?.set(fraction: progress)
        } else if dock != nil {
            dock?.clear(); dock = nil
        }
    }

    func finished(done: [URL], failed: [String]) {
        if let first = failed.first {
            post(title: "Export failed", body: first, revealing: nil)
        } else if let url = done.first {
            SQLog.info("export finished: \(url.lastPathComponent)")
            post(title: "Export finished", body: url.lastPathComponent, revealing: url)
        }
    }

    private func requestOnce() {
        guard !asked, Bundle.main.bundleIdentifier != nil else { return }
        asked = true
        UNUserNotificationCenter.current().delegate = delegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(title: String, body: String, revealing file: URL?) {
        guard !NSApp.isActive, Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = SQL10n.string(title); c.body = body; c.sound = .default
        if let file { c.userInfo = [ExportNotificationDelegate.pathKey: file.path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
