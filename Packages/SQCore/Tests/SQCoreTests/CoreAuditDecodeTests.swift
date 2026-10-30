import Foundation
import Testing
@testable import SQCore

/// H6 core audit items 3 (corrupt files must not load) and 4 (v9 -> v10 scale migration without probe info).
@Suite struct CoreAuditDecodeTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private let fd = Time(1, 30)

    private func clip(_ start: Int64, _ len: Int64, media: UUID = UUID()) -> Clip {
        Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: s(len)), start: s(start))
    }

    private func project(_ clips: [Clip]) -> Project {
        Project(name: "t", timelines: [Timeline(name: "T", format: SequenceFormat(frameDuration: fd),
                                                tracks: [Track(kind: .video, clips: clips)])])
    }

    /// The encoded project as JSON, with `edit` applied to the first track's clip array.
    private func file(_ p: Project, version: Int = ProjectFile.currentVersion,
                      editClips: ([[String: Any]]) -> [[String: Any]] = { $0 }) throws -> Data {
        let encoded = try ProjectFile.encode(p)
        var obj = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        obj["formatVersion"] = version
        var proj = try #require(obj["project"] as? [String: Any])
        var tls = try #require(proj["timelines"] as? [[String: Any]])
        var tracks = try #require(tls[0]["tracks"] as? [[String: Any]])
        let clips = try #require(tracks[0]["clips"] as? [[String: Any]])
        tracks[0]["clips"] = editClips(clips)
        tls[0]["tracks"] = tracks; proj["timelines"] = tls; obj["project"] = proj
        return try JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: Item 3

    @Test func timeRangeDecodeRejectsNegativeDuration() throws {
        let json = #"{"start":{"value":0,"timescale":1},"duration":{"value":-5,"timescale":1}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TimeRange.self, from: Data(json.utf8)) }
        let ok = #"{"start":{"value":0,"timescale":1},"duration":{"value":5,"timescale":1}}"#
        let decoded = try JSONDecoder().decode(TimeRange.self, from: Data(ok.utf8))
        #expect(decoded.duration == s(5))
    }

    @Test func decodeRejectsNegativeDuration() throws {
        let data = try file(project([clip(0, 5)])) { clips in
            clips.map { c in
                var c = c
                c["source"] = ["start": ["value": 0, "timescale": 1], "duration": ["value": -5, "timescale": 1]]
                return c
            }
        }
        #expect(throws: ProjectFileError.corrupt) { try ProjectFile.decode(data, migrations: ProjectFile.migrations) }
    }

    @Test func decodeSortsClipsByStart() throws {
        let data = try file(project([clip(0, 2), clip(4, 2), clip(8, 2)])) { $0.reversed() }
        let p = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        #expect(p.timelines[0].tracks[0].clips.map(\.start) == [s(0), s(4), s(8)])
    }

    @Test func decodeRejectsOverlappingClips() throws {
        let data = try file(project([clip(0, 5), clip(10, 2)])) { clips in
            var c = clips
            c[1]["start"] = ["value": 3, "timescale": 1]
            return c
        }
        #expect(throws: ProjectFileError.corrupt) { try ProjectFile.decode(data, migrations: ProjectFile.migrations) }
    }

    @Test func decodeDropsZeroLengthClipsAndTheirTransitions() throws {
        let a = clip(0, 5), b = clip(5, 5)
        var p = project([a, b])
        p.timelines[0].tracks[0].transitions = [Transition(kind: .crossDissolve, duration: s(1), outgoing: a.id, incoming: b.id)]
        let data = try file(p) { clips in
            var c = clips
            c[1]["source"] = ["start": ["value": 0, "timescale": 1], "duration": ["value": 0, "timescale": 1]]
            return c
        }
        let loaded = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        #expect(loaded.timelines[0].tracks[0].clips.map(\.id) == [a.id])
        #expect(loaded.timelines[0].tracks[0].transitions.isEmpty)
    }

    @Test func validFileStillRoundTrips() throws {
        let a = clip(0, 5), b = clip(5, 5)
        var p = project([a, b])
        p.timelines[0].tracks[0].transitions = [Transition(kind: .crossDissolve, duration: s(1), outgoing: a.id, incoming: b.id)]
        let loaded = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(loaded.timelines[0].tracks[0] == p.timelines[0].tracks[0])
    }

    @Test func newerVersionStillRefusedBeforeLeniency() throws {
        let data = try file(project([clip(0, 5)]), version: ProjectFile.currentVersion + 1) { $0.reversed() }
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        }
    }

    // MARK: Item 4

    private func mediaRef(w: Int, h: Int) -> MediaRef {
        let v = VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 10, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        return MediaRef(name: "m", path: "/m.mov", fingerprint: MediaFingerprint(size: 1), duration: s(10),
                        info: MediaInfo(duration: s(10), video: v))
    }

    /// A v9 file (1920x1080 sequence) with one clip at Scale 200 % whose media has no probe info.
    private func v9WithoutInfo() throws -> (Data, MediaRef) {
        let m = mediaRef(w: 3840, h: 2160)
        var bare = m
        bare.info = nil
        var c = clip(0, 5, media: m.id)
        c.animation.scale = AnimatedProperty(Vec2(2, 2))
        c.animation.scale.track.insert(Keyframe(time: s(1), value: Vec2(4, 4)))
        var p = project([c])
        p.timelines[0].format = SequenceFormat(width: 1920, height: 1080, frameDuration: fd)
        p.add(bare)
        return (try file(p, version: 9), m)
    }

    @Test func v9ScaleMigrationWithoutInfo() throws {
        let (data, m) = try v9WithoutInfo()
        var p = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        var c = p.timelines[0].tracks[0].clips[0]
        #expect(c.animation.scale.value == Vec2(2, 2))           // unknown size: left alone for now
        #expect(c.pendingSourcePixelScale)
        // The flag survives a save at the current version.
        p = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(p.timelines[0].tracks[0].clips[0].pendingSourcePixelScale)
        // Link Media brings probe info: the deferred v10 step runs now (fit 0.5).
        let replaced = p.replaceMedia(m.id, with: m); #expect(replaced)
        c = p.timelines[0].tracks[0].clips[0]
        #expect(c.animation.scale.value == Vec2(1, 1))
        #expect(c.animation.scale.track.keys[0].value == Vec2(2, 2))
        #expect(!c.pendingSourcePixelScale)
        // Runs once: another replace leaves it alone.
        let again = p.replaceMedia(m.id, with: m); #expect(again)
        #expect(p.timelines[0].tracks[0].clips[0].animation.scale.value == Vec2(1, 1))
    }

    @Test func pendingScaleFollowsSplitHalves() throws {
        let (data, m) = try v9WithoutInfo()
        var p = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        try p.timelines[0].tracks[0].split(at: s(2))
        #expect(p.timelines[0].tracks[0].clips.count == 2)
        let pending = p.timelines[0].tracks[0].clips.allSatisfy(\.pendingSourcePixelScale)
        #expect(pending)
        let replaced = p.replaceMedia(m.id, with: m); #expect(replaced)
        let done = p.timelines[0].tracks[0].clips.allSatisfy { !$0.pendingSourcePixelScale && $0.animation.scale.value == Vec2(1, 1) }
        #expect(done)
    }

    @Test func currentFilesNeverGetThePendingFlag() throws {
        let m = mediaRef(w: 3840, h: 2160)
        var bare = m
        bare.info = nil
        var p = project([clip(0, 5, media: m.id)])
        p.add(bare)
        let loaded = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(!loaded.timelines[0].tracks[0].clips[0].pendingSourcePixelScale)
        let saved = try ProjectFile.encode(loaded)
        let json = try #require(String(data: saved, encoding: .utf8))
        #expect(!json.contains("pendingSourcePixelScale"))
    }
}
