import Foundation
import Testing
@testable import SQCore

// Track Mask effect: another video track's picture (alpha or luma, optionally inverted) limits the clip. The effect evaluates
// into the same Picture mask the renderer already reads (`MaskSource.picture`, matte requests tagged `matteFor`), v90 gate.

private let fd = Time(1, 30)
private let fmt = SequenceFormat(width: 1920, height: 1080, frameDuration: fd)

private func clip(_ start: Int, seconds: Int = 10, name: String = "c") -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(Int64(seconds), 1)),
         start: Time(Int64(start), 1), mediaDuration: Time(100, 1))
}

private func trackMask(_ track: Track.ID?, luma: Bool = false, invert: Bool = false, enabled: Bool = true) -> ClipEffect {
    var e = ClipEffect(kind: ClipEffect.trackMaskKind, parameters: ClipEffect.defaultParameters(for: ClipEffect.trackMaskKind))
    e.maskTrack = track
    e.enabled = enabled
    if luma { e.parameters[ClipEffect.trackMaskModeKey] = AnimatedProperty(1) }
    if invert { e.parameters[ClipEffect.trackMaskInvertKey] = AnimatedProperty(1) }
    return e
}

private func timeline(_ e: (Track.ID) -> ClipEffect) throws -> (Timeline, v1: Track.ID, v2: Track.ID, effect: ClipEffect) {
    var v2 = Track(kind: .video)
    try v2.overwrite(clip(0, name: "matte"))
    var c = clip(0, name: "consumer")
    let fx = e(v2.id)
    c.effects = [fx]
    var v1 = Track(kind: .video)
    try v1.overwrite(c)
    return (Timeline(name: "S", format: fmt, tracks: [v1, v2]), v1.id, v2.id, fx)
}

@Suite struct TrackMaskTests {
    @Test func catalogOffersModeAndInvert() throws {
        let spec = try #require(EffectCatalog.all.first { $0.kind == ClipEffect.trackMaskKind })
        #expect(spec.title == "Track Mask")
        #expect(spec.params.map(\.key) == [ClipEffect.trackMaskModeKey, ClipEffect.trackMaskInvertKey])
        let e = ClipEffect(kind: ClipEffect.trackMaskKind, parameters: ClipEffect.defaultParameters(for: ClipEffect.trackMaskKind))
        #expect(e.maskTrack == nil)
        #expect(e.scalar(ClipEffect.trackMaskModeKey, atLocal: .zero) == 0)
    }

    @Test func evaluatesToAnIntersectingPictureMask() {
        let id = UUID()
        var c = clip(0)
        c.effects = [trackMask(id, luma: true, invert: true)]
        let masks = c.effects(at: .zero).masks
        #expect(masks.count == 1)
        let m = masks[0]
        #expect(m.source == .picture && m.pictureTrack == id)
        #expect(m.pictureChannel == .brightness && m.inverted)
        #expect(m.mode == .intersect)
    }

    @Test func alphaIsTheShapeChannelAndNotInverted() {
        var c = clip(0)
        c.effects = [trackMask(UUID())]
        let m = c.effects(at: .zero).masks[0]
        #expect(m.pictureChannel == .shape && !m.inverted)
    }

    @Test func noTrackOrDisabledIsInert() {
        var c = clip(0)
        c.effects = [trackMask(nil)]
        #expect(c.effects(at: .zero).masks.isEmpty)
        c.effects = [trackMask(UUID(), enabled: false)]
        #expect(c.effects(at: .zero).masks.isEmpty)
    }

    @Test func comesAfterTheClipsOwnMasks() {
        var c = clip(0)
        c.masks = [ClipMask.make(.rectangle, name: "Mask (1)")]
        c.effects = [trackMask(UUID())]
        let masks = c.effects(at: .zero).masks
        #expect(masks.count == 2)
        #expect(masks[0].source == .path && masks[1].source == .picture)
    }

    @Test func codableStoresTheTrackOnlyWhenSet() throws {
        let none = trackMask(nil)
        #expect(!String(decoding: try JSONEncoder().encode(none), as: UTF8.self).contains("maskTrack"))
        let set = trackMask(UUID())
        let data = try JSONEncoder().encode(set)
        #expect(String(decoding: data, as: UTF8.self).contains("maskTrack"))
        #expect(try JSONDecoder().decode(ClipEffect.self, from: data) == set)
    }

    @Test func evaluationAddsTheMatteLayersOfTheTrack() throws {
        let (tl, _, v2, _) = try timeline { trackMask($0) }
        let ls = tl.videoLayers(at: Time(1, 1))
        let matte = ls.filter { $0.matteFor != nil }
        #expect(matte.count == 1 && matte[0].matteFor == v2)
    }

    @Test func deleteTrackClearsTheLink() throws {
        var (tl, v1, v2, _) = try timeline { trackMask($0) }
        try tl.removeTrack(v2)
        let c = try #require(tl.tracks.first { $0.id == v1 }?.clips.first)
        #expect(c.effects.first?.maskTrack == nil)
        #expect(c.effects(at: .zero).masks.isEmpty)
    }

    @Test func selectionMarksTheReadTrack() throws {
        let (tl, v1, v2, _) = try timeline { trackMask($0) }
        let id = try #require(tl.tracks.first { $0.id == v1 }?.clips.first?.id)
        #expect(tl.pictureMatteTracks(ofClips: [id]) == [v2])
    }

    @Test func remapFollowsCopiedTracks() throws {
        var (tl, v1, v2, _) = try timeline { trackMask($0) }
        let new = UUID()
        tl.remapPictureMasks(trackIDs: [v2: new])
        let c = try #require(tl.tracks.first { $0.id == v1 }?.clips.first)
        #expect(c.effects.first?.maskTrack == new)
    }

    @Test func v90GateOnlyForTheEffect() throws {
        let (tl, _, _, _) = try timeline { trackMask($0) }
        let p = Project(name: "P", timelines: [tl])
        #expect(p.containsV90Content)
        #expect(ProjectFile.writtenVersion(for: p) == 90)
        for m in [nil, ProjectFile.migrations] { #expect(try ProjectFile.decode(try ProjectFile.encode(p), migrations: m) == p) }
        var plain = tl
        plain.tracks[0].mapClipsKeepingTiming { var c = $0; c.effects = []; return c }
        let q = Project(name: "P", timelines: [plain])
        #expect(!q.containsV90Content)
        #expect(ProjectFile.writtenVersion(for: q) < 90)
    }

    @Test func aV89BuildRefusesAV90File() throws {
        let (tl, _, _, _) = try timeline { trackMask($0) }
        var obj = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(Project(name: "P", timelines: [tl]))) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: (any Error).self) { try ProjectFile.decode(data, migrations: nil) }
    }
}
