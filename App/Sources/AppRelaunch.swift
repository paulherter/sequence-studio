import AppKit

/// Quit and open the app again (the interface language and size apply at launch). The new copy is started by a tiny
/// helper that waits until this process is gone, and only once the app really terminates: a canceled quit (unsaved
/// changes prompt) starts nothing.
@MainActor
enum AppRelaunch {
    private static var armed = false

    static func relaunch() {
        if !armed {
            armed = true
            let path = Bundle.main.bundlePath
            let pid = ProcessInfo.processInfo.processIdentifier
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"", path, String(pid)]
                try? p.run()
            }
        }
        NSApp.terminate(nil)
    }
}
