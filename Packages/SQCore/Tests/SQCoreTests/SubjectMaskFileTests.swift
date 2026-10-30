import Foundation
import Testing
@testable import SQCore

// W9.8 SubjectMask wiring: Add Subject Mask edit + ProjectFile v37 gate.

@Suite struct SubjectMaskFileTests {
    private let fd30 = Time(1, 30)

    private func clip(_ start: Int, kind: TrackKind = .video) -> Clip {
        Clip(name: "c\(start)", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: Time(5, 1)),
             start: Time(Int64(start), 1))
    }

    private func project(_ clips: [Clip], locked: Bool = false) throws -> Project {
        var track = Track(kind: .video)
        for c in clips { try track.overwrite(c) }
        track.isLocked = locked
        return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30),
                                                       tracks: [track])])
    }

    private func writtenVersion(_ p: Project) throws -> Int {
        let obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        return try #require(obj["formatVersion"] as? Int)
    }

    // MARK: Edit

    @Test func addSubjectMaskAddsOneSubjectMaskPerVideoClip() throws {
        let a = clip(0), b = clip(10)
        var t = try project([a, b]).timelines[0]
        let n = try t.addSubjectMask([a.id, b.id])
        #expect(n == 2)
        for c in t.tracks[0].clips {
            #expect(c.masks.count == 1)
            #expect(c.masks[0].source == .subject)
            #expect(c.masks[0].name == "Subject")
            #expect(c.hasSubjectMask)
        }
    }

    @Test func addSubjectMaskKeepsPathMasksAndIsIdempotent() throws {
        var a = clip(0)
        a.masks = [ClipMask.make(.ellipse, name: "Mask 1")]
        var t = try project([a]).timelines[0]
        #expect(try t.addSubjectMask([a.id]) == 1)
        #expect(t.tracks[0].clips[0].masks.map(\.source) == [.path, .subject])
        let before = t
        #expect(try t.addSubjectMask([a.id]) == 0)
        #expect(t == before)
    }

    @Test func addSubjectMaskSkipsGeneratorsNestsAndLockedTracks() throws {
        var gen = clip(0)
        gen.generator = .solid(rgb: [255, 0, 0])
        var t = try project([gen]).timelines[0]
        #expect(try t.addSubjectMask([gen.id]) == 0)
        #expect(t.tracks[0].clips[0].masks.isEmpty)

        let c = clip(0)
        var locked = try project([c], locked: true).timelines[0]
        #expect(try locked.addSubjectMask([c.id]) == 0)
        #expect(locked.tracks[0].clips[0].masks.isEmpty)
    }

    @Test func subjectMaskTargetRule() {
        #expect(clip(0).acceptsSubjectMask)
        var gen = clip(0)
        gen.generator = .solid(rgb: [255, 0, 0])
        #expect(!gen.acceptsSubjectMask)
    }

    @Test func layerRequestsAskForTheMatteOnlyWithAnEnabledSubjectMask() throws {
        var a = clip(0)
        a.masks = [ClipMask.make(.rectangle, name: "Mask 1")]
        var t = try project([a]).timelines[0]
        #expect(t.videoLayers(at: Time(1, 1)).first?.effects.needsSubjectMatte == false)
        try t.addSubjectMask([a.id])
        #expect(t.videoLayers(at: Time(1, 1)).first?.effects.needsSubjectMatte == true)
        var c = t.tracks[0].clips[0]
        c.masks[1].enabled = false
        try t.replaceClip(c)
        #expect(t.videoLayers(at: Time(1, 1)).first?.effects.needsSubjectMatte == false)
    }

    // MARK: ProjectFile v37 gate

    @Test func versionConstants() {
        #expect(ProjectFile.currentVersion >= 37)
        #expect(ProjectFile.subjectMaskVersion == 37)
    }

    @Test func filesWithASubjectMaskAreWrittenAsV37() throws {
        var a = clip(0)
        a.masks = [ClipMask.makeSubject(name: "Subject")]
        let p = try project([a])
        #expect(p.containsSubjectMask)
        // A v36 build refuses anything newer than 36 (ProjectFile.decode: version > currentVersion).
        #expect(try writtenVersion(p) >= ProjectFile.subjectMaskVersion)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0].masks[0].source == .subject)
        #expect(back == p)
    }

    @Test func filesWithoutASubjectMaskStayReadableByV36() throws {
        var a = clip(0)
        a.masks = [ClipMask.make(.rectangle, name: "Mask 1")]
        let p = try project([a])
        #expect(!p.containsSubjectMask)
        let v = try writtenVersion(p)
        #expect(v == 36)   // the lowest version that holds the content (`writtenVersion`)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back == p)
    }

    @Test func disabledSubjectMaskStillGates() throws {
        var m = ClipMask.makeSubject(name: "Subject")
        m.enabled = false
        var a = clip(0)
        a.masks = [m]
        #expect(try writtenVersion(project([a])) >= ProjectFile.subjectMaskVersion)
    }

    @Test func subjectMaskInAnyTimelineGates() throws {
        var a = clip(0)
        a.masks = [ClipMask.makeSubject(name: "Subject")]
        var p = try project([clip(0)])
        var track = Track(kind: .video)
        try track.overwrite(a)
        p.timelines.append(Timeline(name: "Nest", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd30), tracks: [track]))
        #expect(p.containsSubjectMask)
        #expect(try writtenVersion(p) >= ProjectFile.subjectMaskVersion)
    }

    @Test func v36FilesStillOpen() throws {
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(project([clip(0)]))) as? [String: Any])
        obj["formatVersion"] = 36
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines.count == 1)
    }

    @Test func newerVersionIsRefused() throws {
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(project([clip(0)]))) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        }
    }

    // MARK: Paste Attributes (review W9.8 #2)

    @Test func pasteAttributesDropsSubjectMasksOnGeneratorsAndNests() throws {
        var src = clip(0)
        src.masks = [ClipMask.make(.ellipse, name: "Mask 1"), ClipMask.makeSubject(name: "Subject")]
        var gen = clip(10)
        gen.generator = .solid(rgb: [0, 0, 255])
        var nest = clip(20)
        nest.sequence = UUID()
        for target in [gen, nest] {
            let out = target.pastingAttributes(from: src)
            #expect(out.masks.map(\.source) == [.path], "\(target.name)")
        }
        // A media video clip takes both.
        #expect(clip(30).pastingAttributes(from: src).masks.map(\.source) == [.path, .subject])
    }

    // MARK: Targets (review W9.8 #8)

    @Test func subjectMaskTargetsSkipLockedTracksAndClipsThatHaveOne() throws {
        let a = clip(0), b = clip(10)
        var t = try project([a, b]).timelines[0]
        #expect(t.subjectMaskTargets([a.id, b.id]) == [a.id, b.id])
        try t.addSubjectMask([a.id])
        #expect(t.subjectMaskTargets([a.id, b.id]) == [b.id])
        let locked = try project([a, b], locked: true).timelines[0]
        #expect(locked.subjectMaskTargets([a.id, b.id]).isEmpty)
    }
}
