import AppKit
import Foundation
import SQCore
import Testing
@testable import SQEditorUI

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

private func clip(_ name: String, start: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: name, media: UUID(), kind: kind, source: TimeRange(start: f(30), duration: f(60)), start: f(start), mediaDuration: f(300))
}

/// V1: A | B | C with a dissolve at A|B and a dip at the tail of C; A1: a | b with a crossfade.
@MainActor private func makeView(selectFirst: Bool = false) throws -> (TimelineView, Timeline, [Transition.ID]) {
    var v = Track(kind: .video, name: "V1"), a = Track(kind: .audio, name: "A1")
    let c1 = clip("Interview", start: 0), c2 = clip("B-roll", start: 60), c3 = clip("Outro", start: 120)
    for c in [c1, c2, c3] { try v.overwrite(c) }
    let a1 = clip("a", start: 0, kind: .audio), a2 = clip("b", start: 60, kind: .audio)
    try a.overwrite(a1); try a.overwrite(a2)
    var t = Timeline(name: "T", frameDuration: fd, tracks: [v, a])
    let i1 = try t.addTransition(kind: .crossDissolve, track: v.id, outgoing: c1.id, incoming: c2.id, duration: f(24))
    let i2 = try t.addTransition(kind: .dipToBlack, track: v.id, outgoing: c3.id, incoming: nil, duration: f(20))
    let i3 = try t.addTransition(kind: .constantPower, track: a.id, outgoing: a1.id, incoming: a2.id, duration: f(30))
    let view = TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: 900, height: 160))
    view.setZoom(pointsPerSecond: 150)
    if selectFirst { view.setSelectedTransition(i1) }
    return (view, t, [i1, i2, i3])
}

@MainActor private func render2x(_ v: TimelineView) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width) * 2, pixelsHigh: Int(v.bounds.height) * 2,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let base = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = base.cgContext
    cg.scaleBy(x: 2, y: -2); cg.translateBy(x: 0, y: -v.bounds.height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    v.draw(v.bounds)
    for sub in v.subviews where !sub.isHidden {
        cg.saveGState(); cg.translateBy(x: sub.frame.minX, y: sub.frame.minY); sub.draw(sub.bounds); cg.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

@MainActor private func event(_ type: NSEvent.EventType, at p: CGPoint, in v: TimelineView, clicks: Int = 1,
                              flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: v.convert(p, to: nil), modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                       eventNumber: 0, clickCount: clicks, pressure: 1)!
}

@MainActor @Suite struct TransitionViewTests {
    @Test func transitionsAreDrawnOverTheCut() throws {
        let (v, t, ids) = try makeView(selectFirst: true)
        let rep = render2x(v)
        if let dir = ProcessInfo.processInfo.environment["SQ_TRANSITION_SNAPSHOT"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("timeline-transitions.png"))
        }
        // The selected box has an accent-blue outline at its left edge; compare against the same view without transitions.
        let plain = TimelineView(timeline: { var p = t; for i in p.tracks.indices { p.tracks[i].transitions = [] }; return p }(),
                                 frame: v.frame)
        plain.setZoom(pointsPerSecond: 150)
        let base = render2x(plain)
        let row = v.geometry.rows(for: t)[0]
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first { $0.id == ids[0] })
        let box = TransitionLayout.rect(r, row: row, geometry: v.geometry)
        func px(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor { rep.colorAt(x: Int(x * 2), y: Int(y * 2))! }
        let a = px(rep, box.midX, box.maxY - 3), b = px(base, box.midX, box.maxY - 3)
        #expect(abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.05)
        let edge = px(rep, box.minX + 0.5, box.midY)
        #expect(edge.blueComponent > edge.redComponent + 0.2)            // selected: accent outline
    }

    @Test func clickSelectsDoubleClickAsksForDurationDragChangesIt() throws {
        let (v, t, ids) = try makeView()
        var selected: Transition.ID?? = nil
        var doubled: Transition.ID?
        var changes: [(Transition.ID, TransitionLayout.Change, Bool)] = []
        v.onTransitionSelect = { id, _ in selected = .some(id) }
        v.onTransitionDoubleClick = { doubled = $0 }
        v.onTransitionChange = { changes.append(($0, $1, $2)) }
        let row = v.geometry.rows(for: t)[0]
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first { $0.id == ids[0] })
        let box = TransitionLayout.rect(r, row: row, geometry: v.geometry)
        let mid = CGPoint(x: box.midX - 40, y: row.y + row.height / 2)

        v.mouseDown(with: event(.leftMouseDown, at: mid, in: v))
        #expect(selected == .some(ids[0]) && v.selectedTransition == ids[0])
        v.mouseUp(with: event(.leftMouseUp, at: mid, in: v))
        #expect(changes.isEmpty)                                          // a click is not a drag

        v.mouseDown(with: event(.leftMouseDown, at: mid, in: v, clicks: 2))
        #expect(doubled == ids[0])
        v.mouseUp(with: event(.leftMouseUp, at: mid, in: v))

        // Drag the right edge 3 frames to the right: a centred transition grows symmetrically, one gesture.
        let ppf = v.geometry.width(of: fd)
        let edge = CGPoint(x: box.maxX - 1, y: mid.y)
        v.mouseDown(with: event(.leftMouseDown, at: edge, in: v))
        v.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: edge.x + 3 * ppf, y: edge.y), in: v))
        v.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: edge.x + 4 * ppf, y: edge.y), in: v))
        v.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: edge.x + 4 * ppf, y: edge.y), in: v))
        #expect(changes.count == 2 && changes[0].2 == false && changes[1].2 == true)
        #expect(changes[0].1.duration == f(30) && changes[0].1.alignment == .center)
        #expect(changes[1].1.duration == f(32))

        // Shift-drag moves one side only.
        changes = []
        v.mouseDown(with: event(.leftMouseDown, at: edge, in: v))
        v.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: edge.x + 2 * ppf, y: edge.y), in: v, flags: .shift))
        v.mouseUp(with: event(.leftMouseUp, at: edge, in: v))
        #expect(changes.first?.1.alignment == .custom && changes.first?.1.duration == f(26))
    }

    @Test func clickingAClipDeselectsTheTransition() throws {
        let (v, t, ids) = try makeView(selectFirst: true)
        var selected: Transition.ID?? = nil
        v.onTransitionSelect = { id, _ in selected = .some(id) }
        #expect(v.selectedTransition == ids[0])
        let row = v.geometry.rows(for: t)[0]
        let x = v.geometry.x(for: f(100))                                  // inside B-roll, away from the boxes
        v.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: x, y: row.y + row.height / 2), in: v))
        v.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: x, y: row.y + row.height / 2), in: v))
        #expect(v.selectedTransition == nil && selected == .some(nil))
    }

    @Test func effectsPanelListsTransitionsInTheirBins() {
        let rows = EffectsPanelView.rows(matching: "")
        let titles = rows.map(\.title)
        #expect(titles.contains("Video Transitions") && titles.contains("Audio Transitions"))
        #expect(titles.contains("Cross Dissolve") && titles.contains("Dip to Black") && titles.contains("Dip to White"))
        #expect(titles.contains("Constant Power") && titles.contains("Constant Gain"))
        #expect(EffectsPanelView.transitionKind(forID: EffectsPanelView.transitionID(.dipToWhite)) == .dipToWhite)
        #expect(EffectsPanelView.transitionKind(forID: EffectsPanelView.roundedCorners) == nil)
        #expect(EffectsPanelView.rows(matching: "dissolve").contains { $0.title == "Cross Dissolve" })
    }

    @Test func commandsAndShortcuts() {
        let map = CommandMap.premiereDefault
        #expect(map.duplicates.isEmpty)
        #expect(map.binding(for: .applyVideoTransition) == KeyBinding(.char("d"), .command))
        #expect(map.binding(for: .applyAudioTransition) == KeyBinding(.char("d"), [.command, .shift]))
        #expect(map.binding(for: .applyDefaultTransitions) == KeyBinding(.char("d"), .shift))
        #expect(map.command(for: KeyBinding(.char("d"), []), focus: .timeline) == .selectClipAtPlayhead)
        #expect(EditorMenus.sequence.commands.contains(.applyVideoTransition) && EditorMenus.sequence.commands.contains(.applyDefaultTransitions))
    }

    @Test func controlsShowDurationAndAlignmentAndReportEdits() throws {
        let (_, t, ids) = try makeView()
        let tr = t.tracks[0].transitions.first { $0.id == ids[0] }!
        let resolved = t.resolvedTransitions(on: t.tracks[0].id).first { $0.id == ids[0] }
        let c = TransitionControlsView()
        c.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
        c.update(transition: tr, resolved: resolved, frameDuration: fd)
        c.layoutSubtreeIfNeeded()
        var duration: Time?
        var alignment: TransitionAlignment?
        c.onDuration = { duration = $0 }; c.onAlignment = { alignment = $0 }
        let texts = c.subviews.flatMap { v -> [NSView] in [v] + v.subviews.flatMap { [$0] + $0.subviews } }
        let field = try #require(texts.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let popUp = try #require(texts.compactMap { $0 as? NSPopUpButton }.first)
        #expect(field.stringValue == "00:00:00:24" && popUp.titleOfSelectedItem == "Center at Cut")
        field.stringValue = "1:10"
        field.sendAction(field.action, to: field.target)
        #expect(duration == f(40))
        field.stringValue = "garbage"
        field.sendAction(field.action, to: field.target)
        #expect(field.stringValue == "00:00:00:24" && duration == f(40))
        popUp.selectItem(withTitle: "End at Cut")
        popUp.sendAction(popUp.action, to: popUp.target)
        #expect(alignment == .endAtCut)
        if let dir = ProcessInfo.processInfo.environment["SQ_TRANSITION_SNAPSHOT"] {
            let rep = c.bitmapImageRepForCachingDisplay(in: c.bounds)!
            c.cacheDisplay(in: c.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("controls.png"))
        }
    }

    @Test func onlyTheSelectionToolHitsBoxesAndShiftKeepsTheClipSelection() throws {
        let (v, t, ids) = try makeView()
        let row = v.geometry.rows(for: t)[0]
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first { $0.id == ids[0] })
        let box = TransitionLayout.rect(r, row: row, geometry: v.geometry)
        let p = CGPoint(x: box.midX - 40, y: row.y + row.height / 2)
        var tool = v.toolState; tool.tool = .razor; v.toolState = tool
        v.mouseDown(with: event(.leftMouseDown, at: p, in: v))
        v.mouseUp(with: event(.leftMouseUp, at: p, in: v))
        #expect(v.selectedTransition == nil)                                // the razor cuts the clip beneath
        tool.tool = .selection; v.toolState = tool
        // A clip is selected first; a plain click on the box replaces it, Shift adds the transition to it.
        let clipPoint = CGPoint(x: v.geometry.x(for: f(100)), y: row.y + row.height / 2)
        v.mouseDown(with: event(.leftMouseDown, at: clipPoint, in: v)); v.mouseUp(with: event(.leftMouseUp, at: clipPoint, in: v))
        #expect(!v.selection.isEmpty)
        v.mouseDown(with: event(.leftMouseDown, at: p, in: v, flags: .shift)); v.mouseUp(with: event(.leftMouseUp, at: p, in: v, flags: .shift))
        #expect(v.selectedTransition == ids[0] && !v.selection.isEmpty)
        v.setSelectedTransition(nil)
        v.mouseDown(with: event(.leftMouseDown, at: p, in: v)); v.mouseUp(with: event(.leftMouseUp, at: p, in: v))
        #expect(v.selectedTransition == ids[0] && v.selection.isEmpty)
    }

    @Test func staleSelectionIsDroppedWhenTheTimelineChanges() throws {
        let (v, t, ids) = try makeView(selectFirst: true)
        #expect(v.selectedTransition == ids[0])
        var gone = t
        for i in gone.tracks.indices { gone.tracks[i].transitions = [] }
        v.setTimeline(gone)
        #expect(v.selectedTransition == nil)
    }
}
