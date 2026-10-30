import AppKit
import Foundation
import SQCore
import Testing
@testable import SQInspectorUI

/// Display cache and playhead layers of the key lanes, ruler and Graph Editor (proposal section 5): a playhead tick moves
/// layers and redraws no content; rebuilds happen only on revision / selection / viewport / size changes; timings against
/// the budgets (Release: lanes < 0.5 ms, graph < 1 ms, rebuild < 1 ms; Debug gets a x30 allowance). The cache-count
/// tests always run; `timingBudgets` is opt-in: `SQ_PERF=1 SQ_TEST_FILTER=KeyDisplayPerfTests scripts/test.sh SQEditorUI`.
@MainActor @Suite(.serialized) struct KeyDisplayPerfTests {
    static let keys = 20

    static func track(_ n: Int, _ f: (Int) -> Double) -> KeyframeTrack<Double> {
        KeyframeTrack(keys: (0..<n).map { Keyframe(time: Time(Int64($0), 2), value: f($0)) })
    }

    /// 10 s clip with 5 animated base properties and 11 animated effect parameters, 20 keys each.
    static func clip() -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        c.animation.opacity.track = track(keys) { Double($0 % 2) }
        c.animation.rotation.track = track(keys) { Double($0) * 7 }
        c.animation.volume.track = track(keys) { Double($0 % 3) }
        c.animation.position.track = KeyframeTrack(keys: (0..<keys).map { Keyframe(time: Time(Int64($0), 2), value: Vec2(Double($0) * 9, Double($0 % 4) * 20)) })
        c.animation.scale.track = KeyframeTrack(keys: (0..<keys).map { Keyframe(time: Time(Int64($0), 2), value: Vec2(1 + Double($0) / 10, 1 + Double($0) / 10)) })
        func fx(_ kind: String, _ keysOf: [String]) -> ClipEffect {
            var p: [String: AnimatedProperty<Double>] = [:]
            for k in keysOf { p[k] = AnimatedProperty(0, track: track(keys) { Double($0 % 5) * 3 }) }
            return ClipEffect(kind: kind, parameters: p)
        }
        c.effects = [fx(ClipEffect.roundedCornersKind, [ClipEffect.radiusKey]),
                     fx(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey]),
                     fx(ClipEffect.cropKind, [ClipEffect.cropLeftKey, ClipEffect.cropTopKey, ClipEffect.cropRightKey, ClipEffect.cropBottomKey]),
                     fx(ClipEffect.dropShadowKind, [ClipEffect.shadowOpacityKey, ClipEffect.shadowDirectionKey, ClipEffect.shadowDistanceKey,
                                                    ClipEffect.shadowSoftnessKey, ClipEffect.shadowSpreadKey])]
        return c
    }

    func rig(graph: Bool = false) -> (EffectControlsModel, EffectControlsView) {
        let m = EffectControlsModel()
        m.setClip(Self.clip())
        m.graphEditor = graph
        m.graphShowAll = true
        let v = EffectControlsView(model: m)
        v.persistLabelWidth = { _ in }
        v.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        v.layoutSubtreeIfNeeded()
        return (m, v)
    }

    func draw(_ v: NSView) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
    }

    /// Debug x30 plus the machine-load scale (SQTiming; SQ_STRICT_TIMING=1 disables the load scale).
    static var allowance: Double {
        #if DEBUG
        30 * SQTiming.scale
        #else
        1 * SQTiming.scale
        #endif
    }

    /// Best of 5 rounds (SQTiming): scheduling noise only adds time.
    func ms(_ runs: Int, _ body: () -> Void) -> Double {
        SQTiming.bestPerIterationMs(rounds: 5, iterations: runs, body)
    }

    @Test func playheadTickRedrawsNoContent() {
        let (m, v) = rig()
        draw(v)
        let builds = v.lanes.cacheBuilds, rulerDraws = v.ruler.invalidationCount
        for i in 0..<30 {
            m.playhead = Time(Int64(i + 1), 10)
            v.movePlayhead()
            v.refreshContent()
        }
        draw(v)
        #expect(v.lanes.cacheBuilds == builds)
        #expect(v.ruler.invalidationCount == rulerDraws)
    }

    @Test func cacheRebuildsOnSelectionAndViewportOnly() {
        let (m, v) = rig()
        draw(v)
        let builds = v.lanes.cacheBuilds
        v.lanes.needsDisplay = true; draw(v)
        #expect(v.lanes.cacheBuilds == builds)
        m.select([SummaryMember(property: EffectProperty.opacity.id, keyID: m.track(.opacity)!.keyIDs[0])], extend: false)
        v.refreshContent(); draw(v)
        #expect(v.lanes.cacheBuilds == builds + 1)
        m.zoom(by: 2, around: 1)
        v.refreshContent(); draw(v)
        #expect(v.lanes.cacheBuilds == builds + 2)
    }

    @Test func graphSamplesAdaptToZoomAndReusesArtwork() {
        #expect(EffectControlsModel.adaptiveSamples(segmentSeconds: 0.5, pointsPerSecond: 10) == 4)
        #expect(EffectControlsModel.adaptiveSamples(segmentSeconds: 10, pointsPerSecond: 100) == 64)
        #expect(EffectControlsModel.adaptiveSamples(segmentSeconds: 1, pointsPerSecond: 60) == 30)
        let (_, v) = rig(graph: true)
        draw(v.graphEditorView)
        let builds = v.graphEditorView.artworkBuilds
        v.graphEditorView.needsDisplay = true; draw(v.graphEditorView)
        #expect(v.graphEditorView.artworkBuilds == builds)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_PERF"] == "1"))
    func timingBudgets() {
        let (m, v) = rig(graph: true)
        draw(v)
        let lanes = v.lanes, graph = v.graphEditorView
        // Cached draw only (the cache is warm).
        let lrep = lanes.bitmapImageRepForCachingDisplay(in: lanes.bounds)!, grep = graph.bitmapImageRepForCachingDisplay(in: graph.bounds)!
        let lanesMs = ms(50) { lanes.cacheDisplay(in: lanes.bounds, to: lrep) }
        let graphMs = ms(50) { graph.cacheDisplay(in: graph.bounds, to: grep) }
        // Rebuild: invalidate by selection toggles.
        var on = false
        let id = m.track(.opacity)!.keyIDs[0]
        let rebuildMs = ms(50) {
            on.toggle()
            m.select(on ? [SummaryMember(property: EffectProperty.opacity.id, keyID: id)] : [], extend: false)
            lanes.cacheDisplay(in: lanes.bounds, to: lrep)
        }
        let tickMs = ms(200) { m.playhead = m.playhead + Time(1, 30); v.movePlayhead() }
        print("PERF key-display lanes \(lanesMs) ms, graph \(graphMs) ms, rebuild+draw \(rebuildMs) ms, tick \(tickMs) ms")
        #expect(lanesMs < 0.5 * Self.allowance)
        #expect(graphMs < 1 * Self.allowance)
        #expect(rebuildMs < 1 * Self.allowance + lanesMs)
        #expect(tickMs < 0.5 * Self.allowance)
    }
}
