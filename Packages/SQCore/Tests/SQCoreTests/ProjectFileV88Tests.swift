import Foundation
import Testing
@testable import SQCore

// v88: the source patch of a sequence is saved. A v87 build would forget it on save; at v88 it refuses the file. A
// sequence on the default patch stores no key and keeps its lowest version.

private func project(patched: Bool = false, disconnectAudio: Bool = false) -> (Project, Track.ID) {
    var tl = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                      tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
    let v2 = tl.tracks[1].id
    if patched {
        var p = SourcePatch()
        p.patch(.video, to: v2, in: tl)
        if disconnectAudio { p.toggleConnection(.audio) }
        tl.sourcePatch = p
    }
    return (Project(name: "P", timelines: [tl]), v2)
}

@Suite struct ProjectFileV88Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v88Version == 88)
        #expect(ProjectFile.currentVersion >= 88)
    }

    @Test func defaultPatchKeepsTheLowestVersionAndWritesNoKey() throws {
        let (p, _) = project()
        #expect(!p.containsV88Content)
        let data = try ProjectFile.encode(p)
        #expect(!String(decoding: data, as: UTF8.self).contains("sourcePatch"))
        #expect(ProjectFile.writtenVersion(for: p) < 88)
    }

    @Test func settingTheDefaultBackStoresNothing() throws {
        var (p, _) = project(patched: true)
        #expect(p.containsV88Content)
        p.timelines[0].sourcePatch = SourcePatch()
        #expect(!p.containsV88Content)
        #expect(!String(decoding: try ProjectFile.encode(p), as: UTF8.self).contains("sourcePatch"))
    }

    @Test func aPatchWritesV88AndRoundTrips() throws {
        let (p, v2) = project(patched: true, disconnectAudio: true)
        #expect(ProjectFile.writtenVersion(for: p) == 88)
        let data = try ProjectFile.encode(p)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 88)
        for m in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(data, migrations: m)
            #expect(back == p)
            #expect(back.timelines[0].sourcePatch.video.track == v2)
            #expect(!back.timelines[0].sourcePatch.audio.isConnected)
        }
    }

    @Test func aV87BuildRefusesAV88File() throws {
        let (p, _) = project(patched: true)
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: nil)
        }
    }

    @Test func aV87FileOpensWithTheDefaultPatch() throws {
        let (p, _) = project()
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 87
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].sourcePatch == SourcePatch())
    }

    @Test func aMalformedPatchOpensAsTheDefault() throws {
        let (p, _) = project(patched: true)
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        var proj = obj["project"] as! [String: Any]
        var tls = proj["timelines"] as! [[String: Any]]
        tls[0]["sourcePatch"] = 5
        proj["timelines"] = tls
        obj["project"] = proj
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: nil)
        #expect(back.timelines[0].sourcePatch == SourcePatch())
    }

    @Test func duplicateSequenceFollowsItsPatchToTheCopiedTrack() throws {
        var (p, v2) = project(patched: true)
        let src = p.timelines[0]
        let copyID = try p.duplicateSequence(src.id, as: src.format, mode: .fit)
        let copy = try #require(p.timeline(copyID))
        let newV2 = copy.tracks[1].id
        #expect(newV2 != v2)
        #expect(copy.sourcePatch.video.track == newV2)
        #expect(p.timelines[0].sourcePatch.video.track == v2)
    }

    @Test func deletingThePatchedTrackDropsTheStaleIDAndTheVersionGate() throws {
        var (p, v2) = project(patched: true)
        #expect(ProjectFile.writtenVersion(for: p) == 88)
        try p.timelines[0].removeTrack(v2)
        #expect(p.timelines[0].sourcePatch == SourcePatch())
        #expect(!p.containsV88Content)
        #expect(ProjectFile.writtenVersion(for: p) < 88)
    }
}
