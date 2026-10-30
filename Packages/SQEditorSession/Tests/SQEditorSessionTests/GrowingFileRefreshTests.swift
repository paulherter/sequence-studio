import Foundation
import Testing
import SQCore
import SQLibrary
@testable import SQEditorSession

@Suite struct GrowingFilePolicyTests {
    @Test func offOrNothingOnlineDoesNotPoll() {
        #expect(!GrowingFilePolicy.decide(enabled: false, onlineCount: 3, isPlaying: false, isExporting: false, quietPolls: 0).poll)
        #expect(!GrowingFilePolicy.decide(enabled: true, onlineCount: 0, isPlaying: false, isExporting: false, quietPolls: 0).poll)
    }

    @Test func busyWorkSkipsTheStatsAndWaitsLonger() {
        let idle = GrowingFilePolicy.decide(enabled: true, onlineCount: 2, isPlaying: false, isExporting: false, quietPolls: 0)
        let play = GrowingFilePolicy.decide(enabled: true, onlineCount: 2, isPlaying: true, isExporting: false, quietPolls: 0)
        let exp = GrowingFilePolicy.decide(enabled: true, onlineCount: 2, isPlaying: false, isExporting: true, quietPolls: 0)
        #expect(idle.poll && !play.poll && !exp.poll)
        #expect(play.next > idle.next && exp.next > idle.next)
    }

    @Test func quietProjectBacksOff() {
        let fresh = GrowingFilePolicy.decide(enabled: true, onlineCount: 1, isPlaying: false, isExporting: false, quietPolls: 0)
        let calm = GrowingFilePolicy.decide(enabled: true, onlineCount: 1, isPlaying: false, isExporting: false,
                                            quietPolls: GrowingFilePolicy.quietPollsBeforeBackoff)
        #expect(calm.poll && calm.next > fresh.next)
    }

    @Test func refreshedItemTakesNewLengthAndStamp() {
        let old = MediaRef(name: "a.mov", path: "/a.mov", fingerprint: MediaFingerprint(size: 10, modified: nil, headHash: "h"),
                           duration: Time(5, 1), info: MediaInfo(duration: Time(5, 1)))
        let when = Date(timeIntervalSince1970: 500)
        let new = GrowingFileProbe.refreshed(old, info: MediaInfo(duration: Time(9, 1)), stamp: MediaFileStamp(size: 99, modified: when))
        #expect(new.duration == Time(9, 1) && new.info?.duration == Time(9, 1))
        #expect(new.fingerprint.size == 99 && new.fingerprint.modified == when && new.fingerprint.headHash == "h")
        #expect(new.id == old.id && new.path == old.path)
    }
}

@Suite @MainActor struct GrowingFileSessionTests {
    @Test func growingFileIsReprobedAndReported() async throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("SQGrow-\(UUID().uuidString).mov")
        try Data([1, 2, 3]).write(to: u)
        defer { try? FileManager.default.removeItem(at: u) }
        let m = MediaRef(name: "g.mov", path: u.path, fingerprint: MediaFingerprint(size: 3), duration: Time(5, 1),
                         info: MediaInfo(duration: Time(5, 1)))
        var p = Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [])])
        p.add(m)
        let s = EditorSession(project: p)
        s.mediaInfoProbe = { _ in MediaInfo(duration: Time(8, 1)) }
        var reported: [Set<UUID>] = []
        s.onMediaFilesChanged = { reported.append($0) }
        _ = await s.growingFileTick(enabled: true, isExporting: false)          // baseline
        #expect(reported.isEmpty)
        try Data([1, 2, 3, 4, 5, 6]).write(to: u)
        _ = await s.growingFileTick(enabled: true, isExporting: false)
        #expect(reported == [[m.id]])
        #expect(s.project.media(m.id)?.duration == Time(8, 1))
        _ = await s.growingFileTick(enabled: true, isExporting: false)
        #expect(reported.count == 1)                                             // unchanged: quiet
    }

    @Test func disabledTickTouchesNothing() async throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("SQGrow-\(UUID().uuidString).mov")
        try Data([1]).write(to: u)
        defer { try? FileManager.default.removeItem(at: u) }
        var p = Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [])])
        p.add(MediaRef(name: "g.mov", path: u.path, fingerprint: MediaFingerprint(size: 1), duration: Time(5, 1)))
        let s = EditorSession(project: p)
        var count = 0
        s.onMediaFilesChanged = { _ in count += 1 }
        _ = await s.growingFileTick(enabled: false, isExporting: false)
        try Data([1, 2]).write(to: u)
        _ = await s.growingFileTick(enabled: false, isExporting: false)
        #expect(count == 0)
    }
}
