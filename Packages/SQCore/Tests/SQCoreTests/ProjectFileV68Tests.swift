import Foundation
import Testing
@testable import SQCore

// v68: the Canon Log input color spaces. A v67 build would read a Canon project input as "none" and drop it on save, and
// fail on a clip set to one; at v68 it refuses the file instead. Projects without a Canon space keep their version.

private func project(clip: ColorSpaceID? = nil, input: ColorSpaceID? = nil) throws -> Project {
    var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                 start: .zero, mediaDuration: Time(20, 1))
    c.footageColor = ClipFootageColor(source: clip)
    var v = Track(kind: .video)
    try v.overwrite(c)
    let t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v])
    var p = Project(name: "P", timelines: [t])
    p.inputColorSpace = input
    return p
}

@Suite struct ProjectFileV68Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v68Version == 68)
        #expect(ProjectFile.currentVersion >= 68)
    }

    @Test func aCanonClipInputWritesV68AndRoundTrips() throws {
        for s in InputColorProfile.logSpaces(for: .canon) {
            let p = try project(clip: s)
            #expect(p.containsV68Content)
            #expect(ProjectFile.writtenVersion(for: p) == 68)
            let data = try ProjectFile.encode(p)
            let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(obj["formatVersion"] as? Int == 68)
            let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
            #expect(back == p)
            #expect(back.allClips().first?.footageColor.source == s)
        }
    }

    @Test func aCanonProjectInputWritesV68AndRoundTrips() throws {
        for s in InputColorProfile.logSpaces(for: .canon) {
            let p = try project(input: s)
            #expect(p.containsV68Content)
            #expect(ProjectFile.writtenVersion(for: p) == 68)
            let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
            #expect(back == p)
            #expect(back.inputColorSpace == s)
        }
    }

    @Test func aCanonMediaItemWritesV68() throws {
        var p = try project()
        var item = MediaRef(name: "a.mp4", path: "/x/a.mp4", fingerprint: MediaFingerprint(size: 1))
        item.info = MediaInfo(duration: Time(10, 1), detectedColorSpace: .canonLog2CinemaGamut)
        p.media = [item]
        #expect(ProjectFile.writtenVersion(for: p) == 68)
    }

    @Test func projectsWithoutACanonSpaceKeepTheirVersion() throws {
        for p in [try project(), try project(clip: .sLog3SGamut3Cine, input: .appleLog), try project(clip: .dLogDGamut)] {
            #expect(!p.containsV68Content)
            #expect(ProjectFile.writtenVersion(for: p) < 68)
            var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
            #expect((obj["formatVersion"] as? Int ?? 99) < 68)
            // What a v67 build wrote still opens.
            obj["appFormat"] = 67
            let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
            #expect(back == p)
        }
    }

    @Test func onlyTheCanonSpacesNeedV68() {
        let canon = Set(InputColorProfile.logSpaces(for: .canon))
        for s in ColorSpaceID.allCases { #expect(s.needsV68 == canon.contains(s), "\(s)") }
    }

    @Test func v68WinsOverOlderGates() throws {
        var p = try project(input: .canonLog3CinemaGamut)
        p.timelines[0].masterVolumeDB = -3
        #expect(p.containsV66Content)
        #expect(ProjectFile.writtenVersion(for: p) == 68)
    }
}
