import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// The full blend set (27 modes, the editors' standard menu) and its file gate (ProjectFile v55).
@Suite struct BlendModeParityTests {
    private func project() -> (Project, Timeline.ID, Track.ID) {
        let v1 = Track(kind: .video), v2 = Track(kind: .video)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v1, v2, Track(kind: .audio)])
        return (Project(name: "P", timelines: [t]), t.id, v2.id)
    }

    private func writtenVersion(_ p: Project) throws -> Int {
        let obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        return try #require(obj["formatVersion"] as? Int)
    }

    @Test func theFullSetHas27ModesInSixSections() {
        #expect(BlendMode.allCases.count == 27)
        let sections = BlendMode.menuSections
        #expect(sections.count == 6)
        #expect(sections[0] == [.normal, .dissolve])
        #expect(sections[1] == [.darken, .multiply, .colorBurn, .linearBurn, .darkerColor])
        #expect(sections[2] == [.lighten, .screen, .colorDodge, .add, .lighterColor])
        #expect(sections[3] == [.overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix])
        #expect(sections[4] == [.difference, .exclusion, .subtract, .divide])
        #expect(sections[5] == [.hue, .saturation, .color, .luminosity])
    }

    @Test func titlesAreUniqueAndAddIsPlain() {
        #expect(Set(BlendMode.allCases.map(\.title)).count == 27)
        #expect(BlendMode.add.title == "Add")
        #expect(BlendMode.luminosity.title == "Luminosity")
    }

    @Test func everyModeKnowsTheFileVersionItNeeds() {
        for m in BlendMode.allCases where m.isLegacy { #expect(m.minimumFileVersion == 22, "\(m)") }
        let v41: Set<BlendMode> = [.darken, .colorBurn, .linearBurn, .lighten, .colorDodge, .softLight, .hardLight, .difference, .exclusion]
        for m in v41 { #expect(m.minimumFileVersion == 41, "\(m)") }
        let v55 = BlendMode.allCases.filter { !$0.isLegacy && !v41.contains($0) }
        #expect(v55.count == 13)
        for m in v55 { #expect(m.minimumFileVersion == 55, "\(m)") }
    }

    @Test func aFullSetModeIsWrittenAsV55AndRoundTrips() throws {
        var (p, tl, _) = project()
        var c = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        c.blendMode = .difference
        try p.edit(tl) { try $0.tracks[0].overwrite(c) }
        #expect(!p.containsFullBlendModes)
        #expect(try writtenVersion(p) == 41)
        for m in [BlendMode.dissolve, .luminosity, .vividLight] {
            c.blendMode = m
            try p.edit(tl) { try $0.replaceClip(c) }
            #expect(p.containsFullBlendModes)
            #expect(try writtenVersion(p) == 55)
            let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
            #expect(back.timelines[0].tracks[0].clips[0].blendMode == m)
        }
    }

    @Test func aGraphicsLayerWithAFullSetModeGatesV55() throws {
        var (p, tl, v2) = project()
        let id = try p.addGraphicsClip(in: tl, at: s(0), track: v2, duration: s(2))
        var layer = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        layer.blendMode = .multiply
        try p.addGraphicsLayer(layer, to: id)
        #expect(!p.containsFullBlendModes)
        var hue = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        hue.blendMode = .hue
        try p.addGraphicsLayer(hue, to: id)
        #expect(p.containsFullBlendModes)
        #expect(try writtenVersion(p) == 55)
    }

    @Test func versionConstants() {
        #expect(ProjectFile.currentVersion >= 55 && ProjectFile.fullBlendVersion == 55)
        #expect(ProjectFile.migrations[54] != nil)
    }
}
