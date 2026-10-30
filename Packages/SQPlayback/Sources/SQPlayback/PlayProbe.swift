import Foundation
import MachO
import Darwin
import QuartzCore
import Synchronization
import SQCore

/// Diagnostics for the real app (`SQ_PLAY_PROBE=1`, docs/PLAYBACK-PERF.md "Seek in the real app"): per playhead jump the
/// time from the input event to each stage up to the frame on the glass, and while playing the publish -> `apply` delay,
/// the cost of the session's position handler and the main run-loop stalls. Off (the default): every call site checks
/// `enabled` first, one cached Bool, no lock, no allocation.
public final class PlayProbe: Sendable {
    /// Read once per process.
    public static let enabled: Bool = ProcessInfo.processInfo.environment["SQ_PLAY_PROBE"] == "1"
    /// `SQ_PLAY_PROBE_HEADLESS=1`: tick from a timer instead of the display link (locked screen: no window is ever visible).
    public static let headless: Bool = enabled && ProcessInfo.processInfo.environment["SQ_PLAY_PROBE_HEADLESS"] == "1"
    public static let shared = PlayProbe()

    /// 60 Hz timer standing in for the display link.
    final class Ticker: Sendable {
        private let timer: DispatchSourceTimer
        init(_ tick: @escaping @Sendable () -> Void) {
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sq.playprobe.ticker", qos: .userInteractive))
            t.schedule(deadline: .now(), repeating: .microseconds(16_667), leeway: .microseconds(500))
            t.setEventHandler(handler: tick)
            t.resume()
            timer = t
        }
        func stop() { timer.cancel() }
    }

    /// Stages of one jump, in order. t0 is the input event (ruler press, jump command).
    public enum Stage: Int, CaseIterable, Sendable {
        /// `EditorSession` received the command.
        case session
        /// The engine issued the seek (step started, prefetch planned).
        case request
        /// The render thread presented the first picture at the target (a keyframe stand-in counts).
        case firstFrame
        /// The render thread presented the complete exact frame at the target.
        case exact
        /// `apply` ran on the main thread for it.
        case applied
        /// The drawable with the exact frame reached the glass.
        case glass
        public var title: String { ["session", "request", "firstFrame", "exact", "applied", "glass"][rawValue] }
    }

    public struct Seek: Sendable, Equatable {
        public var label: String
        public var t0: Double
        /// Host time of each stage, 0 = not reached.
        public var marks = [Double](repeating: 0, count: Stage.allCases.count)
        public var target: Time?
        /// Milliseconds from t0 to `stage`, nil if not reached.
        public func ms(_ stage: Stage) -> Double? {
            let m = marks[stage.rawValue]
            return m > 0 ? (m - t0) * 1000 : nil
        }
    }

    public struct Stats: Sendable, Equatable {
        public var count = 0
        public var p50 = 0.0, p95 = 0.0, p99 = 0.0, worst = 0.0
        public init(_ values: [Double]) {
            let v = values.sorted()
            count = v.count
            guard !v.isEmpty else { return }
            func at(_ q: Double) -> Double { v[min(max(Int((q * Double(v.count)).rounded(.up)) - 1, 0), v.count - 1)] }
            p50 = at(0.5); p95 = at(0.95); p99 = at(0.99); worst = v[v.count - 1]
        }
        public var text: String {
            count == 0 ? "n=0" : String(format: "n=%d p50 %.1f p95 %.1f p99 %.1f worst %.1f ms", count, p50, p95, p99, worst)
        }
    }

    private struct State {
        var pending: Seek?
        var done: [Seek] = []
        var applyDelays: [Double] = []
        var positionCosts: [Double] = []
        var stalls: [Double] = []
    }
    private let state = Mutex(State())

    public init() {}

    public static func now() -> Double { CACurrentMediaTime() }

    /// t0: the input event. A jump that was still pending is dropped (the user moved on).
    public func begin(_ label: String, now: Double = PlayProbe.now()) {
        state.withLock { $0.pending = Seek(label: label, t0: now) }
    }

    /// Marks `stage` of the pending jump (first time only). `.session` without a pending jump starts one (a command
    /// that did not come through `begin`, e.g. a jump-to-cut key). `target` is the grid time the engine seeks to.
    public func note(_ stage: Stage, target: Time? = nil, now: Double = PlayProbe.now()) {
        state.withLock { s in
            if s.pending == nil {
                guard stage == .session else { return }
                s.pending = Seek(label: "command", t0: now)
            }
            if s.pending!.marks[stage.rawValue] == 0 { s.pending!.marks[stage.rawValue] = now }
            if let target { s.pending!.target = target }
        }
    }

    /// A jump is pending, the engine has seeked and its target is known: the render thread checks each presented tick.
    public var awaitingFrame: Time? {
        state.withLock { s in
            guard let p = s.pending, p.marks[Stage.request.rawValue] > 0, p.marks[Stage.glass.rawValue] == 0 else { return nil }
            return p.target
        }
    }

    /// The exact frame is published and not applied yet (main thread).
    public var awaitingApply: Bool {
        state.withLock { s in
            guard let p = s.pending else { return false }
            return p.marks[Stage.exact.rawValue] > 0 && p.marks[Stage.applied.rawValue] == 0
        }
    }

    /// The exact-frame drawable reached the glass at `t` (`MTLDrawable.presentedTime`; 0 = never shown): completes the jump.
    public func glass(at t: Double) {
        state.withLock { s in
            guard var p = s.pending, p.marks[Stage.exact.rawValue] > 0, t > 0 else { return }
            p.marks[Stage.glass.rawValue] = t
            if p.marks[Stage.applied.rawValue] == 0 { p.marks[Stage.applied.rawValue] = t }
            s.done.append(p); s.pending = nil
        }
    }

    /// The pending jump's reached stages (for a log line when it never completes).
    public var pendingText: String {
        state.withLock { s in
            guard let p = s.pending else { return "none pending" }
            let parts = Stage.allCases.map { st in "\(st.title) \(p.ms(st).map { String(format: "%.0f", $0) } ?? "-")" }
            return parts.joined(separator: ", ") + " target \(String(describing: p.target)) "
        }
    }

    public var completedCount: Int { state.withLock { $0.done.count } }
    public func completed() -> [Seek] { state.withLock { $0.done } }

    public func recordApplyDelay(ms: Double) { state.withLock { $0.applyDelays.append(ms) } }
    public func recordPositionCost(ms: Double) { state.withLock { $0.positionCosts.append(ms) } }
    public func recordStall(ms: Double) { state.withLock { $0.stalls.append(ms) } }
    /// A timed piece of main-thread work (ms) in the log.
    public func stage(_ format: String, _ a: Double, _ b: Double = 0) { NSLog("PLAYPROBE " + format, a, b) }
    private let playStart = Mutex(0.0)
    /// Stalls are logged with their offset from here (play start), so a stall at the start of play is told apart.
    public func markPlayStart() { playStart.withLock { $0 = PlayProbe.now() } }
    func logStall(ms: Double, at t: Double) {
        let p = playStart.withLock { $0 }
        if p > 0, ms > 8 { NSLog("PLAYPROBE stall %.1f ms at +%.0f ms after play start", ms, (t - ms / 1000 - p) * 1000) }
        else if ms > 8 { NSLog("PLAYPROBE stall %.1f ms outside the play window (before play start)", ms) }
    }

    /// Runs `body`; with the probe on and play started, logs pieces over 1 ms with their offset from play start
    /// (attribution of a stall without `sample`, which perturbs the run). Off: a single Bool check.
    @inline(__always)
    public static func timed<T>(_ label: @autoclosure () -> String, over ms: Double = 1, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let t0 = now()
        let r = body()
        let t1 = now()
        let p = shared.playStart.withLock { $0 }
        if p > 0, t1 - t0 > ms / 1000 {
            NSLog("PLAYPROBE mark %@ %.1f ms at +%.0f ms", label(), (t1 - t0) * 1000, (t0 - p) * 1000)
        }
        return r
    }

    public func reset() { state.withLock { $0 = State() } }

    /// The summary as log lines.
    public func report() -> [String] {
        let s = state.withLock { $0 }
        var out = ["PLAYPROBE seeks: \(s.done.count) completed"]
        for stage in Stage.allCases {
            let v = s.done.compactMap { $0.ms(stage) }
            guard !v.isEmpty else { continue }
            out.append("PLAYPROBE seek t0->\(stage.title): \(Stats(v).text)")
        }
        for (i, k) in s.done.enumerated() {
            let parts = Stage.allCases.compactMap { st in k.ms(st).map { String(format: "%@ %.0f", st.title, $0) } }
            out.append("PLAYPROBE seek #\(i + 1) \(k.label): " + parts.joined(separator: ", "))
        }
        out.append("PLAYPROBE publish->apply: \(Stats(s.applyDelays).text)")
        out.append("PLAYPROBE enginePositionChanged: \(Stats(s.positionCosts).text)")
        out.append("PLAYPROBE main run-loop iterations > 8 ms: \(Stats(s.stalls).text)")
        return out
    }

    public func logReport() { for l in report() { NSLog("%@", l) } }

    /// One drawable of a pending jump: completes the jump when it is armed (the tick presented the exact frame) and the
    /// presented handler has reported the glass time, whichever comes last.
    final class GlassSlot: Sendable {
        private struct S { var presented: Double?; var armed = false }
        private let s = Mutex(S())
        func arm() { finish { $0.armed = true } }
        func presented(at t: Double) { finish { $0.presented = t } }
        private func finish(_ change: (inout S) -> Void) {
            let t = s.withLock { st -> Double? in
                change(&st)
                return st.armed ? st.presented : nil
            }
            if let t { PlayProbe.shared.glass(at: t) }
        }
    }

    // MARK: Main run-loop stalls

    private static let watching = Mutex(false)
    private static let iterationStart = Mutex(0.0)

    /// Records every main run-loop iteration longer than the threshold (work from wake-up to going back to sleep, after
    /// Core Animation's commit). Call once on the main thread.
    public static func watchMainRunLoop(threshold: Double = 0.008) {
        guard enabled, watching.withLock({ let was = $0; $0 = true; return !was }) else { return }
        let activities = CFRunLoopActivity([.afterWaiting, .beforeWaiting]).rawValue
        let obs = CFRunLoopObserverCreateWithHandler(nil, activities, true, Int.max) { _, activity in
            let t = PlayProbe.now()
            if activity == .afterWaiting { iterationStart.withLock { $0 = t }; return }
            let started = iterationStart.withLock { let v = $0; $0 = 0; return v }
            if started > 0, t - started > threshold { shared.recordStall(ms: (t - started) * 1000); shared.logStall(ms: (t - started) * 1000, at: t) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        if ProcessInfo.processInfo.environment["SQ_PLAY_PROBE_STACKS"] == "1" { startStackWatchdog(mainThread: mach_thread_self()) }
    }

    // MARK: Stall attribution (SQ_PLAY_PROBE_STACKS=1)

    /// A background thread looks at the running main iteration every 2 ms; when one has run 6 ms it suspends the main
    /// thread for a few microseconds, copies its frame-pointer backtrace and logs it (`PLAYPROBE stack`), so a stall is
    /// attributed in the same run that measures it (`sample` perturbs the run and starves under load).
    /// Addresses are logged as `image+offset`; resolve with `atos -o <binary> -l <load address>`.
    private static func startStackWatchdog(mainThread: mach_port_t) {
        let thread = Thread {
            var capturedFor = 0.0
            while true {
                usleep(2000)
                let started = iterationStart.withLock { $0 }
                guard started > 0, started != capturedFor, now() - started > 0.006 else { continue }
                capturedFor = started
                let frames = captureStack(of: mainThread)
                let p = shared.playStart.withLock { $0 }
                var lines: [String] = []
                for a in frames {
                    var info = Dl_info()
                    if dladdr(UnsafeRawPointer(bitPattern: a), &info) != 0 {
                        let base = UInt(bitPattern: info.dli_fbase)
                        let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
                        let name = info.dli_sname.map { String(cString: $0) } ?? ""
                        lines.append(String(format: "%@+0x%lx %@", image, a - base, name))
                    } else { lines.append(String(format: "0x%lx", a)) }
                }
                let load = UInt(bitPattern: _dyld_get_image_header(0))
                NSLog("PLAYPROBE stack at +%.0f ms (-1: before play start) (main binary load address 0x%lx): %@", p > 0 ? (started - p) * 1000 : -1.0, load, lines.joined(separator: " | "))
            }
        }
        thread.qualityOfService = .userInteractive
        thread.name = "sq.playprobe.stacks"
        thread.start()
    }

    /// Program counter plus the frame-pointer chain of `thread` (arm64). Nothing allocates while it is suspended.
    static func captureStack(of thread: mach_port_t) -> [UInt] {
        var out = [UInt](repeating: 0, count: 48)
        var n = 0
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let ok = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(thread, ARM_THREAD_STATE64, $0, &count) }
        } == KERN_SUCCESS
        if ok {
            let mask: UInt = 0x0000_000F_FFFF_FFFF
            out[n] = UInt(state.__pc) & mask; n += 1
            out[n] = UInt(state.__lr) & mask; n += 1
            var fp = UInt(state.__fp) & mask
            while fp != 0, fp % 8 == 0, n < out.count {
                guard let p = UnsafePointer<UInt>(bitPattern: fp) else { break }
                let next = p[0] & mask, ret = p[1] & mask
                if ret == 0 { break }
                out[n] = ret; n += 1
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(thread)
        return Array(out[0..<n])
    }
}
