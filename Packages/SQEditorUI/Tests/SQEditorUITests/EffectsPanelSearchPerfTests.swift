import AppKit
import Foundation
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

/// Opt-in: `SQ_PERF=1 SQ_TEST_FILTER=EffectsPanelSearchPerfTests scripts/test.sh SQEditorUI`.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["SQ_PERF"] == "1")) struct EffectsPanelSearchPerfTests {
    @Test func searchLatencyPerKeystroke() {
        let d = UserDefaults(suiteName: "sq.test.perf.\(UUID().uuidString)")!
        let panel = EffectsPanelView(defaults: d)
        panel.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        panel.layoutSubtreeIfNeeded()
        var worst = 0.0, total = 0.0
        let typed = ["g", "ga", "gau", "gaus", "gauss", "gaussian", "gaussian ", "gaussian b", "gaussian bl", "gaussian blur", "", "g", "t", "tr"]
        for q in typed {
            let t0 = threadCPUNanos()   // CPU time, not wall time: stable under machine load
            panel.typeSearch(q)
            panel.layoutSubtreeIfNeeded()
            let ms = Double(threadCPUNanos() - t0) / 1e6
            worst = max(worst, ms); total += ms
        }
        let line = String(format: "SQ_PERF effects search: mean %.2f ms, worst %.2f ms over %d keystrokes", total / Double(typed.count), worst, typed.count)
        try? line.write(toFile: "/private/tmp/claude-501/sq_effects_search_perf.txt", atomically: true, encoding: .utf8)
        #expect(worst < 50, Comment(rawValue: line))
    }
}

/// CPU time of the calling thread (the shared one lives with the timeline tests in SQTimelineUI).
private func threadCPUNanos() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}
