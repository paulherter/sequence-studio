import Foundation
import Testing
@testable import SQCore

// v57 gate: bundles (`Clip.bundle`, Premiere's Clip > Group) and subclips (`MediaRef.subclip`). Files without them keep
// their older version; v56 files open unchanged.

private let fd30 = Time(1, 30)

private func clip(bundle: UUID? = nil, effects: [ClipEffect] = []) -> Clip {
    var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 90), start: .zero,
                 effects: effects)
    c.bundle = bundle
    return c
}

private func project(_ clips: [Clip]) throws -> Project {
    var tracks: [Track] = []
    for c in clips { var t = Track(kind: .video); try t.overwrite(c); tracks.append(t) }
    return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30),
                                                   tracks: tracks)])
}

private func withSubclip() throws -> (Project, MediaRef.ID) {
    var p = try project([clip()])
    let m = MediaRef(name: "A.mov", path: "/v/A.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1))
    p.add(m)
    let id = try p.makeSubclip(of: m.id, range: TimeRange(start: Time(2, 1), end: Time(4, 1)))
    return (p, id)
}

@Suite struct ProjectFileV57Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v57Version == 57)
        #expect(ProjectFile.currentVersion >= 57)
    }

    @Test func bundleBumpsToV57AndRoundTrips() throws {
        let b = UUID()
        let p = try project([clip(bundle: b), clip(bundle: b)])
        #expect(p.containsV57Content)
        #expect(ProjectFile.writtenVersion(for: p) == 57)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: nil)
        #expect(back.timelines[0].tracks.map { $0.clips[0].bundle } == [b, b])
    }

    @Test func subclipBumpsToV57AndRoundTrips() throws {
        let (p, id) = try withSubclip()
        #expect(p.containsV57Content)
        #expect(ProjectFile.writtenVersion(for: p) == 57)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: nil)
        #expect(back.media(id) == p.media(id))
        #expect(back.sourceMarks[id] == p.sourceMarks[id])
        #expect(back.rootBin == p.rootBin)
    }

    @Test func plainProjectsKeepTheirVersion() throws {
        let p = try project([clip()])
        #expect(!p.containsV57Content)
        #expect(ProjectFile.writtenVersion(for: p) == ProjectFile.stabilizeVersion)
    }

    @Test func v57BeatsLowerGates() throws {
        let e = try #require(ClipEffect.make(kind: ClipEffect.dynamicZoomKind))
        let b = UUID()
        #expect(ProjectFile.writtenVersion(for: try project([clip(bundle: b, effects: [e]), clip(bundle: b)])) == 57)
    }

    /// A v56 file (no bundle, no subclip keys) still opens and reads the same.
    @Test func v56FileStillOpens() throws {
        let p = try project([clip()])
        let data = try ProjectFile.encode(p)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = 56
        let old = try JSONSerialization.data(withJSONObject: obj)
        let back = try ProjectFile.decode(old, migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0].bundle == nil)
        #expect(back.media.allSatisfy { $0.subclip == nil })
        #expect(back.timelines == p.timelines)
    }

    /// The written version is above anything an older build supports, so it reports "newer version" instead of dropping data.
    @Test func olderBuildRefusesAV57File() throws {
        let (p, _) = try withSubclip()
        let data = try ProjectFile.encode(p)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 57)
        var newer = obj
        newer["formatVersion"] = ProjectFile.currentVersion + 1
        let bumped = try JSONSerialization.data(withJSONObject: newer)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            try ProjectFile.decode(bumped, migrations: nil)
        }
    }
}
