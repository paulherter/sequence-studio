import AppKit
import Testing
@testable import SQUIKit

/// A dialog opened from a main-queue block (a menu action, a `Task`) holds the main queue: a menu row's action inside
/// that dialog must still run while it is open.
@MainActor
@Suite struct SQAfterEventTests {
    @Test func runsInsideANestedModalLoopStartedFromTheMainQueue() async {
        final class Flags: @unchecked Sendable { var afterEvent = false; var queued = false; var afterEventDuringLoop = false; var queuedDuringLoop = false }
        let flags = Flags()
        _ = NSApplication.shared        // registers the modal mode as a common mode, as in the running app
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SQAfterEvent.run { flags.afterEvent = true }
                    DispatchQueue.main.async { flags.queued = true }
                    // The nested loop of a modal session.
                    let end = Date().addingTimeInterval(0.3)
                    while !flags.afterEvent, Date() < end { RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02)) }
                    flags.afterEventDuringLoop = flags.afterEvent
                    flags.queuedDuringLoop = flags.queued
                }
                done.resume()
            }
        }
        #expect(flags.afterEventDuringLoop)
        #expect(!flags.queuedDuringLoop)      // the reason the menu must not use the main queue
    }
}
