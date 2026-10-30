import Foundation
import Synchronization

/// Where a Vision request runs: on the default devices (Neural Engine / GPU), and on the CPU when that throws. Every
/// request falls back by itself, so one failure never decides the next request and two requests failing at the same
/// moment both get their CPU try (before 2026-10-09 a process-wide switch did this: the second of two concurrent failures
/// rethrew without trying the CPU, and after one failure nothing ever went back to the fast path).
///
/// What is remembered is only an order: after a fallback that worked, the next `retryAfter` requests try the CPU first
/// (no failed attempt per frame while the Neural Engine is busy), then the default devices are tried again. Whatever is
/// remembered, a request fails only when both ways threw for that request.
final class ComputeFallback: Sendable {
    private let name: String
    private let retryAfter: Int
    /// Requests left that try the CPU first.
    private let cpuFirst = Mutex(0)

    init(name: String, retryAfter: Int = 120) {
        self.name = name
        self.retryAfter = max(retryAfter, 0)
    }

    /// True while requests try the CPU first.
    var prefersCPU: Bool { cpuFirst.withLock { $0 > 0 } }

    /// Runs `perform` (`cpu`: pin the request to the CPU), and once more the other way when it throws. Throws the error
    /// of the default devices when both ways failed.
    func run<T>(_ perform: (_ cpu: Bool) throws -> T) throws -> T {
        let cpu = cpuFirst.withLock { n -> Bool in
            guard n > 0 else { return false }
            n -= 1
            return true
        }
        do { return try perform(cpu) } catch let first {
            NSLog("[%@] %@ failed, fallback to %@: %@", name, cpu ? "CPU" : "default compute", cpu ? "default compute" : "CPU",
                  Self.describe(first))
            do {
                let r = try perform(!cpu)
                // The CPU worked where the default did not: CPU first for a while. The default worked where the CPU
                // did not: back to the default at once.
                cpuFirst.withLock { $0 = cpu ? 0 : retryAfter }
                return r
            } catch let second {
                cpuFirst.withLock { $0 = 0 }
                NSLog("[%@] both compute paths failed: %@", name, Self.describe(second))
                throw cpu ? second : first
            }
        }
    }

    /// Type, domain, code and text of an error for a log line.
    static func describe(_ error: any Error) -> String {
        let e = error as NSError
        return "\(type(of: error)) \(e.domain) \(e.code): \(e.localizedDescription)"
    }
}
