import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI

/// The ruler row, translated from `RulerView.draw`: In/Out band, cache strip, ticks with timecode labels, markers, the
/// "Tracks" corner over the header column, the bottom hairline and the playhead head.
extension TimelinePanel {
    func drawRuler(_ cv: inout Canvas) {
        let h = TimelineGeometry.rulerHeight, origin = TimelineGeometry.contentOriginX
        let content = CGRect(x: origin, y: 0, width: max(size.width - origin, 0), height: h)
        cv.fill(CGRect(x: 0, y: 0, width: size.width, height: h), theme.timeline)
        if !content.isEmpty {
            cv.saveGState()
            cv.clip(to: content)
            drawRulerInOut(&cv, clip: content)
            drawCacheStrip(&cv, clip: content)
            drawTicks(&cv, clip: content)
            drawMarkers(&cv, clip: content)
            cv.restoreGState()
        }
        drawTracksCorner(&cv)
        cv.fill(CGRect(x: 0, y: h - 1, width: size.width, height: 1), theme.trackRowLine)
        drawPlayheadHead(&cv)
    }

    func drawTracksCorner(_ cv: inout Canvas) {
        let r = CGRect(x: TimelineGeometry.toolColumnWidth, y: 0, width: TimelineGeometry.headerWidth, height: TimelineGeometry.rulerHeight)
        cv.fill(r, theme.panel)
        cv.fill(CGRect(x: r.maxX - 1, y: 0, width: 1, height: r.height), theme.separator)
        let fs = DrawTheme.TypeSize.body.cg
        let s = cv.size(of: "Tracks", fontSize: fs)
        cv.draw("Tracks", at: CGPoint(x: r.minX + DrawTheme.Spacing.sm.cg, y: ((r.height - s.height) / 2).rounded()), fontSize: fs, theme.label3)
    }

    func drawRulerInOut(_ cv: inout Canvas, clip: CGRect) {
        guard let io = timeline.inOut, !io.isEmpty else { return }
        let x0 = geometry.x(for: io.start), x1 = geometry.x(for: io.end)
        guard x1 > clip.minX, x0 < clip.maxX else { return }
        let h = TimelineGeometry.rulerHeight
        cv.fill(roundedRect: CGRect(x: x0, y: h - 4, width: x1 - x0, height: 4), radius: DrawTheme.Radius.small.cg / 2, skin.accentTint)
        if x0 >= clip.minX - 2 { cv.fill(CGRect(x: x0, y: h - 8, width: 2, height: 8), theme.accent) }
        if x1 <= clip.maxX + 2 { cv.fill(CGRect(x: x1 - 2, y: h - 8, width: 2, height: 8), theme.accent) }
    }

    /// `RulerView.cacheBars`, copied (the Mac copy lives in the AppKit ruler).
    static func cacheBars(_ ranges: [TimeRange], geometry: TimelineGeometry) -> [ClosedRange<CGFloat>] {
        var bars: [ClosedRange<CGFloat>] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) {
            let a = geometry.x(for: r.start), b = geometry.x(for: r.end)
            guard b >= a else { continue }
            if let last = bars.last, a - last.upperBound < 6 {
                bars[bars.count - 1] = last.lowerBound...max(last.upperBound, b)
            } else { bars.append(a...b) }
        }
        return bars.filter { $0.upperBound - $0.lowerBound >= 3 }
    }

    func drawCacheStrip(_ cv: inout Canvas, clip: CGRect) {
        for bar in Self.cacheBars(cachedRanges, geometry: geometry) {
            let x0 = max(bar.lowerBound, clip.minX), x1 = min(bar.upperBound, clip.maxX)
            if x1 > x0 { cv.fill(CGRect(x: x0, y: 0, width: x1 - x0, height: 2), skin.cacheStrip) }
        }
    }

    /// `RulerView.ticks`: frame numbers of the visible ticks and whether each is a labeled major tick.
    func ticks(visibleMinX: CGFloat, visibleMaxX: CGFloat, nominalFPS: Int) -> [(frame: Int64, major: Bool)] {
        let fdSec = Double(geometry.frameDuration.value) / Double(geometry.frameDuration.timescale)
        let ppf = geometry.pointsPerSecond * fdSec
        guard ppf > 0 else { return [] }
        let scale = RulerScale.scale(pointsPerFrame: ppf, nominalFPS: nominalFPS)
        let firstFrame = Int64(((Double(visibleMinX - TimelineGeometry.contentOriginX + geometry.scrollX)) / ppf).rounded(.down))
        let lastFrame = Int64(((Double(visibleMaxX - TimelineGeometry.contentOriginX + geometry.scrollX)) / ppf).rounded(.up))
        var f = max(0, (firstFrame / scale.minorFrames) * scale.minorFrames)
        var out: [(Int64, Bool)] = []
        while f <= lastFrame {
            out.append((f, f % scale.majorFrames == 0))
            f += scale.minorFrames
        }
        return out
    }

    func drawTicks(_ cv: inout Canvas, clip: CGRect) {
        let timecode = TimecodeFormat(frameDuration: geometry.frameDuration)
        let h = TimelineGeometry.rulerHeight, fd = geometry.frameDuration
        let fs = DrawTheme.TypeSize.caption.cg
        let lineHeight = cv.size(of: "0", fontSize: fs).height
        for (frame, major) in ticks(visibleMinX: clip.minX - 80, visibleMaxX: clip.maxX, nominalFPS: timecode.nominalFPS) {
            let x = geometry.x(for: fd * frame).rounded()
            if major {
                cv.fill(CGRect(x: x, y: h - 8, width: 1, height: 8), theme.rulerLine)
                cv.draw(timecode.string(forFrame: frame), at: CGPoint(x: x + 3.5, y: ((h - lineHeight) / 2).rounded()), fontSize: fs, theme.label3)
            } else {
                cv.fill(CGRect(x: x, y: h - 4, width: 1, height: 4), theme.rulerMinor)
            }
        }
    }

    func drawMarkers(_ cv: inout Canvas, clip: CGRect) {
        let h = TimelineGeometry.rulerHeight
        for m in timeline.markers {
            let x = geometry.x(for: m.time).rounded()
            guard x <= clip.maxX + 8, max(x, geometry.x(for: m.time + m.duration)) >= clip.minX - 8 else { continue }
            let c = skin.marker(m.color)
            if let bar = MarkerRange.barRect(m, geometry: geometry, rulerHeight: h), bar.maxX >= clip.minX {
                cv.fill(bar, c.alpha(0.55))
                cv.fill(CGRect(x: bar.maxX - 1, y: bar.minY - 3, width: 2, height: bar.height + 3), c)
            }
            cv.fill(ellipseIn: CGRect(x: x - 3.5, y: h - 4 - 7, width: 7, height: 7), c)
        }
    }

    func drawPlayheadHead(_ cv: inout Canvas) {
        let x = geometry.x(for: playhead)
        guard x >= TimelineGeometry.contentOriginX - 7, x <= size.width + 7 else { return }
        cv.saveGState()
        cv.clip(to: CGRect(x: TimelineGeometry.contentOriginX, y: 0, width: max(size.width - TimelineGeometry.contentOriginX, 0),
                           height: TimelineGeometry.rulerHeight))
        let c = x.rounded()
        cv.fill(TimelineSkin.lineFrame(centerX: c, height: TimelineGeometry.rulerHeight), theme.playhead)
        skin.drawHead(&cv, centerX: c)
        cv.restoreGState()
    }
}
