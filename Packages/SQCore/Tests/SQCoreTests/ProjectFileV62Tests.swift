import Foundation
import Testing
@testable import SQCore

// v62: `TemplateSlot.graphicsLayer` (a template field addressing one text layer inside a graphics clip). A v61 build would
// drop the field on decode and write into the clip's (empty) generator payload; at v62 it refuses the file instead.

private func clip(slots: [TemplateSlot]? = nil) -> Clip {
    var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
    c.templateSlots = slots
    return c
}

private func project(_ clip: Clip) throws -> Project {
    var t = Track(kind: .video)
    try t.overwrite(clip)
    return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                                                   tracks: [t])])
}

private func slot(graphicsLayer: UUID?) -> TemplateSlot {
    TemplateSlot(name: "Text 1", kind: .text, layer: UUID(), graphicsLayer: graphicsLayer, path: "template.text", value: .text("Hi"))
}

@Suite struct ProjectFileV62Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v62Version == 62)
        #expect(ProjectFile.currentVersion >= 62)
    }

    @Test func graphicsLayerSlotWritesV62AndRoundTrips() throws {
        let s = slot(graphicsLayer: UUID())
        let p = try project(clip(slots: [s]))
        #expect(p.containsV62Content)
        #expect(ProjectFile.writtenVersion(for: p) == 62)
        let data = try ProjectFile.encode(p)
        let back = try ProjectFile.decode(data, migrations: nil)
        #expect(back == p)
        #expect(back.timelines[0].tracks[0].clips[0].templateSlots?[0].graphicsLayer == s.graphicsLayer)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 62)
        #expect(obj["appFormat"] as? Int == ProjectFile.currentVersion)
    }

    @Test func plainSlotsKeepV58() throws {
        let p = try project(clip(slots: [slot(graphicsLayer: nil)]))
        #expect(!p.containsV62Content)
        #expect(ProjectFile.writtenVersion(for: p) == 58)
        // The key is absent from the file, so the bytes equal what a v61 build wrote.
        let json = String(decoding: try ProjectFile.encode(p), as: UTF8.self)
        #expect(!json.contains("graphicsLayer"))
        #expect(ProjectFile.writtenVersion(for: try project(clip())) == ProjectFile.stabilizeVersion)
    }

    @Test func v62WinsOverV61() throws {
        var c = clip(slots: [slot(graphicsLayer: UUID())])
        c.effects = [ClipEffect(kind: ClipEffect.kaleidoscopeKind)]
        #expect(ProjectFile.writtenVersion(for: try project(c)) == 62)
    }

    /// A v61 file (slots without the field) opens and reads the same.
    @Test func v61FileStillOpens() throws {
        let p = try project(clip(slots: [slot(graphicsLayer: nil)]))
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 61
        let old = try JSONSerialization.data(withJSONObject: obj)
        let back = try ProjectFile.decode(old, migrations: ProjectFile.migrations)
        #expect(back.timelines == p.timelines)
    }

    @Test func olderBuildRefusesANewerFile() throws {
        let p = try project(clip(slots: [slot(graphicsLayer: UUID())]))
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(newer, migrations: ProjectFile.migrations)
        }
    }
}
