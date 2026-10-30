import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// Track headers, translated from `TrackHeaderView`: the target chip, the name, and the button slots (eye + lock on video,
/// S + M (+ lock) on audio, sync lock when off or hovered), with the Mac's slot math and colors.
extension TimelinePanel {
    static let chipWidth: CGFloat = 32, chipHeight: CGFloat = 20
    static let buttonSize: CGFloat = 24, buttonGap: CGFloat = 4, leftPadding: CGFloat = 6, rightPadding: CGFloat = 4

    static func buttonSize(rowHeight: CGFloat) -> CGFloat { rowHeight >= 30 ? buttonSize : max(14, min(buttonSize, rowHeight - 4)) }

    /// `TrackHeaderView.Slots` in header-local coordinates (`.zero` = not shown).
    struct Slots: Equatable {
        var lock: CGRect, sync: CGRect
        var eye: CGRect?, mute: CGRect?, solo: CGRect?
        var nameRight: CGFloat
    }

    /// `TrackHeaderView.slots`: right to left eye, lock (video) or S, M (audio), then lock, then sync lock.
    static func slots(width: CGFloat, height: CGFloat, kind: TrackKind, showsSync: Bool = false, showsLock: Bool? = nil) -> Slots {
        let s = buttonSize(rowHeight: height), y = ((height - s) / 2).rounded()
        var right = width - rightPadding
        func take() -> CGRect { defer { right -= s + buttonGap }; return CGRect(x: right - s, y: y, width: s, height: s) }
        var eye: CGRect?, mute: CGRect?, solo: CGRect?
        if kind == .video { eye = take() } else { solo = take(); mute = take() }
        let lock = (showsLock ?? (kind == .video)) ? take() : .zero
        let sync = showsSync ? take() : .zero
        return Slots(lock: lock, sync: sync, eye: eye, mute: mute, solo: solo, nameRight: right)
    }

    static func chipRect(height: CGFloat) -> CGRect {
        let h = min(chipHeight, max(height - 4, 12))
        return CGRect(x: leftPadding, y: ((height - h) / 2).rounded(), width: chipWidth, height: h)
    }

    /// `TrackHeaderView.displayName`: the typed name, else "Video N" / "Audio N" from the chip.
    static func displayName(name: String, label: String, kind: TrackKind) -> String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard typed.isEmpty || typed.caseInsensitiveCompare(label) == .orderedSame else { return typed }
        let number = label.drop { !$0.isNumber }
        guard !number.isEmpty else { return "" }
        return "\(kind == .video ? "Video" : "Audio") \(number)"
    }

    /// Which buttons a header shows: the Mac `showsSync` / `showsLock` with the row hover.
    static func shows(_ track: Track, hovered: Bool) -> (sync: Bool, lock: Bool) {
        let sync = !track.syncLock || hovered
        return (sync, track.kind == .video || track.isLocked || hovered || sync)
    }

    /// Fixed slots (lock and sync keep their place whether shown or not) and the name's right end.
    static func layout(_ track: Track, width: CGFloat, height: CGFloat, hovered: Bool) -> Slots {
        let show = shows(track, hovered: hovered)
        var sl = slots(width: width, height: height, kind: track.kind, showsSync: true, showsLock: true)
        let first = [show.sync ? sl.sync : nil, show.lock ? sl.lock : nil, sl.mute, sl.eye].compactMap { $0 }.map(\.minX).min()
        sl.nameRight = (first ?? width) - buttonGap
        if !show.lock { sl.lock = .zero }
        if !show.sync { sl.sync = .zero }
        return sl
    }

    /// The header button under a panel point, as the toggle it fires.
    func headerHit(_ p: CGPoint) -> (Track.ID, TrackToggle)? {
        guard p.x >= TimelineGeometry.toolColumnWidth, p.x < TimelineGeometry.contentOriginX, p.y >= TimelineGeometry.rulerHeight,
              let row = rows.first(where: { p.y >= $0.y && p.y < $0.maxY }),
              let track = timeline.tracks.first(where: { $0.id == row.track }) else { return nil }
        let local = CGPoint(x: p.x - TimelineGeometry.toolColumnWidth, y: p.y - row.y)
        let sl = Self.layout(track, width: TimelineGeometry.headerWidth, height: row.height, hovered: hoverTrack == track.id)
        if targetChipRect(height: row.height).contains(local) { return (track.id, .target) }
        let buttons: [(CGRect?, TrackToggle)] = [(sl.eye, .visible), (sl.mute, .mute), (sl.solo, .solo), (sl.lock, .lock), (sl.sync, .syncLock)]
        for (r, t) in buttons { if let r, r != .zero, r.contains(local) { return (track.id, t) } }
        return nil
    }

    func drawHeaders(_ cv: inout Canvas, rows: [TrackRow]) {
        let col = CGRect(x: TimelineGeometry.toolColumnWidth, y: TimelineGeometry.rulerHeight, width: TimelineGeometry.headerWidth,
                         height: max(size.height - TimelineGeometry.rulerHeight, 0))
        cv.fill(col, theme.panel)
        cv.fill(CGRect(x: col.maxX - 1, y: col.minY, width: 1, height: col.height), theme.separator)
        cv.saveGState()
        cv.clip(to: col)
        let split = Self.splitRow(rows)
        for (i, row) in rows.enumerated() {
            guard row.maxY > col.minY, row.y < col.maxY, let track = timeline.tracks.first(where: { $0.id == row.track }) else { continue }
            cv.saveGState()
            cv.translateBy(x: col.minX, y: row.y)
            drawHeader(&cv, track: track, label: row.label, width: col.width, height: row.height, isSplitRow: i == split)
            cv.restoreGState()
        }
        drawCaptionHeaders(&cv)
        drawMixRow(&cv)
        cv.restoreGState()
    }

    /// `TrackHeaderView.draw` plus its buttons (`TrackHeaderButton.draw`), in header-local points.
    func drawHeader(_ cv: inout Canvas, track: Track, label: String, width: CGFloat, height: CGFloat, isSplitRow: Bool) {
        cv.fill(CGRect(x: 0, y: 0, width: width, height: height), theme.panel)
        if isSplitRow { cv.fill(CGRect(x: 0, y: height - 2, width: width, height: 2), theme.trackHeaderLine) }
        else { cv.fill(CGRect(x: 0, y: height - 1, width: width, height: 1), theme.trackRowLine) }
        cv.fill(CGRect(x: width - 1, y: 0, width: 1, height: height), theme.separator)

        drawPatch(&cv, track: track.id, height: height)
        let chip = targetChipRect(height: height)
        cv.fill(roundedRect: chip, radius: DrawTheme.Radius.small.cg, track.isTargeted ? theme.accentFill : theme.fill)
        cv.draw(label, in: chip, fontSize: 10, track.isTargeted ? theme.onClip : theme.label2, align: .center)

        let hovered = hoverTrack == track.id
        let sl = Self.layout(track, width: width, height: height, hovered: hovered)
        let local = hovered ? hoverPoint.map { CGPoint(x: $0.x - TimelineGeometry.toolColumnWidth, y: $0.y - (rows.first { $0.track == track.id }?.y ?? 0)) } : nil
        func button(_ r: CGRect?, icon: SQIcon? = nil, letter: String? = nil, filled: Bool = false, isOn: Bool = false, tint: DrawColor) {
            guard let r, r != .zero else { return }
            let hot = local.map { r.contains($0) } ?? false
            if filled { cv.fill(roundedRect: r, radius: DrawTheme.Radius.small.cg, isOn ? theme.fillPressed : (hot ? theme.fillHover : theme.fill)) }
            else if hot { cv.fill(roundedRect: r, radius: DrawTheme.Radius.small.cg, theme.fillHover) }
            let color = hot && !isOn && tint == theme.label2 ? theme.label : tint
            if let letter { cv.draw(letter, in: r, fontSize: 10, color, align: .center) }
            else if let icon {
                let s = DrawTheme.TypeSize.body.cg            // `Theme.Typography.symbolInline` (11 pt)
                cv.draw(icon: icon, at: CGPoint(x: (r.midX - s / 2).rounded(), y: (r.midY - s / 2).rounded()), size: s, color)
            }
        }
        if track.kind == .video {
            button(sl.eye, icon: track.isVisible ? .eye : .eyeOff, tint: track.isVisible ? theme.label2 : skin.warning)
        } else {
            button(sl.mute, letter: "M", filled: true, isOn: track.isMuted, tint: track.isMuted ? theme.accent : theme.label2)
            button(sl.solo, letter: "S", filled: true, isOn: track.isSolo, tint: track.isSolo ? theme.yellow : theme.label2)
        }
        button(sl.lock, icon: .trackLock, tint: track.isLocked ? theme.accent : theme.label2)
        button(sl.sync, icon: .trackSyncLock, tint: track.syncLock ? theme.label3 : skin.warning)

        let name = Self.displayName(name: track.name, label: label, kind: track.kind)
        let nameX = chip.maxX + Self.buttonGap, w = sl.nameRight - nameX
        guard !name.isEmpty, w > 12 else { return }
        let h: CGFloat = 14
        cv.draw(name, at: CGPoint(x: nameX, y: ((height - h) / 2).rounded()), fontSize: DrawTheme.TypeSize.body.cg, theme.label2, maxWidth: w)
    }
}
