import Foundation
import SQCore
import WinSDK

/// The startup self-log testers can send: `%LOCALAPPDATA%\Sequence Studio\Crash Reports\startup.log` is rewritten at
/// every launch (steps, adapter and driver, decoder used, fallbacks taken); a start that cannot go on also writes a
/// `crash-<time>.txt` there naming the failing step, and says so in a message box (no window exists yet to say it in).
/// Force the fallback paths with SQ_FORCE_WARP=1 (software D3D12) and SQ_FORCE_SW_DECODE=1 (no D3D11VA).
enum StartupLog {
    private static let state = NSLock()
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var currentStep = "launch"
    nonisolated(unsafe) private static var decoders = 0
    static var url: URL { CrashReportStore.defaultDirectory.appendingPathComponent("startup.log") }

    static func begin() {
        let env = ProcessInfo.processInfo.environment
        note("Sequence Studio on \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.activeProcessorCount) cores")
        if let why = env["SQ_WARP_REASON"] { note("restarted on WARP after a GPU start failure: \(why)") }
        note("forced: warp=\(env["SQ_FORCE_WARP"] == "1") softwareDecode=\(env["SQ_FORCE_SW_DECODE"] == "1")")
    }

    /// Names the step now running; a failure report says which one it was.
    static func step(_ name: String) {
        state.lock(); currentStep = name; state.unlock()
        note("step: \(name)")
    }

    static func note(_ line: String) {
        state.lock()
        lines.append(line)
        let text = lines.joined(separator: "\n") + "\n"
        state.unlock()
        let dir = CrashReportStore.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The first few decoders opened: which codec ran on D3D11VA or in software.
    static func decoderOpened(_ description: String) {
        state.lock(); decoders += 1; let n = decoders; state.unlock()
        if n <= 8 { note("decoder: \(description)") }
    }

    /// A GPU step failed on real hardware (device, swap chain or quad pipeline a driver refuses): start once more with
    /// SQ_FORCE_WARP=1, so the app opens on the software rasterizer instead of not at all. Only for a normal launch (scripted
    /// runs have `--` flags and report instead) and only once (the second start has SQ_FORCE_WARP set).
    /// SQ_SIMULATE_GPU_FAIL=1 makes the first start fail there (tests this path on a machine whose GPU works).
    private static func relaunchWithWarp(step: String, message: String) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard env["SQ_FORCE_WARP"] != "1", step.hasPrefix("create engine") || step.hasPrefix("create window"),
              !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) else { return false }
        note("GPU start failed at '\(step)': starting again on WARP (software D3D12)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = Array(CommandLine.arguments.dropFirst())
        var e = env
        e["SQ_FORCE_WARP"] = "1"
        e["SQ_WARP_REASON"] = "\(step): \(message)"
        p.environment = e
        do { try p.run(); return true } catch { note("relaunch failed: \(error)"); return false }
    }

    /// A start that cannot go on: report file, message box, exit.
    static func fail(_ message: String) -> Never {
        state.lock(); let step = currentStep; state.unlock()
        note("FAILED at step '\(step)': \(message)")
        state.lock(); let text = lines.joined(separator: "\n"); state.unlock()
        if relaunchWithWarp(step: step, message: message) { exit(0) }
        let saved = try? CrashReportStore().write("Sequence Studio could not start.\nFailed step: \(step)\nError: \(message)\n\n\(text)\n")
        print("error: \(message)")
        let shown = "Sequence Studio could not start.\n\nFailed step: \(step)\n\(message)\n\nReport: \((saved ?? url).path)\nPlease send this file to the developer."
        // shortcut: a system message box, the one place outside the SQ design (no window or renderer exists yet); replace
        // with an SQ dialog drawn on the software renderer if starts fail often.
        // Scripted runs (any --flag) only print: a box would hang them.
        if !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { _ = shown.withCString(encodedAs: UTF16.self) { body in
            "Sequence Studio".withCString(encodedAs: UTF16.self) { title in MessageBoxW(nil, body, title, UINT(MB_OK | MB_ICONERROR)) }
        } }
        exit(1)
    }
}
