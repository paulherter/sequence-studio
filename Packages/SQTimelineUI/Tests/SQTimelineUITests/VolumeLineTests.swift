#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 30)
private func clip(_ start: Int64 = 0, _ frames: Int64 = 90) -> Clip {
    Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * frames), start: fd * start)
}

/// Audio row 80 pt tall at y 100; 4 pt per frame; clip from frame 0.
@Suite struct VolumeLineTests {
    let geo = TimelineGeometry(frameDuration: fd, pointsPerFrame: 4)
    func rect(_ c: Clip) -> CGRect {
        CGRect(x: geo.x(for: c.start), y: 100, width: geo.width(of: c.source.duration), height: 80)
    }

    @Test func dbAndYAreInverseAndClampedAtTheEnds() {
        let lane = CGRect(x: 0, y: 0, width: 100, height: 55)
        #expect(abs(VolumeLine.y(forDB: VolumeLine.dbTop, in: lane) - 0) < 1e-9)
        #expect(abs(VolumeLine.y(forDB: VolumeLine.dbBottom, in: lane) - 55) < 1e-9)
        for db in stride(from: -35.0, through: 15.0, by: 5.0) {
            #expect(abs(VolumeLine.db(forY: VolumeLine.y(forDB: db, in: lane), in: lane) - db) < 1e-9)
        }
        #expect(VolumeLine.db(forY: -50, in: lane) == VolumeLine.dbTop)
        #expect(VolumeLine.db(forY: 56, in: lane) == AudioGain.silenceDB)        // below the bottom = silence
        #expect(VolumeLine.y(forDB: AudioGain.silenceDB, in: lane) == 55)
    }

    @Test func onlyTallRowsGetABand() {
        #expect(!VolumeLine.isAvailable(rowHeight: 22) && !VolumeLine.isAvailable(rowHeight: 38))
        #expect(VolumeLine.isAvailable(rowHeight: VolumeLine.minRowHeight))
    }

    @Test func hitsTheLineAtItsHeightButNotFarAway() {
        let c = clip(); let r = rect(c)
        let lane = VolumeLine.lane(in: r)
        let y = VolumeLine.y(forDB: 0, in: lane)
        let x = geo.x(for: fd * 30)
        #expect(VolumeLine.hit(clip: c, clipRect: r, at: CGPoint(x: x, y: y + 2), geometry: geo) == .line(atLocal: fd * 30))
        #expect(VolumeLine.hit(clip: c, clipRect: r, at: CGPoint(x: x, y: y + 15), geometry: geo) == nil)
        #expect(VolumeLine.hit(clip: c, clipRect: r, at: CGPoint(x: r.maxX + 20, y: y), geometry: geo) == nil)
    }

    @Test func keyBeatsLine() {
        var c = clip()
        let k = c.addVolumeKey(atLocal: fd * 30)
        let r = rect(c), lane = VolumeLine.lane(in: r)
        let p = CGPoint(x: geo.x(for: fd * 30) + 2, y: VolumeLine.y(forDB: 0, in: lane) + 2)
        #expect(VolumeLine.hit(clip: c, clipRect: r, at: p, geometry: geo) == .key(k))
    }

    @Test func draggingTheLineDownLowersTheWholeClip() {
        let c = clip(); let r = rect(c), lane = VolumeLine.lane(in: r)
        let y0 = VolumeLine.y(forDB: 0, in: lane)
        var g = VolumeLineGesture(clip: c, hit: .line(atLocal: fd * 30), start: CGPoint(x: 100, y: y0), clipRect: r, geometry: geo, addKey: false)
        let moved = g.update(to: CGPoint(x: 100, y: VolumeLine.y(forDB: -10, in: lane)))
        #expect(abs(AudioGain.db(fromLinear: moved.animation.volume.value) + 10) < 1e-6)
        #expect(!moved.animation.volume.isAnimated)
        // Dragging back to the start restores the original (the gesture always starts from the clip it began with).
        let back = g.update(to: CGPoint(x: 100, y: y0))
        #expect(back == c)
    }

    @Test func cmdClickAddsAKeyOnTheLineAndDraggingItMovesTimeAndLevel() {
        let c = clip(); let r = rect(c), lane = VolumeLine.lane(in: r)
        let x = geo.x(for: fd * 30)
        var g = VolumeLineGesture(clip: c, hit: .line(atLocal: fd * 30), start: CGPoint(x: x, y: VolumeLine.y(forDB: 0, in: lane)),
                                  clipRect: r, geometry: geo, addKey: true)
        let added = g.update(to: CGPoint(x: x, y: VolumeLine.y(forDB: 0, in: lane)))
        #expect(added.animation.volume.track.keys.count == 1)
        let moved = g.update(to: CGPoint(x: geo.x(for: fd * 45), y: VolumeLine.y(forDB: -6, in: lane)))
        let key = moved.animation.volume.track.keys[0]
        #expect(key.time == fd * 45 && abs(AudioGain.db(fromLinear: key.value) + 6) < 1e-6)
    }

    @Test func draggingAKeyIsClampedToTheClip() {
        var c = clip()
        let k = c.addVolumeKey(atLocal: fd * 30)
        let r = rect(c), lane = VolumeLine.lane(in: r)
        var g = VolumeLineGesture(clip: c, hit: .key(k), start: CGPoint(x: geo.x(for: fd * 30), y: VolumeLine.y(forDB: 0, in: lane)),
                                  clipRect: r, geometry: geo, addKey: false)
        let far = g.update(to: CGPoint(x: r.maxX + 500, y: VolumeLine.y(forDB: 99, in: lane)))
        let key = far.animation.volume.track.key(id: k)!
        #expect(key.time == c.source.duration)
        #expect(abs(AudioGain.db(fromLinear: key.value) - AudioGain.maxVolumeDB) < 1e-6)
    }

    @Test func lineSamplesFollowTheKeys() {
        var c = clip()
        let a = c.addVolumeKey(atLocal: .zero), b = c.addVolumeKey(atLocal: fd * 90)
        c.animation.volume.track.set(a, value: 1); c.animation.volume.track.set(b, value: 0.5)
        let pts = VolumeLine.points(clip: c, clipRect: rect(c), visible: rect(c), step: 90)
        #expect(pts.count >= 3)
        let lane = VolumeLine.lane(in: rect(c))
        #expect(abs(pts.first!.y - VolumeLine.y(forDB: 0, in: lane)) < 0.5)
        #expect(abs(pts.last!.y - VolumeLine.y(forDB: AudioGain.db(fromLinear: 0.5), in: lane)) < 0.5)
    }

    @Test func aClickWithoutMovementChangesNothing() {
        var c = clip()
        let k = c.addVolumeKey(atLocal: fd * 30)
        let r = rect(c), lane = VolumeLine.lane(in: r)
        let y = VolumeLine.y(forDB: -3.3, in: lane)
        var g = VolumeLineGesture(clip: c, hit: .line(atLocal: fd * 10), start: CGPoint(x: 80, y: y), clipRect: r, geometry: geo, addKey: false)
        #expect(g.update(to: CGPoint(x: 80, y: y)) == c)
        var kg = VolumeLineGesture(clip: c, hit: .key(k), start: CGPoint(x: 80, y: y), clipRect: r, geometry: geo, addKey: false)
        #expect(kg.update(to: CGPoint(x: 80.3, y: y)) == c)
        var plain = clip()
        let before = plain
        plain.shiftVolumeLine(atLocal: fd * 3, byDB: 0)
        #expect(plain == before)
    }

    @Test func edgeTrimBeatsAKeyNearTheClipEnds() {
        let c = clip(); let r = rect(c)
        #expect(VolumeLine.edgeWins(at: CGPoint(x: r.minX + 3, y: r.midY), clipRect: r))
        #expect(VolumeLine.edgeWins(at: CGPoint(x: r.maxX - 5, y: r.midY), clipRect: r))
        #expect(!VolumeLine.edgeWins(at: CGPoint(x: r.midX, y: r.midY), clipRect: r))
    }
}
