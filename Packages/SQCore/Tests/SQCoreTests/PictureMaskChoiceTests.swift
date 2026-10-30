import Foundation
import Testing
@testable import SQCore

// C6 T5: which tracks the Picture mask UI offers, the default track, and the unlinked count for the export warning.

private let fmt = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))

private func clip(_ start: Int, seconds: Int = 5) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(Int64(seconds), 1)),
         start: Time(Int64(start), 1), mediaDuration: Time(100, 1))
}

private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}

@Suite struct PictureMaskChoiceTests {
    /// V1 V2 V3 V4 (bottom first) plus an audio track; the consumer is on V2.
    func rig(v3Clips: [Clip], v4Clips: [Clip]) throws -> (Timeline, [Track.ID]) {
        let ts = [try track([clip(0)]), try track([clip(0)]), try track(v3Clips), try track(v4Clips), try track([], kind: .audio)]
        return (Timeline(name: "S", format: fmt, tracks: ts), ts.map(\.id))
    }

    @Test func nearestFirstListsAboveThenBelowAndSkipsAudioAndOwn() throws {
        let (t, ids) = try rig(v3Clips: [], v4Clips: [])
        #expect(t.pictureMaskTracksNearestFirst(forClipOn: ids[1]).map(\.id) == [ids[2], ids[3], ids[0]])
    }

    @Test func defaultIsNearestAboveWithAClipAtThePlayhead() throws {
        let (t, ids) = try rig(v3Clips: [clip(10)], v4Clips: [clip(0)])
        #expect(t.defaultPictureMaskTrack(forClipOn: ids[1], at: Time(2, 1)) == ids[3])
        let (u, uids) = try rig(v3Clips: [clip(0)], v4Clips: [clip(0)])
        #expect(u.defaultPictureMaskTrack(forClipOn: uids[1], at: Time(2, 1)) == uids[2])
    }

    @Test func defaultFallsBackToNearestAboveThenBelowThenNil() throws {
        let (t, ids) = try rig(v3Clips: [], v4Clips: [])
        #expect(t.defaultPictureMaskTrack(forClipOn: ids[1], at: Time(2, 1)) == ids[2])
        #expect(t.defaultPictureMaskTrack(forClipOn: ids[3], at: Time(2, 1)) == ids[2])
        let single = Timeline(name: "S", format: fmt, tracks: [try track([clip(0)])])
        #expect(single.defaultPictureMaskTrack(forClipOn: single.tracks[0].id, at: .zero) == nil)
    }

    @Test func unlinkedCountsEnabledPictureMasksWithoutTrack() throws {
        var c = clip(0)
        c.masks = [ClipMask.makePicture(track: nil), ClipMask.makePicture(track: UUID())]
        var off = ClipMask.makePicture(track: nil); off.enabled = false
        c.masks.append(off)
        let t = Timeline(name: "S", format: fmt, tracks: [try track([c])])
        #expect(t.unlinkedPictureMaskCount == 1)
        #expect(Timeline(name: "E", format: fmt, tracks: []).unlinkedPictureMaskCount == 0)
    }

    @Test func matteTracksOfSelectedClips() throws {
        let matte = try track([clip(0)])
        var c = clip(0)
        c.masks = [ClipMask.makePicture(track: matte.id)]
        var other = clip(0); other.masks = [ClipMask.makePicture(track: UUID())]
        let t = Timeline(name: "S", format: fmt, tracks: [try track([c]), matte, try track([other])])
        #expect(t.pictureMatteTracks(ofClips: [c.id]) == [matte.id])
        #expect(t.pictureMatteTracks(ofClips: []).isEmpty)
    }

    @Test func unlinkedSkipsHiddenTracksAndFollowsNestedSequences() throws {
        var c = clip(0); c.masks = [ClipMask.makePicture(track: nil)]
        var hidden = try track([c]); hidden.isVisible = false
        var inner = clip(0); inner.masks = [ClipMask.makePicture(track: nil)]
        let innerTL = Timeline(name: "In", format: fmt, tracks: [try track([inner])])
        var nest = clip(0); nest.sequence = innerTL.id
        let outer = Timeline(name: "Out", format: fmt, tracks: [hidden, try track([nest])])
        #expect(outer.unlinkedPictureMaskCount(sequences: [innerTL.id: innerTL]) == 1)
        #expect(outer.unlinkedPictureMaskCount == 0)
    }
}
