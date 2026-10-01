import AppKit
import SSCore
import Testing
@testable import SSEditorUI

@MainActor @Suite struct SpeedSheetRenderTests {
    @Test func accessoryViewHasContentAndRendersAtTwoX() throws {
        let fd = Time(1, 24)
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 48), start: .zero,
                        speed: ClipSpeed(percent: 200))
        let sheet = SpeedDurationSheet(model: SpeedDialogModel(clips: [clip], frameDuration: fd),
                                       timecode: Timecode(frameDuration: fd, dropFrame: false))
        let v = sheet.buildView()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: v.frame.width + 40, height: v.frame.height + 40),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        let host = NSView(frame: win.contentView!.bounds)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        host.addSubview(v)
        v.setFrameOrigin(NSPoint(x: 20, y: 20))
        win.contentView = host
        win.layoutIfNeeded()
        #expect(v.frame.width > 150 && v.frame.height > 100)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let out = ProcessInfo.processInfo.environment["SQ_RENDER_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("speed-sheet.png"))
        }
    }
}
