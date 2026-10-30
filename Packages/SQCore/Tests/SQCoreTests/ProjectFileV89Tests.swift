import Foundation
import Testing
@testable import SQCore

// v89: a reversed transition (`Transition.reversed`, `TransitionLayer.reversed`) travels the other way. A v88 build would
// play it forwards and drop the flag on save; at v89 it refuses the file. A transition that is not reversed stores no key.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }
private func clip(_ name: String, start: Int64) -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(start), mediaDuration: f(300))
}

private func project(reversed: Bool) throws -> (Project, Transition.ID) {
    var v1 = Track(kind: .video)
    let a = clip("A", start: 0), b = clip("B", start: 60)
    try v1.overwrite(a); try v1.overwrite(b)
    var tl = Timeline(name: "T", frameDuration: fd, tracks: [v1])
    let tid = try tl.addTransition(kind: .push, track: v1.id, outgoing: a.id, incoming: b.id, duration: f(12))
    if reversed { try tl.setTransition(tid, reversed: true) }
    return (Project(name: "P", timelines: [tl]), tid)
}

@Suite struct ProjectFileV89Tests {
    @Test func unreversedKeepsLowestVersionAndNoKey() throws {
        let (p, _) = try project(reversed: false)
        #expect(!p.containsV89Content)
        let a = String(decoding: try ProjectFile.encode(p), as: UTF8.self)
        let (q, _) = try project(reversed: true)
        let b = String(decoding: try ProjectFile.encode(q), as: UTF8.self)
        #expect(b.components(separatedBy: "\"reversed\"").count == a.components(separatedBy: "\"reversed\"").count + 1)
        #expect(ProjectFile.writtenVersion(for: p) < 89)
    }

    @Test func reversedWritesV89AndRoundTrips() throws {
        let (p, tid) = try project(reversed: true)
        #expect(ProjectFile.writtenVersion(for: p) == 89)
        let data = try ProjectFile.encode(p)
        for m in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(data, migrations: m)
            #expect(back == p)
            #expect(back.timelines[0].tracks[0].transitions.first { $0.id == tid }?.reversed == true)
        }
    }

    @Test func oldFileWithoutKeyDecodesAsNotReversed() throws {
        let (p, _) = try project(reversed: false)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].transitions.allSatisfy { !$0.isReversed })
    }

    @Test func reversedFlipsTheRenderDirection() throws {
        let (p, tid) = try project(reversed: true)
        let tr = try #require(p.timelines[0].tracks[0].transitions.first { $0.id == tid })
        #expect(tr.effectiveDirection == .left)
        #expect(tr.renderDirection == .right)
        #expect(TransitionDirection.up.opposite == .down)
    }

    @Test func aV88BuildRefusesAV89File() throws {
        let (p, _) = try project(reversed: true)
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: (any Error).self) { try ProjectFile.decode(data, migrations: nil) }
    }
}
