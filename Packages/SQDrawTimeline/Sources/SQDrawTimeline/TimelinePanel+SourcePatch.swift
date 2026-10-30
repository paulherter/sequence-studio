import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import SQUIKit

/// Source patching (MON-30 / TL-44), translated from `TimelineView+SourcePatch` and the `TrackHeaderView` patch chip:
/// while the Source view holds a clip, a column left of the target chips shows where its video ("V") and audio ("A")
/// go for Insert / Overwrite. Click a chip: that stream on / off (Option: this stream only). Drag it onto another track
/// of its kind: patched there (Shift: both streams by the same offset).
extension TimelinePanel {
    static let patchWidth: CGFloat = 16, patchGap: CGFloat = 4

    /// The patch chip cell of a header row (header-local).
    static func patchRect(height: CGFloat) -> CGRect {
        let h = min(chipHeight, max(height - 4, 12))
        return CGRect(x: leftPadding, y: ((height - h) / 2).rounded(), width: patchWidth, height: h)
    }

    /// The target chip, moved right of the patch column while it shows.
    func targetChipRect(height: CGFloat) -> CGRect {
        let r = Self.chipRect(height: height)
        return sourcePatchStreams == nil ? r : r.offsetBy(dx: Self.patchWidth + Self.patchGap, dy: 0)
    }

    /// Caption rows move their chip by the same amount as the track headers (`patchColumnOffset`).
    var patchColumnOffset: CGFloat { sourcePatchStreams == nil ? 0 : Self.patchWidth + Self.patchGap - 2 }

    /// Track a stream's chip sits on: its patched track, shown even while disconnected.
    func patchChipTrack(_ kind: TrackKind) -> Track.ID? {
        var on = timeline.sourcePatch
        on[kind].isConnected = true
        return timeline.patchedTrack(on, kind: kind)
    }

    /// The chip a header row shows; nil without a source, for a stream the source lacks, or on another track.
    func patchChip(for track: Track.ID) -> (kind: TrackKind, connected: Bool)? {
        guard let streams = sourcePatchStreams else { return nil }
        for kind in [TrackKind.video, .audio] where streams.contains(kind) && patchChipTrack(kind) == track {
            return (kind, timeline.sourcePatch[kind].isConnected)
        }
        return nil
    }

    /// The track of `kind` whose header row is under `p`; nil off the header column or on another kind.
    func patchTrack(_ kind: TrackKind, at p: CGPoint) -> Track.ID? {
        guard p.x >= TimelineGeometry.toolColumnWidth, p.x <= TimelineGeometry.contentOriginX,
              p.y >= TimelineGeometry.rulerHeight else { return nil }
        return rows.first { $0.kind == kind && p.y >= $0.y && p.y < $0.maxY }?.track
    }

    /// A press on a patch chip (a little larger than drawn, as on the Mac) begins the click or drag.
    mutating func patchDown(_ p: CGPoint) -> Bool {
        guard sourcePatchStreams != nil, p.x >= TimelineGeometry.toolColumnWidth, p.x < TimelineGeometry.contentOriginX,
              let row = rows.first(where: { p.y >= $0.y && p.y < $0.maxY }), let chip = patchChip(for: row.track) else { return false }
        let local = CGPoint(x: p.x - TimelineGeometry.toolColumnWidth, y: p.y - row.y)
        guard Self.patchRect(height: row.height).insetBy(dx: -2, dy: -3).contains(local) else { return false }
        gesture = .patch(kind: chip.kind, down: p, dragging: false)
        return true
    }

    mutating func patchDragged(_ kind: TrackKind, down: CGPoint, dragging: Bool, at p: CGPoint) {
        let now = dragging || hypot(p.x - down.x, p.y - down.y) >= 3
        gesture = .patch(kind: kind, down: down, dragging: now)
        if now { patchDropTrack = patchTrack(kind, at: p) }
    }

    mutating func patchUp(_ kind: TrackKind, dragging: Bool, at p: CGPoint) -> [TimelineAction] {
        patchDropTrack = nil
        guard dragging else { return [.sourcePatchClick(kind, solo: dragModifiers.contains(.option))] }
        guard let hit = patchTrack(kind, at: p) else { return [] }
        return [.sourcePatchMove(kind, to: hit, both: dragModifiers.contains(.shift))]
    }

    /// Connected: accent fill, the letter on it. Disconnected: hairline outline, gray letter. Drop target: accent ring.
    func drawPatch(_ cv: inout Canvas, track: Track.ID, height: CGFloat) {
        guard sourcePatchStreams != nil else { return }
        let r = Self.patchRect(height: height).insetBy(dx: 0.5, dy: 0.5)
        let radius = DrawTheme.Radius.small.cg + 1
        if patchDropTrack == track { cv.stroke(roundedRect: r, radius: radius, width: 1, theme.accent) }
        guard let chip = patchChip(for: track) else { return }
        if chip.connected { cv.fill(roundedRect: r, radius: radius, theme.accentFill) }
        else { cv.stroke(roundedRect: r, radius: radius, width: 1, theme.label3) }
        cv.draw(chip.kind == .video ? "V" : "A", in: r, fontSize: 10, chip.connected ? theme.onClip : theme.label3, align: .center)
    }
}
