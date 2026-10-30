import AppKit
import Testing
import SQCore
@testable import SQInspectorUI

/// Feedback 2026-10-10: the opened speed curve must have its peak at the top (higher speed is up, handles and drag agree
/// with the picture), and opening a row's curve must not move any keyframe diamond.
@MainActor @Suite struct KeyframeLaneOpenCurveTests {
    func segment(_ shape: EaseShape) -> EaseTrackSegment {
        EaseTrackSegment(from: UUID(), to: UUID(), start: Time(2, 1), end: Time(6, 1), shape: shape)
    }
    var geometry: SpeedGraphGeometry { SpeedGraphGeometry(lane: KeyframeLaneGeometry(width: 420, duration: Time(10, 1))) }

    func model() -> EffectControlsModel {
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.setClip(Clip(name: "c", media: UUID(), kind: .video,
                       source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1)))
        m.playhead = Time(5, 1)
        m.toggleStopwatch(.opacity)
        m.playhead = Time(7, 1)
        m.setValue(.opacity, to: 0.5)
        return m
    }

    // MARK: Point 1: higher speed is up

    @Test func higherSpeedIsHigherInTheFlippedView() {
        let g = geometry
        #expect(g.y(speed: 2) < g.y(speed: 1) && g.y(speed: 1) < g.y(speed: 0))
        #expect(abs(g.speed(atY: g.y(speed: 1.5)) - 1.5) < 1e-9)
        // The hill's peak (smallest y) sits above both keys.
        let s = segment(SpeedCurveChip.smooth.shape)
        let peakY = g.points(s).map(\.y).min()!
        #expect(peakY < g.key(s, side: .out).y - 10 && peakY < g.key(s, side: .in).y - 10)
    }

    /// The handle is hit where it is drawn: a steady key's handle sits on the 1.0x line (above the baseline), and the
    /// mirrored spot below the baseline grabs nothing.
    @Test func handleIsHitAtItsDrawnPositionNotMirrored() {
        let g = geometry
        let s = segment(.linear)
        let k = s.from
        let e = g.handleEnd(s, side: .out)
        #expect(e.y < g.baseline - 10)
        #expect(g.hitTest(e, rows: [[s]], selected: [[k]]) == .handle(row: 0, segment: 0, side: .out))
        let mirrored = CGPoint(x: e.x, y: 2 * g.baseline - e.y)
        if case .handle = g.hitTest(mirrored, rows: [[s]], selected: [[k]]) { Issue.record("handle hit at the mirrored spot") }
    }

    /// The drawn picture: render the view and read pixels. At the middle of a Smooth segment the first lit pixel from
    /// the top is the peak, far above the baseline, and the area under it is filled.
    @Test func drawnPeakIsAtTheTop() throws {
        let m = model()
        m.toggleOpen(.opacity)
        m.applySpeedChip(.smooth, for: .opacity)
        let g = InlineSpeedGraphView(property: .opacity, model: m)
        g.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        g.refresh()
        let rep = try #require(g.bitmapImageRepForCachingDisplay(in: g.bounds))
        g.cacheDisplay(in: g.bounds, to: rep)
        let seg = m.speedSegments(.opacity)[0]
        let geo = g.geometry
        let k = CGFloat(rep.pixelsWide) / g.bounds.width          // pixels per point
        let midX = Int(geo.x(seg, share: 0.5) * k)
        let bg = try #require(rep.colorAt(x: midX, y: 1)).usingColorSpace(.deviceRGB)!
        func differs(_ y: Int) -> Bool {
            guard let c = rep.colorAt(x: midX, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent) > 0.15
        }
        let firstPx = try #require((0..<Int(geo.baseline * k)).first(where: differs))
        let firstLit = CGFloat(firstPx) / k
        let peak = geo.points(seg).map(\.y).min()!
        #expect(abs(firstLit - peak) <= 3)
        #expect(firstLit < geo.baseline - 20)
        // Below the curve line the speed area is filled; above it is empty.
        #expect(!differs(max(Int((firstLit - 4) * k), 0)) && differs(Int((firstLit + 12) * k)))
    }

    // MARK: Point 2: opening a curve moves no diamond

    @Test func openingTheCurveKeepsEveryKeyWhereItWas() async throws {
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.setClip(Clip(name: "c", media: UUID(), kind: .video,
                       source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1)))
        let v = EffectControlsView(model: m)
        v.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        for p in [EffectProperty.scale, .opacity] {
            m.playhead = Time(5, 1); m.toggleStopwatch(p)
            m.playhead = Time(7, 1); m.setValue(p, to: p == .scale ? 1.2 : 0.5)
        }
        try await Task.sleep(for: .milliseconds(50))
        v.layoutSubtreeIfNeeded()
        let lanes = try #require(v.firstSubview(of: EffectKeyframeLanesView.self))
        func centers() -> [EffectProperty: [CGPoint]] {
            var out: [EffectProperty: [CGPoint]] = [:]
            for p in [EffectProperty.position, .scale, .opacity] {
                guard let row = lanes.rows.first(where: { $0.kind == .property(p) }) else { continue }
                out[p] = (m.track(p)?.glyphs ?? []).map { CGPoint(x: lanes.geometry.x(for: $0.time), y: row.y + row.height / 2) }
            }
            return out
        }
        func tops() -> [EffectProperty: CGFloat] {
            Dictionary(uniqueKeysWithValues: [EffectProperty.position, .scale, .opacity].compactMap { p in
                lanes.rows.first(where: { $0.kind == .property(p) }).map { (p, $0.y) }
            })
        }
        let before = centers(), topsBefore = tops(), widthBefore = lanes.bounds.width
        m.toggleOpen(.scale)
        try await Task.sleep(for: .milliseconds(50))
        v.layoutSubtreeIfNeeded()
        let after = centers(), topsAfter = tops()
        #expect(lanes.bounds.width == widthBefore)
        // Every key keeps its x. Rows up to and including the opened one keep their y too; a row below the curve moves
        // down by the curve's height as a whole (its keys keep their place inside the row).
        for p in [EffectProperty.scale, .opacity] {
            #expect(before[p]?.map(\.x) == after[p]?.map(\.x))
        }
        #expect(before[.position]! == after[.position]!)
        #expect(before[.scale]! == after[.scale]!)
        let shift = topsAfter[.opacity]! - topsBefore[.opacity]!
        #expect(shift == ControlsMetrics.graph)
        #expect(after[.opacity]!.map(\.y) == before[.opacity]!.map { $0.y + shift })
        let rowH = lanes.rows.first { $0.kind == .property(.scale) }!.height
        #expect(rowH == ControlsGrid.rowHeight)
        // The curve's own area sits under the key line, not over it.
        let graph = try #require(lanes.rows.first { $0.kind == .graph(.scale) })
        #expect(graph.y >= topsAfter[.scale]! + rowH)
    }

    // MARK: Decreasing values: the graph plots the magnitude of the speed

    /// Two keys 2 s apart whose value DECREASES (or moves backwards / left / up), eased Smooth: the hill must rise from
    /// the baseline (never hang below it), the eased keys sit on the baseline, the baseline is near the bottom, and the
    /// handles are hit where they are drawn.
    @Test func decreasingValuesDrawTheHillUpwardForEveryPropertyKind() {
        let cases: [(String, (EffectControlsModel) -> EffectProperty)] = [
            ("opacity", { m in m.setValue(.opacity, to: 0.1); return .opacity }),
            ("scale", { m in m.setValue(.scale, to: 0.4); return .scale }),
            ("rotation", { m in m.setValue(.rotation, to: -60); return .rotation }),
            ("position", { m in m.setVector(.position, to: Vec2(100, 50)); return .position }),
        ]
        for (name, edit) in cases {
            let m = EffectControlsModel()
            m.onEdit = { c, _, _ in m.setClip(c) }
            m.setClip(Clip(name: "c", media: UUID(), kind: .video,
                           source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1)))
            let p: EffectProperty = name == "opacity" ? .opacity : name == "scale" ? .scale : name == "rotation" ? .rotation : .position
            m.playhead = Time(5, 1); m.toggleStopwatch(p)
            m.playhead = Time(7, 1); _ = edit(m)
            m.toggleOpen(p)
            m.applySpeedChip(.smooth, for: p)
            let seg = m.speedSegments(p)
            #expect(seg.count == 1, "\(name)")
            guard let s = seg.first else { continue }
            #expect(s.scale > 0, "\(name): magnitude scale")
            let g = SpeedGraphGeometry(lane: m.laneGeometry(width: 420), height: 120, peak: SpeedGraphGeometry.peak(of: seg))
            let ys = g.points(s).map(\.y)
            #expect(ys.max()! <= g.baseline + 0.5, "\(name): nothing below the baseline")
            #expect(ys.min()! < g.baseline - 15, "\(name): hill rises")
            #expect(abs(g.key(s, side: .out).y - g.baseline) < 0.5 && abs(g.key(s, side: .in).y - g.baseline) < 0.5, "\(name)")
            #expect(g.baseline > 120 * 0.6, "\(name): baseline near the bottom")
            let e = g.handleEnd(s, side: .out)
            #expect(g.hitTest(e, rows: [seg], selected: [[s.from]]) == .handle(row: 0, segment: 0, side: .out), "\(name)")
        }
    }

    @Test func overshootAndEqualValuesKeepSpeedUpAndBaselineLow() {
        let lane = KeyframeLaneGeometry(width: 420, duration: Time(1, 1), inset: 8)
        // Higher speed is always a smaller y, with and without room for negative speeds.
        for low in [0.0, -0.5, -4.0] {
            var g = SpeedGraphGeometry(lane: lane, height: 120, peak: 1.5)
            g.low = low
            #expect(g.y(speed: 1) < g.y(speed: 0), "low \(low)")
            #expect(g.y(speed: 0) < g.y(speed: -0.2) || low == 0, "low \(low)")
            #expect(g.baseline > 20 && g.baseline <= 120 - SpeedGraphGeometry.baselineInset, "low \(low)")
        }
        // Peak of a huge or tiny hill still leaves the baseline at the bottom and the plot inside the view.
        for peak in [0.0, 0.01, 1, 50] {
            let g = SpeedGraphGeometry(lane: lane, height: 120, peak: peak)
            #expect(g.baseline == 120 - SpeedGraphGeometry.baselineInset, "peak \(peak)")
            #expect(g.unitHeight > 0 && g.y(speed: max(peak, 1)) >= 2 - 0.001, "peak \(peak)")
        }
    }
}
