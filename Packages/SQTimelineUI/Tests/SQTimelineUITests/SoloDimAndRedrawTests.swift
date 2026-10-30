import AppKit
import SQCore
import Testing
@testable import SQTimelineUI

/// Solo silences every other audio track: those dim exactly like muted ones, and un-dim when the solo ends.
/// Eye, mute and solo toggles redraw the timeline and rebuild the affected header.
@MainActor @Suite struct SoloDimAndRedrawTests {
    private static let fd = Time(1, 24)

    private func timeline() -> Timeline {
        func clip(_ kind: TrackKind) -> Clip {
            Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: Self.fd * 48), start: .zero)
        }
        let tracks = [Track(kind: .video, clips: [clip(.video)], name: "V1"),
                      Track(kind: .audio, clips: [clip(.audio)], name: "A1"),
                      Track(kind: .audio, clips: [clip(.audio)], name: "A2")]
        var t = Timeline(name: "t", frameDuration: Self.fd, tracks: tracks)
        t.captionTracks = [CaptionTrack(items: [CaptionItem(lines: ["x"], range: TimeRange(start: .zero, end: Time(2, 1)))])]
        return t
    }

    @Test func otherAudioTracksDimLikeMutedWhileASoloIsActive() {
        var t = timeline()
        t.tracks[1].isSolo = true
        let active = TimelineView.audioSoloActive(in: t)
        #expect(active)
        var muted = Track(kind: .audio); muted.isMuted = true
        let silenced = TimelineView.clipFade(clipEnabled: true, track: t.tracks[2], selected: false, audioSoloActive: active)
        #expect(silenced == TimelineView.clipFade(clipEnabled: true, track: muted, selected: false))
        let silencedSel = TimelineView.clipFade(clipEnabled: true, track: t.tracks[2], selected: true, audioSoloActive: active)
        #expect(silencedSel == TimelineView.inactiveTrackSelectedFade)
        #expect(TimelineView.clipFade(clipEnabled: true, track: t.tracks[1], selected: false, audioSoloActive: active) == nil)
        #expect(TimelineView.clipFade(clipEnabled: true, track: t.tracks[0], selected: false, audioSoloActive: active) == nil)
        t.tracks[1].isSolo = false
        #expect(!TimelineView.audioSoloActive(in: t))
        #expect(TimelineView.clipFade(clipEnabled: true, track: t.tracks[2], selected: false, audioSoloActive: false) == nil)
    }

    @Test func captionEyeUsesTheSameStateColorsAsTrackEyes() {
        #expect(TimelineView.captionEyeTint(visible: true) == Theme.Colors.label3)
        #expect(TimelineView.captionEyeTint(visible: false) == Theme.Colors.warning)
    }

    @Test func headerRebuildsWhenTheToggledStateChanges() {
        var a = Track(kind: .audio, name: "A1")
        let h = TrackHeaderView(track: a, label: "A1")
        let n = h.contentApplyCount
        h.apply(track: a, label: "A1")
        #expect(h.contentApplyCount == n)
        a.isMuted = true; h.apply(track: a, label: "A1")
        a.isSolo = true; h.apply(track: a, label: "A1")
        a.isVisible = false; h.apply(track: a, label: "A1")
        #expect(h.contentApplyCount == n + 3)
    }

    private func pixels(_ v: TimelineView) -> [UInt8] {
        let size = CGSize(width: 900, height: 320)
        do {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 320, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
            cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return Array(UnsafeBufferPointer(start: rep.bitmapData!, count: rep.bytesPerRow * 320))
        }
    }

    /// A live view that already drew once (content cache filled) must show the toggle on its next draw.
    @Test func togglingEyeMuteSoloAndCaptionEyeChangesTheNextDraw() {
        let toggles: [(inout Timeline) -> Void] = [
            { $0.tracks[0].isVisible = false }, { $0.tracks[1].isMuted = true },
            { $0.tracks[1].isSolo = true }, { $0.captionTracks[0].isVisible = false }]
        for (i, toggle) in toggles.enumerated() {
            let v = TimelineView(timeline: timeline(), frame: NSRect(x: 0, y: 0, width: 900, height: 320))
            v.setZoom(pointsPerSecond: 40)
            let before = pixels(v)
            var t = timeline(); toggle(&t)
            v.setTimeline(t)
            #expect(pixels(v) != before, "toggle \(i)")
            v.setTimeline(timeline())                               // toggled back: the dim goes away again
            #expect(pixels(v) == before, "toggle \(i) back")
        }
    }
}
