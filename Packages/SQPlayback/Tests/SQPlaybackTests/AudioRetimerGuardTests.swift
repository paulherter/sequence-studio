import Testing
import Foundation
@testable import SQPlayback

/// A caller bug (oversized block, speed over the cap) must not trap a release build: silence for the excess, clamped speed.
@Suite struct AudioRetimerGuardTests {
    private let read: AudioRetimer.Read = { _, count, dst in
        for i in 0..<count { dst[i] = 1 }
        return count
    }

    @Test func oversizedBlockIsSilencedInsteadOfTrapping() throws {
        let r = AudioRetimer(maxFrames: 256)
        var out = [Float](repeating: 7, count: 400)
        try out.withUnsafeMutableBufferPointer { p in
            try r.render(read: read, origin: 0, speed: 1, reversed: false, keepsPitch: false, srcStart: 0, srcEnd: 10_000,
                         firstOutput: 0, count: 400, into: p.baseAddress!)
        }
        #expect(out[256...].allSatisfy { $0 == 0 })
        #expect(out[0] != 7)
    }

    @Test func speedOverCapIsClamped() throws {
        let r = AudioRetimer(maxFrames: 256)
        var out = [Float](repeating: 0, count: 128)
        try out.withUnsafeMutableBufferPointer { p in
            try r.render(read: read, origin: 0, speed: 500, reversed: false, keepsPitch: false, srcStart: 0, srcEnd: 1_000_000,
                         firstOutput: 0, count: 128, into: p.baseAddress!)
        }
        #expect(out.allSatisfy { $0.isFinite })
    }

    @Test func mappedOversizedBlockIsSilenced() throws {
        let r = AudioRetimer(maxFrames: 64)
        var out = [Float](repeating: 7, count: 100)
        try out.withUnsafeMutableBufferPointer { p in
            try r.renderMapped(read: read, position: { (Double($0), false) }, keepsPitch: false, srcStart: 0, srcEnd: 10_000,
                               firstOutput: 0, count: 100, into: p.baseAddress!)
        }
        #expect(out[64...].allSatisfy { $0 == 0 })
    }
}
