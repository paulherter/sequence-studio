import AppKit
import os

/// Launch milestones, logged (os_log, public) as `SQLaunch +<ms since process start> (<ms since previous>) <name>`.
/// Read with `log show --last 2m --predicate 'process == "Sequence Studio" AND eventMessage CONTAINS "SQLaunch"'`.
/// Milestones stop at the first window update (window on screen); `note` logs later events (background scans).
@MainActor
enum LaunchTiming {
    private static let logger = Logger(subsystem: "de.paulherter.SequenceStudio", category: "launch")
    /// Process start time (kernel), in seconds since 1970.
    private static let processStart: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }()
    private static var last: Double?
    private static var finished = false
    private static var observer: NSObjectProtocol?

    static func mark(_ name: String) {
        guard !finished else { return }
        note(name)
    }

    static func note(_ name: String) {
        let now = Date().timeIntervalSince1970
        let line = String(format: "SQLaunch +%.0f ms (%.0f ms) %@", (now - processStart) * 1000, (now - (last ?? processStart)) * 1000, name)
        logger.notice("\(line, privacy: .public)")
        last = now
    }

    /// The last milestone: the first `NSWindow.didUpdateNotification` after launch (the window is on screen).
    static func finishOnFirstWindowUpdate() {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                mark("window updated (visible)")
                finished = true
                if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
            }
        }
    }
}
