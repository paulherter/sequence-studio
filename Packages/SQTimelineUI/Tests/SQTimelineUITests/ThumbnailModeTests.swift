import AppKit
import Foundation
import SQCore
import SQUIKit
import Testing
@testable import SQTimelineUI

@Suite struct ThumbnailChoiceMappingTests {
    @Test func menuChoiceAndModeShareRawValuesAndTitles() {
        #expect(ThumbnailMode.allCases.map(\.rawValue) == ThumbnailModeChoice.allCases.map(\.rawValue))
        for m in ThumbnailMode.allCases { #expect(ThumbnailModeChoice(rawValue: m.rawValue)?.title == m.title) }
    }
}

@MainActor
@Suite struct ThumbnailModeTests {
    private let fd = Time(1, 30)

    @Test func headIsOneColumn() {
        let t = ThumbnailLayout.tiles(mode: .head, clipWidth: 200, column: 25, visible: 0...200)
        #expect(t == [ThumbnailTile(offset: 0, width: 25, anchor: .head, belowNameStrip: false)])
    }

    @Test func noColumnNoTiles() {
        #expect(ThumbnailLayout.tiles(mode: .continuous, clipWidth: 200, column: 0, visible: 0...200).isEmpty)
    }

    @Test func headAndTailPutsTheLastFrameAtTheRightEnd() {
        let t = ThumbnailLayout.tiles(mode: .headAndTail, clipWidth: 200, column: 25, visible: 0...200)
        #expect(t.count == 2)
        #expect(t[1].anchor == .tail)
        #expect(t[1].offset == 175)
        // Too short for two columns and a name: head only.
        #expect(ThumbnailLayout.tiles(mode: .headAndTail, clipWidth: 60, column: 25, visible: 0...60).count == 1)
    }

    @Test func continuousFillsTheClipAndCulls() {
        let all = ThumbnailLayout.tiles(mode: .continuous, clipWidth: 230, column: 25, visible: 0...230)
        #expect(all.count == 5)                                   // 4 x 50 + 30
        #expect(all.first?.anchor == .head)
        #expect(all.last?.anchor == .tail)
        #expect(all.last?.width == 30)
        #expect(all.filter { !$0.belowNameStrip }.isEmpty)
        let culled = ThumbnailLayout.tiles(mode: .continuous, clipWidth: 100_000, column: 25, visible: 5000...5200)
        #expect(culled.count <= 6)
        #expect(culled.first.map { $0.offset <= 5000 } == true)
    }

    @Test func mediaTimeFollowsSourceAndSnaps() {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: Time(10, 1), duration: Time(4, 1)),
                     start: Time(2, 1), mediaDuration: Time(60, 1))
        #expect(ThumbnailLayout.mediaTime(of: .head, clip: c, frameDuration: fd) == Time(10, 1))
        #expect(ThumbnailLayout.mediaTime(of: .tail, clip: c, frameDuration: fd) == Time(10, 1) + Time(119, 30))
        // Half way: 2 s into the clip, snapped to a quarter second.
        #expect(ThumbnailLayout.mediaTime(of: .fraction(0.5), clip: c, frameDuration: fd) == Time(12, 1))
    }

    @Test func preferenceRoundTripsAndDefaultsToHead() {
        let saved = UserDefaults.standard.string(forKey: ThumbnailPrefs.modeKey)
        defer { UserDefaults.standard.set(saved, forKey: ThumbnailPrefs.modeKey) }
        UserDefaults.standard.removeObject(forKey: ThumbnailPrefs.modeKey)
        #expect(ThumbnailPrefs.mode == .head)
        ThumbnailPrefs.mode = .continuous
        #expect(ThumbnailPrefs.mode == .continuous)
        UserDefaults.standard.set("nonsense", forKey: ThumbnailPrefs.modeKey)
        #expect(ThumbnailPrefs.mode == .head)
    }

    @Test func tilesDrawIntoTheClip() {
        let size = NSSize(width: 300, height: 60)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        let flipped = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        let tiles = ThumbnailLayout.tiles(mode: .headAndTail, clipWidth: 280, column: 25, visible: 0...280)
        ClipDrawing.draw(name: "Clip", rect: CGRect(origin: .zero, size: CGSize(width: 280, height: size.height)),
                         visible: CGRect(x: 0, y: 0, width: 300, height: 60), style: .video, isSelected: false, isOffline: false,
                         thumbnailTiles: tiles.map { ClipThumbnailPicture(tile: $0, image: nil) })
        NSGraphicsContext.restoreGraphicsState()
        // The tail column is painted in the well color at the right end.
        let tail = rep.colorAt(x: 270, y: 30)
        let middle = rep.colorAt(x: 140, y: 30)
        #expect(tail != nil && middle != nil && tail != middle)
    }
}

@Suite struct MarkerIndexModelTests {
    private let fd = Time(1, 30)

    private func timeline() throws -> Timeline {
        var c = Clip(name: "Interview", media: UUID(), kind: .video, source: TimeRange(start: Time(2, 1), duration: Time(4, 1)),
                     start: Time(1, 1), mediaDuration: Time(20, 1))
        c.markers = [Marker(time: Time(3, 1), name: "Quote", color: .blue, comment: "use this")]   // at sequence time 2 s
        var tr = Track(kind: .video)
        try tr.overwrite(c)
        var t = Timeline(name: "T", frameDuration: fd, tracks: [tr])
        t.markers = [Marker(time: Time(5, 1), name: "Outro", color: .red), Marker(time: Time(0, 1), name: "Intro", color: .green)]
        return t
    }

    @Test func listsSequenceAndClipMarkersInTimeOrder() throws {
        let m = MarkerIndexModel(timeline: try timeline())
        #expect(m.rows.map(\.name) == ["Intro", "Quote", "Outro"])
        #expect(m.rows[1].scopeLabel == "Interview")
        #expect(m.text(for: m.rows[1].time) == "00:00:02:00")
    }

    @Test func filtersByTextAndColor() throws {
        var m = MarkerIndexModel(timeline: try timeline())
        m.query = "USE"
        #expect(m.rows.map(\.name) == ["Quote"])
        m.query = ""
        m.color = .red
        #expect(m.rows.map(\.name) == ["Outro"])
        #expect(m.colorsInUse == [.green, .red, .blue])
    }

    @Test func currentRowIsTheLastMarkerAtOrBeforeThePlayhead() throws {
        let m = MarkerIndexModel(timeline: try timeline())
        #expect(m.currentRow(at: Time(3, 1)) == 1)
        #expect(m.currentRow(at: Time(5, 1)) == 2)
        var empty = Timeline(name: "E", frameDuration: fd, tracks: [])
        empty.markers = [Marker(time: Time(1, 1))]
        #expect(MarkerIndexModel(timeline: empty).currentRow(at: .zero) == nil)
    }

    @Test func frameCountDisplayAndTimecodeStart() throws {
        var t = try timeline()
        t.timecodeStart = Time(3600, 1)
        var m = MarkerIndexModel(timeline: t)
        #expect(m.text(for: Time(1, 1)) == "01:00:01:00")
        t.timecodeDisplay = .frames
        m.reload(t)
        #expect(m.text(for: Time(1, 1)) == String(3600 * 30 + 30))
    }
}
