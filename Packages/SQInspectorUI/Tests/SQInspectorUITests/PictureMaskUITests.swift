import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// C6 T5: Picture mask UI (row controls, track choices, add from the monitor menu, header marker).
@MainActor @Suite struct PictureMaskUITests {
    final class Log { var edits: [(String, Clip)] = [] }

    /// V1 (consumer), V2 (clip "Overlay" 0...10), V3 (clip at 20...30), audio. Playhead at 6 s.
    @MainActor struct Rig {
        var model = EffectControlsModel()
        var timeline: Timeline
        var log = Log()
        var v1: Track.ID, v2: Track.ID, v3: Track.ID
        var consumer: Clip
    }

    func rig() throws -> Rig {
        func clip(_ name: String, _ start: Int) -> Clip {
            Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)),
                 start: Time(Int64(start), 1), mediaDuration: Time(100, 1))
        }
        var t1 = Track(kind: .video), t2 = Track(kind: .video), t3 = Track(kind: .video)
        let consumer = clip("Base", 0)
        try t1.overwrite(consumer); try t2.overwrite(clip("Overlay", 0)); try t3.overwrite(clip("Late", 20))
        let tl = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                          tracks: [t1, t2, t3, Track(kind: .audio)])
        var r = Rig(timeline: tl, v1: t1.id, v2: t2.id, v3: t3.id, consumer: consumer)
        let log = r.log
        r.model.timeline = { tl }
        r.model.onEdit = { c, n, _ in log.edits.append((n, c)) }
        r.model.setClip(consumer); r.model.playhead = Time(6, 1)
        return r
    }

    @Test func choicesListNoTrackThenNearestAboveFirstWithClipNames() throws {
        let r = try rig()
        let c = r.model.pictureTrackChoices()
        #expect(c.map(\.title) == ["No track", "V2 \u{2013} Overlay", "V3"])
        #expect(c.map(\.track) == [nil, r.v2, r.v3])
    }

    @Test func addedFromMenuIsOneUndoStepWithTheDefaultTrack() throws {
        let r = try rig()
        // V2 has a clip at the playhead and is nearest above, so it is the default.
        #expect(r.model.defaultPictureTrack == r.v2)
        let id = r.model.addPictureMask(track: r.model.defaultPictureTrack)
        #expect(r.log.edits.map(\.0) == ["Add Mask"])
        #expect(r.model.clip?.mask(id!)?.source == .picture && r.model.clip?.mask(id!)?.pictureTrack == r.v2)
        #expect(r.model.selectedSection == .mask(id!))
    }

    @Test func addingWithAnInvalidTrackIsRefused() throws {
        let r = try rig()
        #expect(r.model.addPictureMask(track: r.v1) == nil)          // the clip's own track
        #expect(r.model.addPictureMask(track: UUID()) == nil)
        #expect(r.log.edits.isEmpty)
    }

    @Test func trackAndChannelChangesAreOneStepEach() throws {
        let r = try rig()
        let id = r.model.addPictureMask(track: nil)!
        r.log.edits.removeAll()
        r.model.setMaskPictureTrack(id, r.v3)
        r.model.setMaskPictureChannel(id, .brightness)
        #expect(r.log.edits.map(\.0) == ["Change Mask Track", "Change Mask Channel"])
        #expect(r.model.clip?.mask(id)?.pictureTrack == r.v3 && r.model.clip?.mask(id)?.pictureChannel == .brightness)
        r.model.setMaskPictureTrack(id, r.v3)                  // same value: no step
        #expect(r.log.edits.count == 2)
        r.model.setMaskPictureTrack(id, r.v1)                  // the clip's own track is refused
        #expect(r.model.clip?.mask(id)?.pictureTrack == r.v3)
        r.model.setMaskPictureTrack(id, nil)
        #expect(r.model.clip?.mask(id)?.pictureTrack == nil)
    }

    @Test func rowsHideFeatherAndExpansionAndSwapTheTrackingRow() throws {
        let r = try rig()
        let id = r.model.addPictureMask(track: r.v2)!
        let rows = EffectControlsLayout.rows(sections: r.model.visibleSections, collapsed: [], expanded: [],
                                             pictureMasks: r.model.pictureMaskIDs).map(\.kind)
        #expect(rows.contains(.property(.mask(id, .opacity))))
        #expect(!rows.contains(.property(.mask(id, .feather))) && !rows.contains(.property(.mask(id, .expansion))))
        #expect(rows.suffix(3) == [.pictureMask(id), .maskControls(id), .maskUse(id)])
        #expect(!rows.contains(.maskTrack(id)))
        // A path mask keeps its rows.
        let path = EffectControlsLayout.rows(sections: r.model.visibleSections, collapsed: [], expanded: []).map(\.kind)
        #expect(path.contains(.maskTrack(id)))
    }

    @Test func rowPopupsShowTheTracksAndNoTrackAfterTheTrackIsDeleted() throws {
        var r = try rig()
        let id = r.model.addPictureMask(track: r.v2)!
        let row = PictureMaskRow(maskID: id, model: r.model)
        #expect(row.trackPopup.itemTitles == ["No track", "V2", "V3"])
        #expect(row.trackPopup.indexOfSelectedItem == 1)
        #expect(row.channelPopup.itemTitles == ["Shape", "Brightness"])
        // Delete Track V2: the link is cleared in the same edit, the row shows "No track".
        try r.timeline.removeTrack(r.v2)
        var c = r.model.clip!
        c.masks = c.masks.map { var m = $0; m.pictureTrack = nil; return m }
        let tl = r.timeline
        r.model.timeline = { tl }
        r.model.setClip(c)
        row.update()
        #expect(row.trackPopup.indexOfSelectedItem == 0)
        #expect(row.trackPopup.itemTitles == ["No track", "V2"])
    }

    @Test func headerMarkerFollowsTheFlag() throws {
        let r = try rig()
        let header = TrackHeaderView(track: r.timeline.tracks[1], label: "V2")
        #expect(!header.isMatteSource)
        header.isMatteSource = true
        #expect(header.sqToolTip != nil)
        header.isMatteSource = false
        #expect(header.sqToolTip == nil)
    }
}
