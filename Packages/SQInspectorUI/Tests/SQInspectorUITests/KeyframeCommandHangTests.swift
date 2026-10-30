import AppKit
import Foundation
import SQCore
import Testing
@testable import SQInspectorUI

/// Fails (crashes with a message) instead of blocking the run when `body` does not return within `seconds`.
/// The keyframe commands run on the main actor; a hang there used to beachball the whole app.
@MainActor func withHangWatchdog<T>(_ label: String, seconds: Double = 10, _ body: () throws -> T) rethrows -> T {
    let done = ManagedAtomicFlag()
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
        if !done.isSet { fatalError("HANG: \(label) did not return within \(seconds) s") }
    }
    defer { done.set() }
    return try body()
}

final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// F9 family (Smooth, Smooth In, Smooth Out), Hold, interpolation choices, copy / paste, delete and moves on keyframe
/// selections in Effect Controls: none may hang, whatever the selection (empty, one, many, keys at one time, degenerate tracks).
@MainActor @Suite struct KeyframeCommandHangTests {
    func t(_ s: Int64) -> Time { Time(s, 1) }

    /// Video clip at 5 s, 10 s long; Opacity and Position keyed at `times`, the edits fed back like the session does.
    func rig(times: [Time] = [Time(0, 1), Time(4, 1)], values: [Double] = [0, 1]) -> EffectControlsModel {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        clip.animation.opacity.track = KeyframeTrack(keys: zip(times, values).map { Keyframe(time: $0, value: $1) })
        clip.animation.position.track = KeyframeTrack(keys: zip(times, values).map { Keyframe(time: $0, value: Vec2($1 * 100, $1 * 50)) })
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.setClip(clip)
        m.playhead = Time(5, 1)
        return m
    }

    func members(_ m: EffectControlsModel, _ p: EffectProperty) -> Set<SummaryMember> {
        let ids: [UUID] = switch p {
        case .opacity: m.clip!.animation.opacity.track.keys.map(\.id)
        case .position: m.clip!.animation.position.track.keys.map(\.id)
        default: []
        }
        return Set(ids.map { SummaryMember(property: p.id, keyID: $0) })
    }

    /// The real panel, laid out and drawn into a bitmap (the redraw after an edit is part of the command's path).
    func render(_ m: EffectControlsModel) -> EffectControlsView {
        let v = EffectControlsView(model: m)
        v.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        v.layoutSubtreeIfNeeded()
        draw(v)
        return v
    }
    func draw(_ v: NSView) {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
    }

    typealias Command = (String, (EffectControlsModel) -> Void)
    var commands: [Command] {
        [("Smooth", { $0.applyEasing(.easeInOut) }),
         ("Smooth In", { $0.applyEasing(.easeIn, side: .in) }),
         ("Smooth Out", { $0.applyEasing(.easeOut, side: .out) }),
         ("Hold", { $0.toggleHold() }),
         ("Hold again", { $0.toggleHold() })]
            + KeyInterpolationChoice.allCases.map { c in ("Interpolation \(c)", { $0.applyInterpolation(c) }) }
            + KeyInterpolationChoice.allCases.map { c in ("Graph ease \(c)", { $0.applyGraphEase(c) }) }
            + [("Copy+Paste", { m in _ = m.copyKeys(); _ = m.pasteKeys() }),
               ("Move", { _ = $0.moveSelection(by: Time(1, 1)) }),
               ("Move back", { _ = $0.moveSelection(by: Time(-1, 1)) }),
               ("Delete", { $0.deleteSelection() })]
    }

    func runAll(_ m: EffectControlsModel, selection: Set<SummaryMember>, label: String, view: EffectControlsView? = nil) {
        for (name, cmd) in commands {
            let live = selection.filter { s in m.clip.map { EffectControlsModel.tracks(of: $0)[s.property]?.keyIDs.contains(s.keyID) ?? false } ?? false }
            m.clearSelection()
            if !live.isEmpty { m.select(Array(live), extend: false) }
            withHangWatchdog("\(label): \(name)") {
                cmd(m)
                if let view { draw(view) }
            }
        }
    }

    @Test func smoothOnTwoSelectedKeysReturnsAndEases() {
        let m = rig()
        let v = render(m)
        m.selectGraphProperty(.opacity, extend: false)
        m.select(Array(members(m, .opacity)), extend: false)
        withHangWatchdog("F9 Smooth, two keys") {
            m.applyEasing(.easeInOut)
            draw(v)
        }
        #expect(m.clip!.animation.opacity.track.keys.allSatisfy { $0.interpolation == .bezier })
    }

    @Test func everyCommandOnEverySelectionShapeReturns() {
        let shapes: [(String, [Time], [Double])] = [
            ("two keys", [t(0), t(4)], [0, 1]),
            ("equal values", [t(0), t(4)], [0.5, 0.5]),
            ("one frame apart", [Time(0, 1), Time(1, 30)], [0, 1]),
            ("three keys", [t(0), t(2), t(4)], [0, 1, 0]),
            ("one key", [t(2)], [1]),
            ("at clip end", [t(9), t(10)], [0, 1]),
        ]
        for (label, times, values) in shapes {
            for scope in ["none", "one", "opacity", "both"] {
                let m = rig(times: times, values: values)
                let v = render(m)
                m.selectGraphProperty(.opacity, extend: false)
                let sel: Set<SummaryMember> = switch scope {
                case "none": []
                case "one": Set(members(m, .opacity).prefix(1))
                case "opacity": members(m, .opacity)
                default: members(m, .opacity).union(members(m, .position))
                }
                runAll(m, selection: sel, label: "\(label) / \(scope)", view: v)
            }
        }
    }

    /// Keys of several properties at one time, picked as one summary key (collapsed section row): every command returns.
    @Test func summaryKeysAtIdenticalTimeDoNotHang() {
        let m = rig()
        let v = render(m)
        for g in m.summaryKeys(.motion) + m.summaryKeys(.opacity) {
            m.clearSelection()
            m.selectSummary(g, extend: true)
            runAll(m, selection: m.selection, label: "summary at \(g.time)", view: v)
        }
    }

    /// The app's wiring: edits go through the session, every session change syncs the panel back (Normal and Fast Cut).
    @Test func sessionRoundTripDoesNotHang() throws {
        for magnetic in [false, true] {
            var track = Track(kind: .video)
            var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: t(10)), start: .zero)
            clip.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: t(1), value: 0), Keyframe(time: t(4), value: 1)])
            clip.animation.position.track = KeyframeTrack(keys: [Keyframe(time: t(1), value: Vec2(0, 0)), Keyframe(time: t(4), value: Vec2(9, 9))])
            try track.overwrite(clip)
            var tl = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [track])
            if magnetic { tl.editMode = .magnetic }
            let session = EditorSession(project: Project(name: "P", timelines: [tl]))
            let m = EffectControlsModel()
            session.onChange = { [unowned session] c in m.sync(with: session, change: c) }
            m.onEdit = { c, name, co in session.replaceDisplayedClip(c, name: name, continuesGesture: co) }
            session.select(clips: [clip.id])
            session.seek(to: t(2))
            let v = render(m)
            #expect(m.clip != nil)
            runAll(m, selection: members(m, .opacity).union(members(m, .position)), label: "session magnetic=\(magnetic)", view: v)
            withHangWatchdog("undo all") { while session.canUndo { _ = session.undo() }; draw(v) }
        }
    }

    /// NaN / infinite values in keys must not stall drawing or easing.
    @Test func nonFiniteValuesDoNotHang() {
        for bad in [Double.nan, .infinity, -.infinity, 1e300] {
            let m = rig(values: [0, bad])
            let v = render(m)
            m.selectGraphProperty(.opacity, extend: false)
            runAll(m, selection: members(m, .opacity), label: "value \(bad)", view: v)
        }
    }
}
