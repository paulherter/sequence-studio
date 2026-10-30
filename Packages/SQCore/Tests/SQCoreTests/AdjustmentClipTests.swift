import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct AdjustmentClipTests {
    private func project() -> (Project, Timeline.ID, Track.ID, Track.ID) {
        let v1 = Track(kind: .video), v2 = Track(kind: .video)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v1, v2, Track(kind: .audio)])
        return (Project(name: "P", timelines: [t]), t.id, v1.id, v2.id)
    }

    private func clip(_ p: Project, _ tl: Timeline.ID, _ id: Clip.ID) -> Clip {
        p.timeline(tl)!.tracks.flatMap(\.clips).first { $0.id == id }!
    }

    @Test func addPlacesAnAdjustmentLayerWithoutMedia() throws {
        var (p, tl, _, v2) = project()
        let id = try p.addAdjustmentClip(in: tl, at: s(1), track: v2, duration: s(4))
        let c = clip(p, tl, id)
        #expect(c.isAdjustment && c.isGenerator && c.kind == .video)
        #expect(c.generator?.kind == GeneratorRef.adjustment)
        #expect(c.name == "Adjustment Layer")
        #expect(c.timeline == TimeRange(start: s(1), duration: s(4)))
        #expect(c.mediaDuration == nil)
    }

    @Test func refusesAudioTracksAndEmptyLengths() throws {
        var (p, tl, _, _) = project()
        let a = p.timeline(tl)!.tracks[2].id
        #expect(throws: EditError.wrongTrackKind) { try p.addAdjustmentClip(in: tl, at: s(0), track: a, duration: s(1)) }
        let v = p.timeline(tl)!.tracks[0].id
        #expect(throws: EditError.emptyClip) { try p.addAdjustmentClip(in: tl, at: s(0), track: v, duration: Time(1, 60)) }
    }

    @Test func evaluationListsItAboveTheLayersBelowWithItsEffects() throws {
        var (p, tl, v1, v2) = project()
        let media = UUID()
        let base = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        try p.edit(tl) { try $0.tracks[0].overwrite(base) }
        _ = v1
        let id = try p.addAdjustmentClip(in: tl, at: s(1), track: v2, duration: s(2))
        var adj = clip(p, tl, id)
        adj.effects = [ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: ClipEffect.defaultParameters(for: ClipEffect.gaussianBlurKind)
                                    .merging([ClipEffect.blurrinessKey: AnimatedProperty(20)]) { $1 })]
        adj.blendMode = .softLight
        try p.edit(tl) { try $0.replaceClip(adj) }
        let layers = p.timeline(tl)!.videoLayers(at: s(2))
        #expect(layers.count == 2)
        #expect(layers[0].clip == base.id)
        #expect(layers[1].clip == id && layers[1].isAdjustment)
        #expect(layers[1].effects.blur > 0)
        #expect(layers[1].blendMode == .softLight)
        // Outside its time range only the clip below shows.
        #expect(p.timeline(tl)!.videoLayers(at: s(5)).map(\.clip) == [base.id])
    }

    @Test func blendModesFollowPremieresOrderAndKeepTheOldRawValues() {
        #expect(BlendMode.allCases.count >= 12)
        #expect(BlendMode.allCases.first == .normal)
        for m in ["normal", "multiply", "screen", "add", "overlay"] { #expect(BlendMode(rawValue: m)?.isLegacy == true) }
        #expect(BlendMode.allCases.filter(\.isLegacy).count == 5)
        // Groups never go back: a menu can put a separator wherever the group changes.
        let groups = BlendMode.allCases.map(\.group)
        #expect(groups == groups.sorted())
        #expect(Set(BlendMode.allCases.map(\.title)).count == BlendMode.allCases.count)
    }

    @Test func blendModeMenuSectionsFollowTheGroups() {
        let sections = BlendMode.menuSections
        #expect(sections.count == 6)
        #expect(sections.flatMap { $0 } == BlendMode.allCases)
        for (i, s) in sections.enumerated() { #expect(s.allSatisfy { $0.group == i }) }
        #expect(sections[0] == [.normal, .dissolve])
    }

    /// An Adjustment Layer takes a color grade (Lumetri on the picture below); other generators still do not.
    @Test func anAdjustmentLayerAcceptsColour() throws {
        var (p, tl, _, v2) = project()
        let id = try p.addAdjustmentClip(in: tl, at: s(0), track: v2, duration: s(2))
        var c = clip(p, tl, id)
        #expect(c.acceptsColor)
        #expect(c.addEffect(kind: ClipEffect.colorKind) != nil)
        #expect(c.effects.contains { $0.isColor })
        var text = c; text.generator = GeneratorRef.solid(rgb: [1, 2, 3])
        #expect(!text.acceptsColor)
    }

    // MARK: ProjectFile v41

    private func writtenVersion(_ p: Project) throws -> Int {
        let obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        return try #require(obj["formatVersion"] as? Int)
    }

    @Test func versionConstants() {
        #expect(ProjectFile.currentVersion >= 41)
        #expect(ProjectFile.adjustmentVersion == 41 && ProjectFile.extendedBlendVersion == 41)
        #expect(ProjectFile.realMigrations[40] != nil)
    }

    @Test func anAdjustmentLayerIsWrittenAsV41AndRoundTrips() throws {
        var (p, tl, _, v2) = project()
        try p.addAdjustmentClip(in: tl, at: s(0), track: v2, duration: s(2))
        #expect(p.containsAdjustmentClips)
        #expect(try writtenVersion(p) == 41)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back == p)
    }

    @Test func aNewBlendModeIsWrittenAsV41ButTheOldOnesKeepTheLowestVersion() throws {
        var (p, tl, _, _) = project()
        var c = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        c.blendMode = .screen
        try p.edit(tl) { try $0.tracks[0].overwrite(c) }
        #expect(!p.containsExtendedBlendModes)
        #expect(try writtenVersion(p) == 36)
        c.blendMode = .difference
        try p.edit(tl) { try $0.replaceClip(c) }
        #expect(p.containsExtendedBlendModes)
        #expect(try writtenVersion(p) == 41)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0].blendMode == .difference)
    }

    @Test func v40FilesStillOpen() throws {
        let (p, _, _, _) = project()
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 40
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines.count == 1 && !back.containsAdjustmentClips)
    }
}
