import AppKit
import SQCore
import SQMonitorUI

// Multi-angle Source view: the Source monitor shows every angle of the Angles clip under the playhead, side by side;
// a click on a tile gives the piece that angle (the same edit as the number key).
extension EditorPanels {
    func wireAnglesGrid() {
        source.onToggleAngles = { [weak self] in
            guard let self else { return }
            showsAllAngles.toggle()
            refreshAnglesGrid()
        }
        source.anglesAvailable = { [weak self] in self?.anglesPiece() != nil }
        source.model.onPickAngle = { [weak self] i in
            guard let self, let piece = anglesPiece() else { return }
            session.setAngle(i, on: piece.id)
        }
    }

    /// The video piece of an Angles clip under the playhead (the tiles show its picture angles).
    private func anglesPiece() -> Clip? {
        guard let tl = session.activeTimeline, let c = tl.anglesClip(at: session.playhead), c.kind == .video else { return nil }
        return c
    }

    func refreshAnglesGrid() {
        let model = source.model
        guard showsAllAngles, let tl = session.activeTimeline, let piece = anglesPiece(),
              let inner = piece.sequence.flatMap({ session.project.timeline($0) }) else {
            if model.angleTiles != nil { model.angleTiles = nil }
            return
        }
        let fd = tl.frameDuration
        let frames = inner.angleFrames(at: piece.angleInnerTime(at: session.playhead.snapped(to: fd)), frameDuration: fd)
        let names = inner.angleNames
        let active = min(max(piece.angle?.index ?? 0, 0), max(frames.count - 1, 0))
        let tiles = frames.enumerated().map { i, f in
            AngleTile(name: i < names.count ? names[i] : "Angle \(i + 1)",
                      image: f.flatMap { frame in session.project.media(frame.media).flatMap { clipThumbnails.frame(for: $0, at: frame.time) } },
                      isActive: i == active)
        }
        if model.angleTiles != tiles { model.angleTiles = tiles }
    }
}
