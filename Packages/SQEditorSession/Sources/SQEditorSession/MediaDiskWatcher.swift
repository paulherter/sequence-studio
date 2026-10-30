import AppKit
import Foundation

/// Forwards workspace notifications as `MediaDiskEvent`s. Main actor only; `stop()` (or deinit) removes the observers.
@MainActor
public final class MediaDiskWatcher {
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private let handler: @MainActor (MediaDiskEvent) -> Void

    public init(handler: @escaping @MainActor (MediaDiskEvent) -> Void) {
        self.handler = handler
        let ws = NSWorkspace.shared.notificationCenter
        let table: [(NotificationCenter, Notification.Name, MediaDiskEvent)] = [
            (ws, NSWorkspace.didMountNotification, .mounted),
            (ws, NSWorkspace.didUnmountNotification, .unmounted),
            (ws, NSWorkspace.willUnmountNotification, .unmounted),
            (ws, NSWorkspace.willSleepNotification, .willSleep),
            (ws, NSWorkspace.screensDidSleepNotification, .willSleep),
            (ws, NSWorkspace.didWakeNotification, .didWake),
            (ws, NSWorkspace.screensDidWakeNotification, .didWake),
            (.default, NSApplication.didBecomeActiveNotification, .activated),
        ]
        for (center, name, event) in table {
            let t = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handler(event) }
            }
            tokens.append((center, t))
        }
    }

    public func stop() {
        for (center, t) in tokens { center.removeObserver(t) }
        tokens = []
    }
}
