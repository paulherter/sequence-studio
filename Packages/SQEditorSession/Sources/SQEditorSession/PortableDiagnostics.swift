#if !canImport(os)
import Foundation

/// shortcut: off the Mac `os.Logger` does not exist; this stand-in keeps the call sites and drops the messages.
/// Upgrade to a real log sink (ETW or a file) when the Windows shell gets diagnostics.
struct Logger: Sendable {
    init(subsystem: String, category: String) {}
    func info(_ message: LogMessage) {}
    func debug(_ message: LogMessage) {}
    func notice(_ message: LogMessage) {}
    func error(_ message: LogMessage) {}
}

enum LogPrivacy: Sendable { case `public`, `private`, auto }

struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    struct StringInterpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) {}
        mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .auto) {}
    }
    init(stringLiteral value: String) {}
    init(stringInterpolation: StringInterpolation) {}
}

/// shortcut: the playback probe (SQPlayback `PlayProbe`, `SQ_PLAY_PROBE=1`) is Mac-only; this stand-in is always off.
/// Upgrade when SQPlayback's probe builds on Windows.
enum PlayProbe {
    enum Stage: Sendable { case session }
    static let enabled = false
    static let shared = Recorder()
    static func now() -> Double { 0 }
    struct Recorder: Sendable {
        func note(_ stage: Stage) {}
        func recordPositionCost(ms: Double) {}
        func stage(_ format: String, _ a: Double, _ b: Double = 0) {}
    }
}
#endif
