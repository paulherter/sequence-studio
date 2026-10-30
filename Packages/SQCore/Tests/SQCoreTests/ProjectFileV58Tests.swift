import Foundation
import Testing
@testable import SQCore

// v58 gate: animation zones (`Clip.zones`) and applied title templates (`Clip.templateSlots`). Files without them keep
// their older version; v57 files open unchanged.

private let fd30 = Time(1, 30)

private func clip(zones: AnimationZones? = nil, slots: [TemplateSlot]? = nil, bundle: UUID? = nil) -> Clip {
    var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd30 * 90), start: .zero)
    c.zones = zones
    c.templateSlots = slots
    c.bundle = bundle
    return c
}

private func project(_ clips: [Clip]) throws -> Project {
    var tracks: [Track] = []
    for c in clips { var t = Track(kind: .video); try t.overwrite(c); tracks.append(t) }
    return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30),
                                                   tracks: tracks)])
}

private let zones = AnimationZones(introEnd: Time(1, 2), outroStart: Time(5, 2), designDuration: Time(3, 1), middle: .stretch)

@Suite struct ProjectFileV58Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v58Version == 58)
        #expect(ProjectFile.currentVersion >= 58)
    }

    @Test func zonesBumpToV58AndRoundTrip() throws {
        let p = try project([clip(zones: zones)])
        #expect(p.containsV58Content)
        #expect(ProjectFile.writtenVersion(for: p) == 58)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: nil)
        #expect(back.timelines[0].tracks[0].clips[0].zones == zones)
        #expect(back == p)
    }

    @Test func templateSlotsBumpToV58AndRoundTrip() throws {
        let slot = TemplateSlot(name: "Text 1", kind: .text, layer: UUID(), path: "template.text", value: .text("Hi"))
        let p = try project([clip(slots: [slot])])
        #expect(ProjectFile.writtenVersion(for: p) == 58)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: nil)
        #expect(back.timelines[0].tracks[0].clips[0].templateSlots == [slot])
    }

    @Test func plainProjectsKeepTheirVersion() throws {
        let p = try project([clip()])
        #expect(!p.containsV58Content)
        #expect(ProjectFile.writtenVersion(for: p) == ProjectFile.stabilizeVersion)
        let b = UUID()
        #expect(ProjectFile.writtenVersion(for: try project([clip(bundle: b), clip(bundle: b)])) == 57)
    }

    @Test func v58BeatsLowerGates() throws {
        let b = UUID()
        #expect(ProjectFile.writtenVersion(for: try project([clip(zones: zones, bundle: b), clip(bundle: b)])) == 58)
    }

    /// A v57 file (no zone or slot keys) still opens and reads the same.
    @Test func v57FileStillOpens() throws {
        let b = UUID()
        let p = try project([clip(bundle: b), clip(bundle: b)])
        let data = try ProjectFile.encode(p)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = 57
        let old = try JSONSerialization.data(withJSONObject: obj)
        let back = try ProjectFile.decode(old, migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks.allSatisfy { $0.clips.allSatisfy { $0.zones == nil && $0.templateSlots == nil } })
        #expect(back.timelines == p.timelines)
    }

    /// An applied template round-trips with its inner sequence; the file is v58.
    @Test func appliedTemplateRoundTrips() throws {
        var layer = Clip(name: "T", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)),
                         start: .zero, generator: GeneratorRef(kind: GeneratorRef.text, payload: Data(#"{"template":{"text":"A"}}"#.utf8)))
        layer.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(1, 2), value: 1.0)])
        var lt = Track(kind: .video)
        try lt.overwrite(layer)
        let src = Timeline(name: "Src", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30), tracks: [lt])
        var p = Project(name: "P", timelines: [src])
        let t = try TitleTemplate.capture(clips: [layer.id], in: src.id, of: p, name: "Lower third")
        let host = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30), tracks: [Track(kind: .video)])
        p.timelines.append(host)
        _ = try p.applyTitleTemplate(t, in: host.id, track: host.tracks[0].id, at: .zero, values: [t.slots[0].id: .text("B")])
        #expect(ProjectFile.writtenVersion(for: p) == 58)
        p.normalizeBins()
        // The template's inside is not filed in a bin (it is not a sequence of its own); the others are.
        #expect(p.rootBin.allRefs.count == 2)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: nil)
        #expect(back.timelines == p.timelines)
        #expect(back.rootBin == p.rootBin)
    }
}
