import Foundation
import Testing
@testable import SQCore

@Suite struct ColorMatteTests {
    private func project() -> (Project, Timeline.ID, Track.ID) {
        let v = Track(kind: .video), a = Track(kind: .audio)
        let t = Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)), tracks: [v, a])
        return (Project(name: "P", timelines: [t]), t.id, v.id)
    }
    private func clip(_ p: Project, _ tl: Timeline.ID, _ id: Clip.ID) -> Clip {
        p.timeline(tl)!.tracks.flatMap(\.clips).first { $0.id == id }!
    }

    @Test func payloadRoundTripsThroughTheProjectFile() throws {
        var (p, tl, v) = project()
        let id = try p.addColorMatte(ColorMatteColor(r: 12, g: 200, b: 99), name: "Sky", in: tl, at: Time(2, 1), track: v,
                                     duration: Time(5, 1))
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        let c = clip(back, tl, id)
        #expect(c.name == "Sky" && c.isColorMatte && c.isGenerator)
        #expect(c.matteColor == ColorMatteColor(r: 12, g: 200, b: 99))
        #expect(c.generator == GeneratorRef.solid(rgb: [12, 200, 99]))
        #expect(c.start == Time(2, 1) && c.duration == Time(5, 1))
    }

    @Test func setColorChangesOnlyThePayload() throws {
        var (p, tl, v) = project()
        let id = try p.addColorMatte(.default, in: tl, at: .zero, track: v, duration: Time(5, 1))
        let before = clip(p, tl, id)
        try p.setColorMatte(clipID: id, ColorMatteColor(r: 255, g: 0, b: 10))
        var after = clip(p, tl, id)
        #expect(after.matteColor == ColorMatteColor(r: 255, g: 0, b: 10))
        after.generator = before.generator
        #expect(after == before)
    }

    @Test func setColorRefusesOtherClips() throws {
        var (p, tl, v) = project()
        let id = try p.addGeneratorClip(kind: GeneratorRef.text, payload: Data(), in: tl, at: .zero, track: v, duration: Time(2, 1))
        #expect(throws: EditError.self) { try p.setColorMatte(clipID: id, .default) }
        #expect(GeneratorRef(kind: GeneratorRef.solid, payload: Data([1, 2])).matteColor == nil)
    }

    @Test func behavesAsAnOrdinaryClip() throws {
        var (p, tl, v) = project()
        let id = try p.addColorMatte(.default, in: tl, at: .zero, track: v, duration: Time(5, 1))
        var c = clip(p, tl, id)
        #expect(c.addEffect(kind: ClipEffect.gaussianBlurKind) != nil)
        c.animation.opacity = AnimatedProperty(0.5)
        try p.edit(tl) { try $0.replaceClip(c) }
        #expect(clip(p, tl, id).animation.opacity == AnimatedProperty(0.5))
        #expect(!clip(p, tl, id).effects.isEmpty)
    }
}
