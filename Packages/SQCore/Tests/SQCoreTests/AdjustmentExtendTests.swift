import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// "Extend to sequence end" (v49): an Adjustment Layer with the flag ends where the rest of the sequence ends.
@Suite struct AdjustmentExtendTests {
    /// V1 holds a 10 s clip, V2 an adjustment layer 0..4 s with the flag.
    private func project(flag: Bool = true) throws -> (Project, Timeline.ID, Track.ID, Track.ID, Clip.ID, Clip.ID) {
        var v1 = Track(kind: .video); let v2 = Track(kind: .video)
        let media = UUID()
        try v1.overwrite(Clip(id: UUID(), name: "A", media: media, kind: .video,
                              source: TimeRange(start: .zero, duration: s(10)), start: .zero))
        let base = v1.clips[0].id
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v1, v2])
        var p = Project(name: "P", timelines: [t])
        let adj = try p.addAdjustmentClip(in: t.id, at: .zero, track: v2.id, duration: s(4))
        if flag { p.setExtendToSequenceEnd(true, clip: adj) }
        return (p, t.id, v1.id, v2.id, base, adj)
    }

    private func clip(_ p: Project, _ id: Clip.ID) -> Clip { p.allClips().first { $0.id == id }! }

    @Test func flagOnlyForAdjustmentLayers() throws {
        var (p, _, _, _, base, adj) = try project(flag: false)
        p.setExtendToSequenceEnd(true, clip: base)
        #expect(!clip(p, base).extendsToSequenceEnd)
        p.setExtendToSequenceEnd(true, clip: adj)
        #expect(clip(p, adj).extendsToSequenceEnd)
        p.setExtendToSequenceEnd(false, clip: adj)
        #expect(!clip(p, adj).extendsToSequenceEnd)
    }

    @Test func settingTheFlagExtendsRightAway() throws {
        let (p, _, _, _, _, adj) = try project()
        #expect(clip(p, adj).timeline.end == s(10))
    }

    @Test func followsAGrowingAndShrinkingCut() throws {
        var (p, tl, v1, _, base, adj) = try project()
        try p.edit(tl) { t in
            let i = t.tracks.firstIndex { $0.id == v1 }!
            try t.tracks[i].overwrite(Clip(id: UUID(), name: "B", media: UUID(), kind: .video,
                                           source: TimeRange(start: .zero, duration: s(5)), start: s(10)))
        }
        p.extendAdjustmentLayersToSequenceEnd()
        #expect(clip(p, adj).timeline == TimeRange(start: .zero, duration: s(15)))
        try p.edit(tl) { t in
            let i = t.tracks.firstIndex { $0.id == v1 }!
            for c in t.tracks[i].clips where c.id != base { t.tracks[i].remove(c.id) }
        }
        p.extendAdjustmentLayersToSequenceEnd()
        #expect(clip(p, adj).timeline.end == s(10))
    }

    @Test func unflaggedLayerIsUntouched() throws {
        var (p, _, _, _, _, adj) = try project(flag: false)
        p.extendAdjustmentLayersToSequenceEnd()
        #expect(clip(p, adj).timeline.end == s(4))
    }

    @Test func layerAloneDoesNotRunAway() throws {
        var (p, tl, v1, _, _, adj) = try project()
        try p.edit(tl) { t in
            let i = t.tracks.firstIndex { $0.id == v1 }!
            for c in t.tracks[i].clips { t.tracks[i].remove(c.id) }
        }
        p.extendAdjustmentLayersToSequenceEnd()
        #expect(clip(p, adj).timeline.end == s(10))
        p.extendAdjustmentLayersToSequenceEnd()
        #expect(clip(p, adj).timeline.end == s(10))
    }

    @Test func stopsAtTheNextClipOnItsTrack() throws {
        var (p, tl, _, v2, _, adj) = try project(flag: false)
        try p.edit(tl) { t in
            let i = t.tracks.firstIndex { $0.id == v2 }!
            try t.tracks[i].overwrite(Clip(id: UUID(), name: "T", media: UUID(), kind: .video,
                                           source: TimeRange(start: .zero, duration: s(2)), start: s(7)))
        }
        p.setExtendToSequenceEnd(true, clip: adj)
        #expect(clip(p, adj).timeline.end == s(7))
    }

    @Test func versionGateAndRoundTrip() throws {
        let (p, _, _, _, _, adj) = try project()
        #expect(ProjectFile.writtenVersion(for: p) == ProjectFile.extendAdjustmentVersion)
        let obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == ProjectFile.extendAdjustmentVersion)
        var off = p; off.setExtendToSequenceEnd(false, clip: adj)
        #expect(ProjectFile.writtenVersion(for: off) < ProjectFile.extendAdjustmentVersion)
    }
}
