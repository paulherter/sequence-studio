import AppKit
import SQCore
import SQEditorUI

/// Developer aid: `SQ_MASKTEST=<media file>` imports the clip, places it, picks the Mask tool (Rectangle) and posts real
/// mouse events onto the Program monitor overlay: a click, a drag, a second click, a second drag, an Ellipse drag, a
/// vertex drag and a move. Logs the masks after each step and a main-thread heartbeat, so a hang shows as missing beats.
@MainActor
enum MaskTestDriver {
    static func runIfRequested(_ c: AppController) {
        guard let path = ProcessInfo.processInfo.environment["SQ_MASKTEST"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            await c.panels.projectModel.importFiles([URL(fileURLWithPath: path)])
            guard let m = c.session.project.media.first else { NSLog("MASKTEST no media"); exit(2) }
            _ = c.session.placeMedia([m.id], at: .zero, mode: .overwrite)
            c.session.seek(to: Time(1, 1))
            try? await Task.sleep(for: .seconds(1))
            guard let clip = c.session.activeTimeline?.tracks.flatMap(\.clips).first else { NSLog("MASKTEST no clip"); exit(3) }
            c.session.select(clips: [clip.id])
            c.panels.timelineView.toolState.maskMode = .rectangle
            c.panels.timelineView.toolState.tool = .mask
            c.panels.timelineView.onToolChange?(.mask)
            try? await Task.sleep(for: .seconds(1))
            let o = c.panels.surface.overlay
            let beat = Thread { while true { Thread.sleep(forTimeInterval: 1); DispatchQueue.main.async { NSLog("MASKTEST beat") } } }
            beat.start()
            @MainActor func at(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint {
                let r = o.canvasRect
                return o.convert(NSPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy), to: nil)
            }
            @MainActor func post(_ type: NSEvent.EventType, _ p: NSPoint, _ flags: NSEvent.ModifierFlags = []) {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { return }
                switch type {
                case .leftMouseDown: o.mouseDown(with: e)
                case .leftMouseDragged: o.mouseDragged(with: e)
                default: o.mouseUp(with: e)
                }
            }
            @MainActor func drag(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat), _ flags: NSEvent.ModifierFlags = []) {
                post(.leftMouseDown, at(a.0, a.1), flags)
                for i in 1...8 {
                    let t = CGFloat(i) / 8
                    post(.leftMouseDragged, at(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t), flags)
                }
                post(.leftMouseUp, at(b.0, b.1), flags)
            }
            @MainActor func log(_ step: String) {
                let ms = c.panels.effectModel.clip?.masks ?? []
                NSLog("MASKTEST \(step): masks=\(ms.count) selected=\(String(describing: c.panels.effectModel.selectedSection)) overlay=\(o.masks.count) active=\(o.masks.filter(\.active).count) canvas=\(o.canvasRect)")
            }
            log("start")
            drag((0.4, 0.4), (0.4, 0.4)); log("click 1")
            try? await Task.sleep(for: .seconds(1))
            drag((0.1, 0.1), (0.3, 0.35)); log("drag 1")
            try? await Task.sleep(for: .seconds(1))
            drag((0.7, 0.7), (0.7, 0.7)); log("click 2")
            try? await Task.sleep(for: .seconds(1))
            drag((0.55, 0.15), (0.9, 0.45), .shift); log("drag 2 shift")
            try? await Task.sleep(for: .seconds(1))
            c.panels.timelineView.toolState.maskMode = .ellipse
            c.panels.timelineView.onToolChange?(.mask)
            drag((0.2, 0.6), (0.35, 0.9), .option); log("ellipse option")
            try? await Task.sleep(for: .seconds(1))
            drag((0.275, 0.75), (0.3, 0.7)); log("move inside active ellipse")
            try? await Task.sleep(for: .seconds(1))
            // Selection tool: drag the first vertex of the first (not active) mask, then the Effect Controls row + Delete.
            c.panels.timelineView.toolState.tool = .selection
            c.panels.timelineView.onToolChange?(.selection)
            try? await Task.sleep(for: .seconds(0.5))
            if let first = o.masks.first, let v = first.path.vertices.first {
                // The clip fills the canvas here (sequence made from it): frame fraction = canvas fraction.
                let fx = CGFloat(v.point.x), fy = CGFloat(v.point.y)
                drag((fx, fy), (fx + 0.05, fy + 0.05))
                log("vertex drag on first mask (selection tool)")
            }
            try? await Task.sleep(for: .seconds(1))
            if let id = c.panels.effectModel.clip?.masks.dropFirst().first?.id {
                c.panels.effectModel.selectEffectHeader(.mask(id))
                c.panels.effectModel.deleteSelectionOrEffect()
                log("row select + Delete on mask 2")
            }
            for _ in 0..<4 { _ = c.session.undo() }
            log("undo x4")
            for _ in 0..<4 { _ = c.session.redo() }
            log("redo x4")
            c.session.playPause()
            try? await Task.sleep(for: .seconds(2))
            c.session.playPause()
            log("played 2 s")
            try? await Task.sleep(for: .seconds(1))
            log("end")
            exit(0)
        }
    }
}
