import Foundation
import Testing
@testable import SQCore

// v72: Looks with a payload newer than the caption look (v1) in `StyleKit.looks`. A v71 build would skip such a Look and
// draw its captions in the default style; at v72 it refuses the file instead. Projects whose Looks are all v1 are written
// exactly as before.

private func project(looks: [String: StyleKitLook]) -> Project {
    let t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                     tracks: [Track(kind: .video)])
    var p = Project(name: "P", timelines: [t])
    p.styleKit = looks.isEmpty ? nil : StyleKit(looks: looks)
    return p
}

private let v1 = StyleKitLook(name: "Old", payload: Data(#"{"style":{},"animation":{}}"#.utf8), payloadVersion: 1)
private let v2 = StyleKitLook(name: "New", payload: Data(#"{"style":{}}"#.utf8), payloadVersion: 2)

@Suite struct ProjectFileV72Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v72Version == 72)
        #expect(ProjectFile.currentVersion >= 72)
    }

    @Test func aNewLookPayloadWritesV72AndRoundTrips() throws {
        let p = project(looks: ["a": v1, "b": v2])
        #expect(p.containsV72Content)
        #expect(ProjectFile.writtenVersion(for: p) == 72)
        let data = try ProjectFile.encode(p)
        let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        #expect(back == p)
        #expect(back.styleKit?.looks == ["a": v1, "b": v2])
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 72)
    }

    @Test func projectsWithOldLooksKeepTheirVersion() throws {
        for p in [project(looks: [:]), project(looks: ["a": v1])] {
            #expect(!p.containsV72Content)
            #expect(ProjectFile.writtenVersion(for: p) < 72)
            let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
            #expect(back == p)
        }
    }

    /// A stored v71 file (`Tests/Fixtures/project-v71.json`, as a v71 build writes it: `appFormat` 71) with kit looks
    /// and captions that carry one opens unchanged: same ids, names and payload bytes, and it is not lifted to v72.
    @Test func aStoredV71FileOpensWithItsLooks() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/project-v71.json")
        let data = try Data(contentsOf: url)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 71)
        let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        let looks = try #require(back.styleKit?.looks)
        #expect(Set(looks.keys) == ["brand", "own-1"])
        #expect(looks["brand"] == v1)
        #expect(looks["own-1"]?.payloadVersion == 1 && looks["own-1"]?.payload == v1.payload)
        let track = try #require(back.timelines.first?.captionTracks.first)
        #expect(track.styleRef == "look-kit-brand" && track.animationRef == "look-kit-brand")
        #expect(track.lookID == nil)
        #expect(track.items.map(\.lines) == [["Hello"], ["World"]])
        #expect(back.timelines.first?.angles != nil)
        #expect(!back.containsV72Content)
        #expect(ProjectFile.writtenVersion(for: back) == 71)
        #expect(try ProjectFile.decode(try ProjectFile.encode(back), migrations: ProjectFile.migrations) == back)
    }

    /// The Look a caption track was given is remembered next to its style (an optional key: no new file version), kept
    /// by an edit on top of the Look and forgotten when another style is chosen.
    @Test func aCaptionTrackRemembersItsLook() throws {
        var p = project(looks: ["brand": v1])
        let track = CaptionTrack(items: [])
        p.timelines[0].captionTracks = [track]
        let plain = try #require(String(data: try ProjectFile.encode(p), encoding: .utf8))
        #expect(!plain.contains("lookID"))

        try p.timelines[0].setCaptionStyle(styleRef: "look-kit-brand", track: track.id)
        try p.timelines[0].setCaptionLook("kit-brand", track: track.id)
        try p.timelines[0].setCaptionStyle(styleRef: "kit-caption", track: track.id, keepsLook: true)
        #expect(p.timelines[0].captionTracks[0].lookID == "kit-brand")
        #expect(ProjectFile.writtenVersion(for: p) < 72)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back == p && back.timelines[0].captionTracks[0].lookID == "kit-brand")

        // A sequence duplicated in another format and a second caption track start with the same Look.
        let copy = try p.duplicateSequence(p.timelines[0].id, as: p.timelines[0].format, mode: .fit)
        #expect(p.timeline(copy)?.captionTracks.map(\.lookID) == ["kit-brand"])
        let second = p.timelines[0].addCaptionTrack()
        #expect(p.timelines[0].captionTrack(second)?.lookID == "kit-brand")

        try p.timelines[0].setCaptionStyle(styleRef: "default", track: track.id)
        #expect(p.timelines[0].captionTracks[0].lookID == nil)
    }

    @Test func olderBuildRefusesANewerFile() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(project(looks: ["b": v2]))) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(newer, migrations: ProjectFile.migrations)
        }
    }
}
