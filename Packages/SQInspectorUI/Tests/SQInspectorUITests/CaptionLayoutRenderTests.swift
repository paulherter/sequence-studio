import AppKit
import Foundation
import Testing
import SQCore
import SQText
@testable import SQInspectorUI

/// Draws the changed panels offscreen (2x) for a look by eye. A no-op unless $SQ_RENDER_DIR is set.
@MainActor @Suite struct CaptionLayoutRenderTests {
    private func png(_ v: NSView, size: NSSize, name: String, dir: String) throws {
        v.frame = NSRect(origin: .zero, size: size)
        v.layoutSubtreeIfNeeded()
        v.layout()
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        rep.size = size
        v.cacheDisplay(in: v.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    @Test func rendersTheChangedPanels() throws {
        guard let dir = ProcessInfo.processInfo.environment["SQ_RENDER_DIR"] else { return }
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        func item(_ text: String, _ a: Int64) -> CaptionItem {
            CaptionItem(lines: [text], range: TimeRange(start: Time(a, 1), end: Time(a + 2, 1)), styleRef: "tiktok")
        }
        session.replaceCaptions([item("So this is how it works", 0), item("and then it gets better", 2)])
        session.setCaptionKaraoke(KaraokeStyle())
        let tab = CaptionsTabView()
        tab.session = session
        tab.setTimeline(session.activeTimeline)
        try png(tab, size: NSSize(width: 320, height: 520), name: "captions-tab.png", dir: dir)

        var style = CaptionPresetLibrary.builtIn.style(for: "tiktok")
        style.allCaps = true
        let inspector = TextInspectorView(model: TextInspectorModel(style: style))
        try png(inspector, size: NSSize(width: 300, height: 700), name: "text-inspector.png", dir: dir)
    }
}
