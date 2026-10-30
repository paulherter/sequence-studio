import Foundation
import Testing
import SQCore
@testable import SQEditAPI

@Suite struct HardeningTests {
    @Test func timeLimits() {
        #expect(TimeLimits.isValid(value: 1, timescale: 25))
        #expect(!TimeLimits.isValid(value: 1, timescale: 0))
        #expect(!TimeLimits.isValid(value: 1, timescale: TimeLimits.maxTimescale + 1))
        #expect(!TimeLimits.isValid(value: .min, timescale: 1))
        #expect(TimeLimits.isValid(value: -TimeLimits.maxSeconds, timescale: 1))
        #expect(!TimeLimits.isValid(value: TimeLimits.maxSeconds + 1, timescale: 1))
    }

    @Test func outOfRangeTimeInCodeIsRefusedBeforeArithmetic() {
        let f = Fixture()
        var p = f.project
        let huge = Time(Int64.max / 2, 3)
        #expect {
            try EditTransaction.apply([.addMarker(at: .s(1), name: ""), .trim(clip: f.a, edge: .tail, by: huge)], to: &p, sequence: f.seq)
        } throws: { ($0 as? TransactionError) == TransactionError(.invalidTime, operationIndex: 1, operation: "trim") }
        #expect(p == f.project)
        #expect(throws: TransactionError.self) { try EditTransaction.preview([.razor(at: huge, tracks: nil)], on: p, sequence: f.seq) }
    }

    /// The largest allowed times against project times on an awkward timescale must fail cleanly or apply, never trap.
    @Test func extremeAllowedTimesDoNotTrap() throws {
        var f = Fixture()
        try f.project.edit(f.seq) { t in t.frameDuration = Time(1001, 90000) }
        let ts = TimeLimits.maxTimescale - 1          // odd, coprime with 90000
        let far = Time(ts * TimeLimits.maxSeconds, ts), back = Time(-ts * TimeLimits.maxSeconds, ts)
        let ops: [EditOperation] = [.razor(at: far, tracks: nil), .razor(at: back, tracks: nil), .trim(clip: f.a, edge: .tail, by: far),
                                    .trim(clip: f.a, edge: .head, by: back), .move(clip: f.b, to: far, track: nil),
                                    .slip(clip: f.a, by: far), .slide(clip: f.b, by: back), .roll(clip: f.a, by: far),
                                    .rippleTrim(clip: f.b, edge: .tail, by: back), .addMarker(at: far, name: ""),
                                    .extract(range: TimeRange(start: .zero, duration: far), tracks: nil)]
        for op in ops {
            var p = f.project
            _ = try? EditTransaction.apply([op], to: &p, sequence: f.seq)
        }
    }

    @Test func errorAfterTheLastOperationHasNoIndex() throws {
        let f = Fixture()
        var p = f.project
        // A sequence that already contains itself: the nesting check at the end of Project.edit refuses any batch.
        let self_ = Clip(name: "self", media: f.seq, kind: .video, source: TimeRange(start: .zero, duration: .s(1)),
                         start: .s(10), sequence: f.seq)
        p.timelines[0].tracks[0] = Track(id: f.v1, kind: .video, clips: p.timelines[0].tracks[0].clips + [self_], name: "V1")
        let snapshot = p
        #expect {
            try EditTransaction.apply([.addMarker(at: .s(1), name: "")], to: &p, sequence: f.seq)
        } throws: { ($0 as? TransactionError) == TransactionError(.edit(.nestingCycle)) }
        #expect(p == snapshot)
    }

    @Test func connectionLimiterCaps() {
        var l = ConnectionLimiter(max: 2)
        let a = l.acquire(), b = l.acquire(), c = l.acquire()
        #expect(a && b && !c)
        l.release()
        let d = l.acquire()
        #expect(d)
        l.release(); l.release(); l.release()
        #expect(l.open == 0)
    }

    #if !os(Windows)   // symlinks need a privilege on Windows; its discovery write is the plain variant (WINDOWS-PLAN seam 2)
    @Test func discoveryNeverFollowsAPlantedSymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqapi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = dir.appendingPathComponent("victim"), url = dir.appendingPathComponent("edit-api.json")
        try Data("keep".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: victim)
        try EditAPIDiscovery(port: 1, token: "t", pid: 1).write(to: url)
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attrs[.type] as? FileAttributeType == .typeRegular && attrs[.posixPermissions] as? Int == 0o600)
    }
    #endif
}
