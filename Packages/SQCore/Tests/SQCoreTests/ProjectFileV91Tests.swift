import Foundation
import Testing
@testable import SQCore

// v91: Snapping and Linked Selection are saved per sequence (stored only when off); Delete Track removes the targeted tracks.

private func timeline() -> Timeline {
    Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
             tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .video), Track(kind: .audio), Track(kind: .audio)])
}

@Suite struct ProjectFileV91Tests {
    @Test func defaultsKeepTheLowestVersionAndWriteNoKey() throws {
        let p = Project(name: "P", timelines: [timeline()])
        #expect(ProjectFile.v91Version == 91 && ProjectFile.currentVersion >= 91)
        #expect(!p.containsV91Content && ProjectFile.writtenVersion(for: p) < 91)
        let text = String(decoding: try ProjectFile.encode(p), as: UTF8.self)
        #expect(!text.contains("snappingOff") && !text.contains("linkedSelectionOff"))
    }

    @Test func offTogglesWriteV91AndRoundTrip() throws {
        var tl = timeline()
        tl.snappingOn = false
        let p = Project(name: "P", timelines: [tl])
        #expect(ProjectFile.writtenVersion(for: p) == 91)
        let data = try ProjectFile.encode(p)
        for m in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(data, migrations: m)
            #expect(!back.timelines[0].snappingOn && back.timelines[0].linkedSelectionOn)
        }
        var q = p
        q.timelines[0].snappingOn = true
        q.timelines[0].linkedSelectionOn = false
        #expect(q.containsV91Content)
        q.timelines[0].linkedSelectionOn = true
        #expect(!q.containsV91Content)
    }

    @Test func deleteTargetedTracksRemovesThemAsOneMutation() throws {
        var tl = timeline()
        tl.tracks[1].isTargeted = true; tl.tracks[2].isTargeted = true
        let gone = try tl.deleteTargetedTracks()
        #expect(gone.count == 2 && tl.tracks.count == 3)
    }

    @Test func deleteTargetedTracksKeepsTheLowestOfEachKind() {
        var tl = timeline()
        tl.tracks[0].isTargeted = true; tl.tracks[3].isTargeted = true
        #expect(throws: EditError.noTrackToDelete) { try tl.deleteTargetedTracks() }
        #expect(tl.tracks.count == 5)
    }

    @Test func deleteTargetedTracksRefusesALockedTrackAndChangesNothing() {
        var tl = timeline()
        tl.tracks[1].isTargeted = true; tl.tracks[2].isTargeted = true; tl.tracks[2].isLocked = true
        #expect(throws: EditError.trackLocked) { try tl.deleteTargetedTracks() }
        #expect(tl.tracks.count == 5)
    }
}
