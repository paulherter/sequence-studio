import Foundation

/// Shared timing helpers for tests with a time budget. ONE source file (Packages/TestSupport), symlinked into every
/// package's test target as `TimingSupport.swift`; edit only the original.
///
/// - `SQTiming.scale`: budgets are multiplied by the observed machine load (1-minute load average per core, floor 1,
///   cap `SQTiming.maxScale` = 4) so a busy parallel run or a second build does not fail a perf test. A real regression
///   (typically 3x or more) still fails because the cap is small and best-of-N removes scheduling noise.
/// - `SQTiming.bestMs`: best of N wall-clock runs (noise only ever adds time, so the minimum is the honest number).
/// - `SQTiming.cpuMs`: process CPU time (not wall), immune to being descheduled; includes all threads of the process.
/// - `SQTiming.waitUntil`: condition polling instead of fixed sleeps.
/// - `SQ_STRICT_TIMING=1`: scale is 1 (original budgets).
enum SQTiming {
    static let maxScale = 4.0

    static var strict: Bool { ProcessInfo.processInfo.environment["SQ_STRICT_TIMING"] == "1" }

    /// Load factor, sampled per call (load changes during a long suite). 1 in strict mode.
    static var scale: Double {
        if strict { return 1 }
        #if os(Windows)
        return 2   // no load average on Windows: fixed allowance
        #else
        var l = [Double](repeating: 0, count: 1)
        guard getloadavg(&l, 1) == 1 else { return 1 }
        let perCore = l[0] / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        return min(maxScale, max(1, perCore * 2))   // load of half the cores already doubles the allowance
        #endif
    }

    /// Iteration ceiling for `for _ in 0..<N where !ready { sleep }` poll loops: they leave as soon as the condition
    /// holds, so a generous ceiling costs nothing on a healthy run and only prevents false failures under load.
    static func polls(_ n: Int) -> Int { strict ? n : n * Int(maxScale * 2) }

    /// Budget scaled by current load.
    static func budget(_ value: Double) -> Double { value * scale }
    static func budget(_ d: Duration) -> Duration { .nanoseconds(Int64(ms(d) * 1e6 * scale)) }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Best (minimum) wall milliseconds of `runs` executions of `body`.
    static func bestMs(runs: Int = 5, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        var best = Double.infinity
        for _ in 0..<max(1, runs) { best = min(best, ms(clock.measure(body))) }
        return best
    }

    /// Best (minimum) average milliseconds per iteration: `rounds` rounds of `iterations` calls.
    static func bestPerIterationMs(rounds: Int = 5, iterations: Int, _ body: () -> Void) -> Double {
        bestMs(runs: rounds) { for _ in 0..<iterations { body() } } / Double(max(1, iterations))
    }

    /// Process CPU milliseconds consumed by `body`.
    static func cpuMs(_ body: () -> Void) -> Double {
        func now() -> Double {
            #if os(Windows)
            return ProcessInfo.processInfo.systemUptime * 1000   // wall clock stands in for CPU time
            #else
            var ts = timespec()
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
            return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1e6
            #endif
        }
        let t0 = now(); body(); return now() - t0
    }

    /// Polls `condition` until true or `timeout` (scaled by load; an upper bound, never a delay on success).
    @discardableResult
    static func waitUntil(timeout: Duration = .seconds(5), poll: Duration = .milliseconds(5),
                          _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + budget(timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { return condition() }
            try? await Task.sleep(for: poll)
        }
        return true
    }

    /// Async-condition variant for actor-isolated state.
    @discardableResult
    static func waitUntil(timeout: Duration = .seconds(5), poll: Duration = .milliseconds(5),
                          _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + budget(timeout)
        while await !condition() {
            if ContinuousClock.now >= deadline { return await condition() }
            try? await Task.sleep(for: poll)
        }
        return true
    }
}
