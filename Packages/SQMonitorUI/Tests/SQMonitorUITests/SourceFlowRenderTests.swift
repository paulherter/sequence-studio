import AppKit
import SQCore
import Testing
@testable import SQMonitorUI

/// Renders the changed Source monitor layout (title popup, scrub strip with grips and markers, button bar) at 2x.
/// Set SQ_RENDER_DIR to keep the PNG; without it the test only checks that the layout has real size.
@MainActor @Suite struct SourceFlowRenderTests {
    @Test func sourcePanelRendersWithPopupGripsAndMarkers() throws {
        let fd = Time(1, 30)
        let m = MonitorPanelModel(frameDuration: fd, mode: .source)
        m.duration = Time(20, 1)
        m.currentTime = Time(9, 1)
        m.markIn = Time(4, 1); m.markOut = Time(13, 1)
        m.markerTimes = [Time(2, 1), Time(9, 1), Time(17, 1)]
        let a = UUID(), b = UUID()
        m.sourceItems = [.init(id: a, name: "Interview A cam.mov"), .init(id: b, name: "B-roll street.mp4")]
        m.sourceCurrent = a
        let panel = MonitorPanelView(model: m)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = panel
        panel.frame = NSRect(x: 0, y: 0, width: 520, height: 380)
        win.layoutIfNeeded()
        panel.layoutSubtreeIfNeeded()
        #expect(panel.viewerSlot.frame.height > 150)
        let rep = try #require(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
        panel.cacheDisplay(in: panel.bounds, to: rep)
        if let out = ProcessInfo.processInfo.environment["SQ_RENDER_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("sq2-source-panel.png"))
        }
    }

    /// Reference render of the unchanged Program header, to compare the Source header against.
    @Test func programPanelReference() throws {
        let m = MonitorPanelModel(frameDuration: Time(1, 30), mode: .program)
        m.duration = Time(20, 1); m.currentTime = Time(9, 1)
        let panel = MonitorPanelView(model: m)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = panel
        panel.frame = NSRect(x: 0, y: 0, width: 520, height: 380)
        win.layoutIfNeeded()
        panel.layoutSubtreeIfNeeded()
        let rep = try #require(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
        panel.cacheDisplay(in: panel.bounds, to: rep)
        if let out = ProcessInfo.processInfo.environment["SQ_RENDER_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("sq2-program-panel.png"))
        }
    }
}
