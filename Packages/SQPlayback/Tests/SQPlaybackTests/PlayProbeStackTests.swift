import Darwin
import Foundation
import Testing
@testable import SQPlayback

/// The stall attribution (`SQ_PLAY_PROBE_STACKS=1`) copies another thread's backtrace while it is suspended.
@Suite("PlayProbe stall stacks")
struct PlayProbeStackTests {
    final class Box: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var port: mach_port_t = 0
    }

    @Test("captures the frames of a blocked thread and resumes it")
    func capturesBlockedThread() {
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        let t = Thread {
            box.port = mach_thread_self()
            box.started.signal()
            box.release.wait()
            finished.signal()
        }
        t.start()
        box.started.wait()
        usleep(20_000)
        let frames = PlayProbe.captureStack(of: box.port)
        #expect(frames.count >= 3)
        #expect(frames.allSatisfy { $0 != 0 })
        var info = Dl_info()
        #expect(dladdr(UnsafeRawPointer(bitPattern: frames[0]), &info) != 0)
        box.release.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)   // resumed
    }

    @Test("timed() is silent and returns the value when the probe is off")
    func timedPassesThrough() {
        #expect(PlayProbe.timed("x") { 41 + 1 } == 42)
    }
}
