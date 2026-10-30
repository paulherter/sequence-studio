import AppKit
import SQCore
import SQEditorSession
import Testing
@testable import SQMonitorUI

@Suite struct MonitorDropZoneTests {
    @Test func leftHalfInsertsRightHalfOverwrites() {
        #expect(MonitorDropZone.zone(atX: 10, width: 600) == .insert)
        #expect(MonitorDropZone.zone(atX: 299.9, width: 600) == .insert)
        #expect(MonitorDropZone.zone(atX: 300, width: 600) == .overwrite)
        #expect(MonitorDropZone.zone(atX: 590, width: 600) == .overwrite)
        #expect(MonitorDropZone.zone(atX: 5, width: 0) == .overwrite)
    }

    @Test func zoneRectsSplitThePanel() {
        let size = CGSize(width: 600, height: 400)
        #expect(MonitorDropZone.insert.rect(in: size) == CGRect(x: 0, y: 0, width: 300, height: 400))
        #expect(MonitorDropZone.overwrite.rect(in: size) == CGRect(x: 300, y: 0, width: 300, height: 400))
    }
}

@MainActor @Suite struct MonitorAccessibilityTests {
    @Test func programPictureHasALabelAndSize() {
        let s = ProgramSurfaceView(viewer: NSView())
        s.sequenceSize = CGSize(width: 1080, height: 1920)
        #expect(s.accessibilityLabel() == "Program picture")
        #expect(s.accessibilityValue() as? String == "1080 by 1920 pixels")
    }

    @Test func loudnessMeterReadsOutItsNumbers() {
        let m = LoudnessMeterView()
        #expect(m.isAccessibilityElement())
        #expect(m.accessibilityLabel() == "Loudness meter")
        #expect(m.accessibilityValue() as? String
                == "Momentary no signal, short-term no signal, integrated no signal, true peak no signal, loudness range needs 60 seconds of signal")
        m.reading = LoudnessReading(momentaryLUFS: -14.04, shortTermLUFS: -15, integratedLUFS: -13.96, truePeakDB: -1.25)
        let text = m.accessibilityValue() as? String ?? ""
        #expect(text.contains("Momentary -14.0 LUFS"))
        #expect(text.contains("integrated -14.0 LUFS"))
        #expect(text.contains("true peak -1.2 dBTP") || text.contains("true peak -1.3 dBTP"))
    }
}

@MainActor @Suite struct MonitorOptionsMenuTests {
    @Test func scopesRowOnlyWhenTheHostOffersIt() {
        let m = MonitorPanelModel(frameDuration: Time(1, 30), mode: .program)
        let panel = MonitorPanelView(model: m)
        #expect(!panel.optionItems().contains { $0.title == "Scopes" })
        var shown = 0
        m.onShowScopes = { shown += 1 }
        panel.optionItems().first { $0.title == "Scopes" }?.action?()
        #expect(shown == 1)
    }
}

/// Crop handles on the Program picture: a drag on an edge handle reports the new inset once per move; leaving the
/// window in the middle of a drag cancels it instead of writing.
@MainActor @Suite struct CropOverlayTests {
    private func event(_ type: NSEvent.EventType, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private final class Log { var phases: [TransformOverlayView.Phase] = []; var last: Double = 0; var edge: CropEdge?; var canceled = 0 }

    private func surface(_ log: Log) -> ProgramSurfaceView {
        let v = ProgramSurfaceView(viewer: NSView())
        v.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        v.sequenceSize = CGSize(width: 1920, height: 1080)
        v.layoutSubtreeIfNeeded()
        let target = OverlayTarget(clip: UUID(), size: CGSize(width: 1920, height: 1080), isText: false,
                                   baseTransform: ClipTransform(), shift: .zero, positionTrack: KeyframeTrack<Vec2>())
        v.setTarget(target, snap: nil)
        v.setCrop(CropInsets.none) { phase, edge, value in log.phases.append(phase); log.edge = edge; log.last = value }
        v.overlay.onDragCancelled = { log.canceled += 1 }
        return v
    }

    @Test func draggingTheLeftHandleReportsTheInset() throws {
        let log = Log()
        let v = surface(log)
        let o = v.overlay
        o.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 1, y: 270)))
        o.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 120, y: 270)))
        o.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 240, y: 270)))
        #expect(log.edge == .left)
        #expect(log.phases.first == .began && log.phases.last == .ended)
        #expect(abs(log.last - 0.25) < 0.02)
    }

    @Test func leavingTheWindowMidDragCancelsIt() throws {
        let log = Log()
        let v = surface(log)
        let o = v.overlay
        o.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 1, y: 270)))
        o.viewWillMove(toWindow: nil)
        o.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 240, y: 270)))
        #expect(log.canceled == 1)
        #expect(!log.phases.contains(.ended))
    }
}

@Suite struct MaskOverlayMappingTests {
    @Test func frameFractionsRoundTripThroughARotatedQuad() throws {
        // A 200 x 100 layer turned by 90 degrees about (100, 100).
        let q = [CGPoint(x: 150, y: 0), CGPoint(x: 150, y: 200), CGPoint(x: 50, y: 200), CGPoint(x: 50, y: 0)]
        let g = MaskOverlayGeometry(quad: q)
        let p = g.viewPoint(Vec2(0.25, 0.5))
        let n = try #require(g.framePoint(p))
        #expect(abs(n.x - 0.25) < 1e-9 && abs(n.y - 0.5) < 1e-9)
        #expect(abs(p.x - 100) < 1e-9 && abs(p.y - 50) < 1e-9)
    }

    @Test func aLayerWithoutAreaMapsNothing() {
        let flat = [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)]
        #expect(MaskOverlayGeometry(quad: flat).framePoint(CGPoint(x: 10, y: 10)) == nil)
    }
}

/// D12: Esc (or leaving the window) in the middle of a mask gesture drops it instead of writing it.
@MainActor @Suite struct MaskGestureCancelTests {
    private func event(_ type: NSEvent.EventType, _ p: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func overlay(masks: [MaskOverlay]) -> TransformOverlayView {
        let v = ProgramSurfaceView(viewer: NSView())
        v.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        v.sequenceSize = CGSize(width: 1920, height: 1080)
        v.layoutSubtreeIfNeeded()
        let target = OverlayTarget(clip: UUID(), size: CGSize(width: 1920, height: 1080), isText: false,
                                   baseTransform: ClipTransform(), shift: .zero, positionTrack: KeyframeTrack<Vec2>())
        v.setTarget(target, snap: nil)
        v.overlay.masks = masks
        return v.overlay
    }

    @Test func aVertexDragCanceledPutsTheMaskBack() throws {
        let id = UUID()
        let path = MaskPath.rectangle(Vec2(0.25, 0.25), Vec2(0.75, 0.75))
        let o = overlay(masks: [MaskOverlay(id: id, path: path, active: true)])
        var phases: [TransformOverlayView.Phase] = []
        var canceled = 0
        o.onMaskVertex = { phase, _, _, _ in phases.append(phase) }
        o.onDragCancelled = { canceled += 1 }
        o.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 240, y: 135)))
        try #require(phases.first == .began)
        o.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 300, y: 200)))
        #expect(o.masks[0].path != path)
        o.viewWillMove(toWindow: nil)                       // same path as Esc
        #expect(o.masks[0].path == path)
        #expect(canceled == 1)
        o.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 300, y: 200)))
        #expect(!phases.contains(.ended))
    }

    @Test func aShapeBeingDrawnIsDroppedWithoutTouchingTheClip() throws {
        let o = overlay(masks: [])
        var drawn = 0, canceled = 0
        o.maskTool = .rectangle
        o.onMaskShapeDrawn = { _, _ in drawn += 1 }
        o.onDragCancelled = { canceled += 1 }
        o.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 200, y: 100)))
        o.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 400, y: 300)))
        o.viewWillMove(toWindow: nil)
        o.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 400, y: 300)))
        #expect(drawn == 0)
        #expect(canceled == 0)
    }
}
