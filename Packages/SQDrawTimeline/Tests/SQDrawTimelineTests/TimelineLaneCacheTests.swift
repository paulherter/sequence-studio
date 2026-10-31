import Foundation
import SQCore
import SQDrawKit
import SQMedia
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

/// The clip layer is replayed from a cache while nothing it draws has changed, and is exactly what a fresh draw gives.
@MainActor @Suite struct TimelineLaneCacheTests {
    static let fd = Time(1, 30)

    static func timeline(clips: Int = 40, length: Int64 = 60) -> Timeline {
        func track(_ kind: TrackKind) -> Track {
            Track(kind: kind, clips: (0..<clips).map { i in
                Clip(name: "c\(i)", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: fd * length), start: fd * (Int64(i) * length))
            })
        }
        return Timeline(name: "t", frameDuration: fd, tracks: [track(.video), track(.audio)])
    }

    static func panel(_ t: Timeline, selection: Set<Clip.ID> = [], zoom: Double = 20) -> TimelinePanel {
        var p = TimelinePanel()
        p.layout(DrawRect(x: 0, y: 0, w: 1200, h: 600), scale: 1)
        p.sync(timeline: t, selection: selection, playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        p.setZoom(pointsPerSecond: zoom)
        return p
    }

    static func draw(_ p: TimelinePanel, atlas: GlyphAtlas? = nil) -> DrawList {
        var list = DrawList(width: 1200, height: 600)
        p.draw(into: &list, atlas: atlas)
        return list
    }

    @Test func aMovingPlayheadReplaysTheClipLayer() {
        var p = Self.panel(Self.timeline())
        _ = Self.draw(p)
        for i in 1...5 {
            p.sync(timeline: p.timeline, selection: [], playhead: Self.fd * Int64(i * 10), selectedTransition: nil, labels: LabelResolver())
            _ = Self.draw(p)
        }
        #expect(p.laneCache.misses == 1)
        #expect(p.laneCache.hits == 5)
    }

    @Test func aReplayedFrameEqualsAFreshDraw() throws {
        let t = Self.timeline()
        let atlas = try #require(GlyphAtlas())
        var cached = Self.panel(t, selection: [t.tracks[0].clips[2].id])
        _ = Self.draw(cached, atlas: atlas)
        cached.sync(timeline: t, selection: [t.tracks[0].clips[2].id], playhead: Self.fd * 90, selectedTransition: nil, labels: LabelResolver())
        let replay = Self.draw(cached, atlas: atlas)
        #expect(cached.laneCache.hits == 1)
        cached.laneCache.invalidate()
        let fresh = Self.draw(cached, atlas: atlas)
        #expect(cached.laneCache.hits == 1)           // the second draw was a miss
        #expect(replay.quads == fresh.quads)
    }

    @Test func everythingTheLayerDrawsInvalidatesIt() {
        let t = Self.timeline()
        var p = Self.panel(t)
        _ = Self.draw(p)
        var misses = p.laneCache.misses
        func expectRedraw(_ what: String, _ change: (inout TimelinePanel) -> Void) {
            change(&p)
            _ = Self.draw(p)
            #expect(p.laneCache.misses == misses + 1, "\(what)")
            misses = p.laneCache.misses
        }
        expectRedraw("selection") { $0.sync(timeline: t, selection: [t.tracks[0].clips[1].id], playhead: .zero, selectedTransition: nil, labels: LabelResolver()) }
        expectRedraw("zoom") { $0.setZoom(pointsPerSecond: 33) }
        expectRedraw("scroll") { $0.geometry.scrollX = 40 }
        expectRedraw("layout") { $0.layout(DrawRect(x: 0, y: 0, w: 1100, h: 600), scale: 1) }
        expectRedraw("model") {
            let edited = Self.timeline(clips: 41)
            $0.sync(timeline: edited, selection: [t.tracks[0].clips[1].id], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        }
        expectRedraw("thumbnail mode") { $0.thumbnailMode = $0.thumbnailMode == .head ? .continuous : .head }
        expectRedraw("grade outline") { $0.gradeOutline = [t.tracks[0].clips[0].id] }
        expectRedraw("analysis progress") { $0.analysisProgress = [t.tracks[0].clips[0].id: 0.4] }
    }

    @Test func aMediaSourceWithoutAStampIsNeverCached() {
        final class Plain: TimelineMediaSource {
            func waveform(media: UUID) -> WaveformData? { nil }
        }
        let media = Plain()
        var p = Self.panel(Self.timeline())
        p.media = media
        _ = Self.draw(p); _ = Self.draw(p)
        #expect(p.laneCache.hits == 0 && p.laneCache.misses == 0)
    }

    @Test func aMediaStampChangeRedraws() {
        final class Stamped: TimelineMediaSource {
            var revision = 0
            func waveform(media: UUID) -> WaveformData? { nil }
            var drawRevision: Int? { revision }
        }
        let media = Stamped()
        var p = Self.panel(Self.timeline())
        p.media = media
        _ = Self.draw(p); _ = Self.draw(p)
        #expect(p.laneCache.hits == 1 && p.laneCache.misses == 1)
        media.revision += 1
        _ = Self.draw(p)
        #expect(p.laneCache.misses == 2)
    }

    @Test func touchingSliversOfOneColorBecomeOneFill() {
        // 2000 one-frame clips at 1 pt/s are 0.03 pt wide: a zoomed-out hour.
        let t = Self.timeline(clips: 2000, length: 1)
        let p = Self.panel(t, zoom: 1)
        let rows = p.rows
        let content = CGRect(x: 156, y: 24, width: 1044, height: 576)
        var cv = Canvas(width: 1200, height: 600, atlas: nil, scale: 1)
        p.drawLanes(&cv, rows: rows, clip: content)
        let list = cv.list
        #expect(list.quads.count < 20, "a sliver per clip would be 4000 quads, got \(list.quads.count)")
        let video = rows.first { $0.kind == .video }!
        let inRow = list.quads.filter { $0.y >= Float(video.y) && $0.y + $0.h <= Float(video.maxY) && $0.h < Float(video.height) }
        let width = inRow.map(\.w).max() ?? 0
        #expect(width > 30, "the run spans the clips' whole width")
    }

    @Test func aSelectedSliverBreaksTheRunInYellow() {
        let t = Self.timeline(clips: 2000, length: 1)
        let p = Self.panel(t, selection: [t.tracks[0].clips[1000].id], zoom: 1)
        let list = Self.draw(p)
        let yellow = p.theme.yellow
        #expect(list.quads.contains { $0.color == yellow })
    }

    @Test func transitionLayersAreFoundWithoutScanningEveryClip() {
        let t = Self.timeline()
        let p = Self.panel(t)
        #expect(p.transitionLayerTracks.isEmpty)
    }
}

@MainActor @Suite struct TimelineVeilOrderTests {
    final class Lanes: TimelineKeyLaneSource {
        func keyLane(clip: Clip, clipRect: CGRect, visible: CGRect, selected: Bool, geometry: TimelineGeometry) -> TimelineKeyLane? {
            guard selected else { return nil }
            let lane = CGRect(x: clipRect.minX, y: clipRect.maxY - 11, width: clipRect.width, height: 10)
            return TimelineKeyLane(lane: lane, glyphs: [.init(center: CGPoint(x: lane.midX, y: lane.midY), selected: false)], glyphSize: 7)
        }
        func keyLaneHit(clip: Clip, clipRect: CGRect, at p: CGPoint, geometry: TimelineGeometry) -> Time? { nil }
    }

    @Test func aDisabledClipsVeilCoversItsKeyLane() {
        let fd = TimelineLaneCacheTests.fd
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 60), start: .zero)
        c.isEnabled = false
        let id = c.id
        let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])
        let lanes = Lanes()
        var p = TimelineLaneCacheTests.panel(t, selection: [id])
        p.keyLanes = lanes
        let q = TimelineLaneCacheTests.draw(p).quads
        let strip = q.lastIndex { abs($0.a - 0.55 * p.theme.lane.a) < 0.001 && $0.h == 10 }
        let veil = q.lastIndex { abs($0.a - 0.68) < 0.001 && $0.radius > 0 }
        #expect(strip != nil && veil != nil)
        if let strip, let veil { #expect(veil > strip) }
    }
}

