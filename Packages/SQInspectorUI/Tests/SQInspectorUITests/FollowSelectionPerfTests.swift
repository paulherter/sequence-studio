import AppKit
import Foundation
import SQCore
import Testing
@testable import SQEditorSession
@testable import SQInspectorUI

/// One selection change as selection-follows-playhead (or a click on a clip) causes it, measured headless: the session
/// part (clip lookup, selection, every synchronous observer wired here: the Effect Controls model) and the Effect
/// Controls panel's reload for the new clip. `SQ_FOLLOW_OUT=<file>` writes the numbers. The row-reuse correctness tests
/// always run; `measureOneSelectionChange` is opt-in:
/// `SQ_PERF=1 SQ_TEST_FILTER=FollowSelectionPerfTests scripts/test.sh SQEditorUI`.
@MainActor @Suite(.serialized) struct FollowSelectionPerfTests {
    static let clips = 60

    /// A cut-up interview: 60 linked video/audio pairs on targeted V1/A1, plus 4 more tracks of 60 clips. With `rich`
    /// every V1 clip carries the same four keyframed effects (own IDs per clip).
    static func rig(rich: Bool, customize: (Int, inout Clip) -> Void = { _, _ in })
        throws -> (EditorSession, EffectControlsModel, EffectControlsView) {
        var v1 = Track(kind: .video, isTargeted: true), a1 = Track(kind: .audio, isTargeted: true)
        for i in 0..<clips {
            let link = UUID()
            var v = Clip(name: "v\(i)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                         start: Time(Int64(i * 2), 1), link: link)
            if rich {
                let r = KeyDisplayPerfTests.clip()
                v.animation = r.animation
                v.effects = r.effects.map { ClipEffect(kind: $0.kind, parameters: $0.parameters) }
            }
            customize(i, &v)
            try v1.overwrite(v)
            try a1.overwrite(Clip(name: "a\(i)", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(2, 1)),
                                  start: Time(Int64(i * 2), 1), link: link))
        }
        var tracks = [v1, a1]
        for k in 0..<4 {
            var tr = Track(kind: k < 2 ? .video : .audio)
            for i in 0..<clips {
                try tr.overwrite(Clip(name: "x", media: UUID(), kind: tr.kind, source: TimeRange(start: .zero, duration: Time(2, 1)),
                                      start: Time(Int64(i * 2), 1)))
            }
            tracks.append(tr)
        }
        let session = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: tracks)]),
                                    engine: StubProgramEngine(),
                                    autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("sq-followperf-\(UUID().uuidString)")))
        let model = EffectControlsModel()
        session.onChange = { [weak session, weak model] change in
            guard let session, let model else { return }
            model.sync(with: session, change: change)
        }
        session.seek(to: Time(1, 1))
        let view = EffectControlsView(model: model)
        view.persistLabelWidth = { _ in }
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        view.layoutSubtreeIfNeeded()
        return (session, model, view)
    }

    /// (session ms, panel ms) per selection change over 40 boundary crossings; the panel reloads as its observation
    /// does (`reloadForModelChange`), or from scratch with `fullRebuild` (the path before row reuse).
    static func crossings(rich: Bool, fullRebuild: Bool) throws -> (session: Double, panel: Double, rows: Int) {
        let (s, m, v) = try rig(rich: rich)
        var session = 0.0, panel = 0.0
        let n = 40
        for i in 1...n {
            session += ScrubDragPerfTests.ms { s.seek(to: Time(Int64(i * 2 + 1), 1)) }
            #expect(m.clip?.name == "v\(i)")
            panel += ScrubDragPerfTests.ms {
                if fullRebuild { v.rebuild(reusing: false) } else { v.reloadForModelChange() }
                v.layoutSubtreeIfNeeded()
            }
        }
        return (session / Double(n), panel / Double(n), v.shownRows.count)
    }

    /// A scrub over all 60 clips evaluates selection-follows-playhead once, at the end (not per mouse event).
    @Test func scrubEvaluatesFollowOnceAtTheEnd() throws {
        let (s, _, _) = try Self.rig(rich: false)
        let evaluations = s.followEvaluations
        s.beginScrub()
        for i in 0..<60 { s.scrub(to: Time(Int64(i), 5)) }
        #expect(s.followEvaluations == evaluations)
        s.endScrub()
        #expect(s.followEvaluations == evaluations + 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_PERF"] == "1"))
    func measureOneSelectionChange() throws {
        _ = try Self.crossings(rich: false, fullRebuild: true)       // warm-up
        var lines: [String] = []
        for rich in [false, true] {
            let full = try Self.crossings(rich: rich, fullRebuild: true)
            let reuse = try Self.crossings(rich: rich, fullRebuild: false)
            lines.append(String(format: "%@ clip (%d rows): session+model %.3f ms; panel reload full %.3f ms, reusing rows %.3f ms",
                                rich ? "4-effect" : "plain", full.rows, full.session, full.panel, reuse.panel))
            #expect(reuse.rows == full.rows)
            #expect(full.session < 5 * KeyDisplayPerfTests.allowance)
        }
        // A scrub drag over all 60 clips: what the playhead pays per mouse event.
        let (s, _, _) = try Self.rig(rich: false)
        let events = 600
        let evaluations = s.followEvaluations
        s.beginScrub()
        let drag = ScrubDragPerfTests.ms { for i in 0..<events { s.scrub(to: Time(Int64(i), 5)) } } / Double(events)
        #expect(s.followEvaluations == evaluations)
        s.endScrub()
        #expect(s.followEvaluations == evaluations + 1)
        lines.append(String(format: "scrub over 60 clips: %.4f ms per mouse event, 1 follow evaluation for %d events", drag, events))
        if let out = ProcessInfo.processInfo.environment["SQ_FOLLOW_OUT"] {
            try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    /// A clip with the same sections keeps the row views that are not bound to an id of the clip.
    @Test func sameShapeKeepsTheRowViews() throws {
        let (s, m, v) = try Self.rig(rich: false)
        v.reloadForModelChange()
        let before = v.shownRowViews
        #expect(!before.isEmpty)
        s.seek(to: Time(11, 1))
        #expect(m.clip?.name == "v5")
        v.reloadForModelChange()
        let after = v.shownRowViews
        #expect(after.count == before.count)
        // Every row but the five Crop rows (bound to the clip's own Crop id) is the same view.
        #expect(zip(before, after).filter { $0 === $1 }.count == before.count - 5)
        #expect(after.allSatisfy { $0.superview != nil })
        // Nothing selected: the rows go, the empty state shows.
        s.select(clips: [])
        v.reloadForModelChange()
        #expect(v.shownRowViews.isEmpty)
        #expect(before.allSatisfy { $0.superview == nil })
    }

    /// Reused rows show the new clip's values, exactly like rows built from scratch.
    @Test func reusedRowsShowTheNewClip() throws {
        let (s, m, v) = try Self.rig(rich: false)
        v.reloadForModelChange()
        s.seek(to: Time(15, 1))
        var c = try #require(s.displayedSelectedClip)
        let id = c.id
        c.animation.rotation.value = 33
        c.animation.opacity.value = 0.25
        s.replaceDisplayedClip(c, name: "Edit", continuesGesture: false)
        s.seek(to: Time(5, 1))
        v.reloadForModelChange()
        let rows = v.shownRowViews
        s.seek(to: Time(15, 1))
        #expect(m.clip?.id == id)
        v.reloadForModelChange()
        v.layoutSubtreeIfNeeded()
        #expect(zip(rows, v.shownRowViews).contains { $0 === $1 })
        let reused = Self.fieldTexts(v)
        v.rebuild(reusing: false)
        v.layoutSubtreeIfNeeded()
        #expect(Self.fieldTexts(v) == reused)
        #expect(reused.contains { $0.contains("33") })
    }

    /// Key state, key navigation, switches, values: a reused row must be indistinguishable from a fresh one. Clip 3 is
    /// keyframed, clips 5 and 6 are the halves of a cut clip (same effect ids, other values).
    @Test func reusedRowsMatchFreshRowsInEveryState() throws {
        let keyed = KeyDisplayPerfTests.clip()
        let (s, m, v) = try Self.rig(rich: false) { i, c in
            if i == 3 { c.animation = keyed.animation }
            if i == 5 || i == 6 { c.effects = keyed.effects }
            if i == 6 { c.animation.rotation.value = 12; c.effects[1].parameters[ClipEffect.blurrinessKey]?.value = 40 }
        }
        for i in [3, 1, 3, 5, 6, 5, 0] {
            s.seek(to: Time(Int64(i * 2 + 1), 1))
            #expect(m.clip?.name == "v\(i)")
            let before = v.shownRowViews
            v.reloadForModelChange()
            v.layoutSubtreeIfNeeded()
            let kept = v.shownRowViews.filter { r in before.contains { $0 === r } }
            #expect(!kept.isEmpty)
            // No row bound to an effect, mask or parameter id is kept, also not between the halves of a cut clip.
            for (row, view) in zip(v.shownRows, v.shownRowViews) where kept.contains(where: { $0 === view }) {
                switch row.kind {
                case .section(let x): #expect(EffectSection.builtIns.contains(x))
                case .property(let p): #expect(EffectProperty.builtIns.contains(p))
                case .placeholder, .speedControl, .blendMode, .group: break
                default: Issue.record("kept a row bound to an id: \(row.kind)")
                }
            }
            let reused = Self.state(v)
            v.rebuild(reusing: false)
            v.layoutSubtreeIfNeeded()
            #expect(Self.state(v) == reused, "clip \(i)")
        }
    }

    /// A row with a field in editing is not handed to the next clip (its text belongs to the old one).
    @Test func theRowBeingEditedIsNotReused() throws {
        let (s, _, v) = try Self.rig(rich: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = v
        v.reloadForModelChange()
        let before = v.shownRowViews
        func field(_ x: NSView) -> ScrubField? { (x as? ScrubField) ?? x.subviews.lazy.compactMap(field).first }
        let (index, edited) = try #require(before.enumerated().lazy.compactMap { i, r in field(r).map { (i, $0) } }.first)
        #expect(window.makeFirstResponder(edited))
        s.seek(to: Time(11, 1))
        v.reloadForModelChange()
        let after = v.shownRowViews
        #expect(after[index] !== before[index])
        #expect(zip(before, after).contains { $0 === $1 })
    }

    /// Everything a row shows, as text: class, hidden, enabled, strings, values and the plain stored state of each view.
    static func state(_ v: EffectControlsView) -> [String] {
        func walk(_ x: NSView) -> [String] {
            var line = "\(type(of: x)) hidden=\(x.isHidden) frame=\(x.frame)"
            if let c = x as? NSControl { line += " enabled=\(c.isEnabled)" }
            if let t = x as? NSTextField { line += " text=\(t.stringValue)" }
            if let b = x as? NSButton { line += " state=\(b.state.rawValue)" }
            for child in Mirror(reflecting: x).children {
                switch child.value {
                case let b as Bool: line += " \(child.label ?? "")=\(b)"
                case let n as Double: line += " \(child.label ?? "")=\(n)"
                case let n as Int: line += " \(child.label ?? "")=\(n)"
                case let t as String: line += " \(child.label ?? "")=\(t)"
                default: break
                }
            }
            return [line] + x.subviews.flatMap(walk)
        }
        return v.shownRowViews.flatMap(walk)
    }

    static func fieldTexts(_ v: EffectControlsView) -> [String] {
        func walk(_ x: NSView) -> [String] {
            ((x as? NSTextField).map { [$0.stringValue] } ?? []) + ((x as? ScrubField).map { ["\($0.value)"] } ?? [])
                + x.subviews.flatMap(walk)
        }
        return v.shownRowViews.flatMap(walk)
    }
}
