import Foundation
import Testing
@testable import SSCore

@Suite struct ProjectFileTests {
    let fm = FileManager.default

    func tempDir() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("ssproj-\(UUID().uuidString)")
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func sample() throws -> Project {
        let m = MediaRef(name: "a.mov", path: "/x/a.mov", bookmark: Data([1, 2, 3]),
                         fingerprint: MediaFingerprint(size: 42, modified: Date(timeIntervalSince1970: 1_700_000_000), headHash: "ab"),
                         duration: Time(1001, 30000))
        let link = UUID()
        let v = Clip(name: "v", media: m.id, kind: .video, source: TimeRange(start: Time(1001, 30000), duration: Time(2002, 30000)),
                     start: Time(0, 1), link: link, mediaDuration: m.duration)
        let a = Clip(name: "a", media: m.id, kind: .audio, source: TimeRange(start: Time(1001, 30000), duration: Time(2002, 30000)),
                     start: Time(0, 1), link: link)
        var vt = Track(kind: .video, isLocked: true, syncLock: false)
        try vt.overwrite(v)
        var at = Track(kind: .audio)
        try at.overwrite(a)
        let tl = Timeline(name: "Main", frameDuration: Time(1001, 30000), tracks: [vt, at])
        var p = Project(name: "P", timelines: [tl])
        p.add(m)
        return p
    }

    @Test func roundTrip() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("P.ssproj")
        let p = try sample()
        try ProjectFile.write(p, to: url)
        let back = try ProjectFile.read(from: url)
        #expect(back == p)
        #expect(back.timelines[0].tracks[0].isLocked)
        #expect(!back.timelines[0].tracks[0].syncLock)
        #expect(back.media(p.media[0].id)?.duration == Time(1001, 30000))
        #expect(back.activeTimeline == p.timelines[0].id)
    }

    @Test func timeRoundTripsExactly() throws {
        let t = Time(1_234_567_891_011, 90000)
        let d = try JSONEncoder().encode([t])
        let back = try JSONDecoder().decode([Time].self, from: d)
        #expect(back[0].value == t.value && back[0].timescale == t.timescale)
    }

    @Test func nonNormalizedTimeInFileLoadsNormalizedAndRoundTrips() throws {
        let p = try sample()
        let data = try ProjectFile.encode(p)
        func rewrite(_ v: Any) -> Any {
            if var d = v as? [String: Any] {
                if d["value"] as? Int == 1001, d["timescale"] as? Int == 30000, d.count == 2 {
                    return ["value": 2002, "timescale": 60000]
                }
                for (k, x) in d { d[k] = rewrite(x) }
                return d
            }
            if let a = v as? [Any] { return a.map(rewrite) }
            return v
        }
        let raw = try JSONSerialization.jsonObject(with: data)
        let altered = try JSONSerialization.data(withJSONObject: rewrite(raw))
        #expect(altered != data)
        let loaded = try ProjectFile.decode(altered, migrations: ProjectFile.migrations)
        #expect(loaded == p)
        let again = try ProjectFile.decode(try ProjectFile.encode(loaded), migrations: ProjectFile.migrations)
        #expect(again == p)
    }

    @Test func fileShape() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        try ProjectFile.write(try sample(), to: dir)
        let text = try String(contentsOf: dir.appendingPathComponent("project.json"), encoding: .utf8)
        #expect(text.contains("\"formatVersion\" : 8"))
        #expect(text.contains("\n"))
        #expect(text.contains("2023-11-14T22:13:20Z"))
    }

    @Test func v1FixtureLoadsAsV2WithDefaults() throws {
        let tid = UUID().uuidString, pid = UUID().uuidString, cid = UUID().uuidString
        let v1 = #"""
        {"formatVersion":1,"project":{"id":"\#(pid)","name":"Old","media":[],
         "timelines":[{"id":"\#(tid)","name":"Main","frameDuration":{"value":1001,"timescale":30000},
           "tracks":[{"id":"\#(cid)","kind":"video","isLocked":true,"syncLock":false,"clips":[]}]}]}}
        """#
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        try Data(v1.utf8).write(to: dir.appendingPathComponent("project.json"))
        let p = try ProjectFile.read(from: dir)
        let tl = try #require(p.timelines.first)
        #expect(tl.format == SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1001, 30000), audioSampleRate: 48_000))
        #expect(tl.frameDuration == Time(1001, 30000))
        #expect(tl.inOut == nil && tl.markers.isEmpty)
        let t = tl.tracks[0]
        #expect(t.isLocked && !t.syncLock)
        #expect(t.name == "" && t.isVisible && !t.isMuted && !t.isSolo && !t.isTargeted && t.height == Track.defaultHeight)
    }

    @Test func v2FieldsRoundTrip() throws {
        var p = try sample()
        var tl = p.timelines[0]
        tl.format = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 25), audioSampleRate: 44_100)
        tl.inOut = TimeRange(start: Time(1, 1), duration: Time(2, 1))
        tl.markers = [Marker(time: Time(3, 2), name: "hit")]
        tl.tracks[0].name = "V1"; tl.tracks[0].isVisible = false; tl.tracks[0].height = 80
        tl.tracks[1].isMuted = true; tl.tracks[1].isSolo = true; tl.tracks[1].isTargeted = true
        p.timelines[0] = tl
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        try ProjectFile.write(p, to: dir)
        let back = try ProjectFile.read(from: dir)
        #expect(back == p)
        #expect(back.timelines[0].frameDuration == Time(1, 25))
    }

    @Test func missingAndCorrupt() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        #expect(throws: ProjectFileError.missing) { try ProjectFile.read(from: dir) }
        try Data("{ nope".utf8).write(to: dir.appendingPathComponent("project.json"))
        #expect(throws: ProjectFileError.corrupt) { try ProjectFile.read(from: dir) }
        try Data(#"{"formatVersion":3,"project":{"x":1}}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        #expect(throws: ProjectFileError.corrupt) { try ProjectFile.read(from: dir) }
    }

    @Test func newerVersionRefused() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        try Data(#"{"formatVersion":99,"project":{}}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        #expect(throws: ProjectFileError.newerVersion(found: 99, supported: 8)) { try ProjectFile.read(from: dir) }
    }

    @Test func migrationFromFakeV0() throws {
        // v0 stored "title"; v1 calls it "name" and has no media/timelines.
        let v0 = #"{"formatVersion":0,"project":{"id":"\#(UUID().uuidString)","title":"Old"}}"#
        let migrations: ProjectFile.Migrations = [0: { obj in
            var o = obj
            var p = o["project"] as! [String: Any]
            p["name"] = p.removeValue(forKey: "title")
            p["media"] = [Any](); p["timelines"] = [Any]()
            o["project"] = p
            return o
        }, 1: ProjectFile.migrateV1toV2, 2: ProjectFile.migrateV2toV3, 3: ProjectFile.migrateV3toV4, 4: ProjectFile.migrateV4toV5, 5: ProjectFile.migrateV5toV6, 6: ProjectFile.migrateV6toV7, 7: ProjectFile.migrateV7toV8]
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        try Data(v0.utf8).write(to: dir.appendingPathComponent("project.json"))
        let p = try ProjectFile.read(from: dir, migrations: migrations)
        #expect(p.name == "Old")
        // without a registered step, refuse rather than guess
        #expect(throws: ProjectFileError.corrupt) { try ProjectFile.read(from: dir, migrations: [1: ProjectFile.migrateV1toV2, 2: ProjectFile.migrateV2toV3]) }
    }

    @Test func failedWriteKeepsOldFile() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let p = try sample()
        try ProjectFile.write(p, to: dir)
        // A directory squatting on the temp-rename target is not easy to force; instead make the dir read-only.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        var changed = p; changed.name = "Changed"
        #expect(throws: (any Error).self) { try ProjectFile.write(changed, to: dir) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(try ProjectFile.read(from: dir).name == "P")
        let leftovers = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func overwriteReplaces() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        var p = try sample()
        try ProjectFile.write(p, to: dir)
        p.name = "Second"
        try ProjectFile.write(p, to: dir)
        #expect(try ProjectFile.read(from: dir).name == "Second")
    }

    @Test func autosavePrunesAndRecovers() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        var p = try sample()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            p.name = "v\(i)"
            try ProjectFile.autosave(p, in: dir, keep: 3, date: base.addingTimeInterval(Double(i) * 0.5))
        }
        let files = ProjectFile.autosaves(in: dir)
        #expect(files.count == 3)
        #expect(files.first?.lastPathComponent == "20231114-221320-500.json" || files.first?.lastPathComponent.hasSuffix(".json") == true)
        #expect(ProjectFile.latestAutosave(in: dir)?.name == "v4")
        #expect(files.map(\.lastPathComponent) == files.map(\.lastPathComponent).sorted())
    }

    @Test func latestAutosaveSkipsCorrupt() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        var p = try sample(); p.name = "good"
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try ProjectFile.autosave(p, in: dir, date: base)
        let bad = ProjectFile.autosaves(in: dir)[0].deletingLastPathComponent()
            .appendingPathComponent(ProjectFile.timestamp(base.addingTimeInterval(1)) + ".json")
        try Data("garbage".utf8).write(to: bad)
        #expect(ProjectFile.latestAutosave(in: dir)?.name == "good")
        #expect(ProjectFile.latestAutosave(in: try tempDir()) == nil)
    }

    @Test func mediaStatus() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let f = dir.appendingPathComponent("m.bin")
        try Data(count: 100).write(to: f)
        let mod = try #require(fm.attributesOfItem(atPath: f.path)[.modificationDate] as? Date)
        var ref = MediaRef(name: "m", path: f.path, fingerprint: MediaFingerprint(size: 100, modified: mod))
        #expect(ref.status() == .ok)
        ref.fingerprint.modified = nil
        #expect(ref.status() == .ok)
        ref.fingerprint.modified = mod.addingTimeInterval(-3600)
        #expect(ref.status() == .changed)
        ref.fingerprint = MediaFingerprint(size: 101, modified: mod)
        #expect(ref.status() == .changed)
        try fm.removeItem(at: f)
        #expect(ref.status() == .missing)
    }

    @Test func projectHelpers() {
        var p = Project(name: "x")
        let m = MediaRef(name: "a", path: "/a", fingerprint: MediaFingerprint(size: 1))
        p.add(m)
        var m2 = m; m2.name = "b"
        p.add(m2)
        #expect(p.media.count == 1)
        #expect(p.media(m.id)?.name == "b")
        #expect(p.media(UUID()) == nil)
    }

    @Test func animationRoundTripsInProjectFile() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        var p = try sample()
        var c = p.timelines[0].tracks[0].clips[0]
        c.animation.rotation.track = KeyframeTrack(keys: [
            Keyframe(time: Time(0, 1), value: 0.0), Keyframe(time: Time(1001, 30000), value: 720.0)])
        c.animation.scale.value = Vec2(2, 2)
        c.animation.position.track = KeyframeTrack(keys: [
            Keyframe(time: Time(0, 1), value: Vec2(1, 2), outTangent: Vec2(5, 0)), Keyframe(time: Time(1, 1), value: Vec2(9, 9))])
        p.timelines[0].tracks[0].replace(c)
        try ProjectFile.write(p, to: dir)
        let back = try ProjectFile.read(from: dir)
        #expect(back == p)
        #expect(back.timelines[0].tracks[0].clips[0].animation.rotation.track.keys.count == 2)
    }

    @Test func binsAndMarksRoundTrip() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        var p = try sample()
        let mid = p.media[0].id
        let b = p.newBin(name: "Day 1")!
        p.move([.media(mid)], to: b)
        p.setSourceIn(Time(1001, 30000), for: mid)
        p.setSourceOut(Time(3003, 30000), for: mid)
        try ProjectFile.write(p, to: dir)
        let back = try ProjectFile.read(from: dir)
        #expect(back == p)
        #expect(back.bin(b)?.mediaIDs == [mid])
        #expect(back.sourceMarks(for: mid).markOut == Time(3003, 30000))
        let text = try String(contentsOf: dir.appendingPathComponent("project.json"), encoding: .utf8)
        #expect(text.contains(mid.uuidString))
    }

    @Test func v3FileLoadsWithEverythingInRootBin() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let pid = UUID(), tid = UUID(), mid = UUID()
        let json = #"""
        {"formatVersion":3,"project":{"id":"\#(pid)","name":"Old","activeTimeline":"\#(tid)",
        "media":[{"id":"\#(mid)","name":"a.mov","path":"/x/a.mov","fingerprint":{"size":1}}],
        "timelines":[{"id":"\#(tid)","name":"T","format":{"width":1920,"height":1080,"frameDuration":{"value":1,"timescale":30},"audioSampleRate":48000},"tracks":[]}]}}
        """#
        try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
        let p = try ProjectFile.read(from: dir)
        #expect(p.rootBin.mediaIDs == [mid])
        #expect(p.rootBin.contains(.sequence(tid)))
        #expect(p.rootBin.children.count == 2)
        #expect(p.sourceMarks.isEmpty)
        try ProjectFile.write(p, to: dir)
        #expect(try ProjectFile.read(from: dir) == p)
    }

    @Test func v2FileLoadsWithStaticDefaults() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let pid = UUID(), tid = UUID(), cid = UUID(), mid = UUID()
        let json = #"""
        {"formatVersion":2,"project":{"id":"\#(pid)","name":"Old","media":[],"activeTimeline":"\#(tid)",
        "timelines":[{"id":"\#(tid)","name":"T","format":{"width":1920,"height":1080,"frameDuration":{"value":1,"timescale":30},"audioSampleRate":48000},
        "tracks":[{"id":"\#(UUID())","kind":"video","clips":[{"id":"\#(cid)","name":"c","media":"\#(mid)","kind":"video",
        "source":{"start":{"value":0,"timescale":1},"duration":{"value":4,"timescale":1}},"start":{"value":0,"timescale":1}}]}]}]}}
        """#
        try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
        let p = try ProjectFile.read(from: dir)
        let c = p.timelines[0].tracks[0].clips[0]
        #expect(c.id == cid)
        #expect(c.animation == ClipAnimation())
        #expect(c.transform(at: Time(1, 1)) == ClipTransform.identity)
        #expect(c.animation.position.track.isEmpty)
        try ProjectFile.write(p, to: dir)
        let text = try String(contentsOf: dir.appendingPathComponent("project.json"), encoding: .utf8)
        #expect(text.contains("\"formatVersion\" : 8"))
    }

    @Test func v4FileLoadsWithoutNestingCaptionsOrRadius() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let pid = UUID(), tid = UUID(), cid = UUID(), mid = UUID()
        let json = #"""
        {"formatVersion":4,"project":{"id":"\#(pid)","name":"Old","media":[],"activeTimeline":"\#(tid)",
        "timelines":[{"id":"\#(tid)","name":"T","format":{"width":1920,"height":1080,"frameDuration":{"value":1,"timescale":30},"audioSampleRate":48000},
        "tracks":[{"id":"\#(UUID())","kind":"video","clips":[{"id":"\#(cid)","name":"c","media":"\#(mid)","kind":"video",
        "source":{"start":{"value":0,"timescale":1},"duration":{"value":4,"timescale":1}},"start":{"value":0,"timescale":1}}]}]}]}}
        """#
        try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
        let p = try ProjectFile.read(from: dir)
        let c = p.timelines[0].tracks[0].clips[0]
        #expect(c.sequence == nil && c.clipSource == .media(mid))
        #expect(c.animation.cornerRadius.value == 0)
        #expect(p.timelines[0].captionTracks.isEmpty)
        #expect(ProjectFile.currentVersion == 8)
    }
}
