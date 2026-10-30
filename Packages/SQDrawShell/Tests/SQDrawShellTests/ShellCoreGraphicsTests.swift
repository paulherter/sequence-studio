#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// The Mac shared-UI host draws the shell through `CoreGraphicsRenderer`: the real start screen and an open menu must
/// come out as the reference rasterizer draws them (antialiased edges may differ, so mean and outlier share are checked).
@MainActor
@Suite struct ShellCoreGraphicsTests {
    static var hosts: [ShellHost] = []

    static func compare(_ list: DrawList, _ w: Int, _ h: Int, atlas: GlyphAtlas) throws -> (mean: Double, over: Double) {
        let clear = DrawColor(hex: 0x1E1E1E)
        let cg = try #require(CoreGraphicsRenderer.render(list, width: w, height: h, clear: clear, atlas: atlas))
        let sw = SoftwareRenderer.render(list, width: w, height: h, clear: clear, atlas: atlas)
        var sum = 0, over = 0, n = 0
        for i in 0..<sw.pixels.count where i % 4 != 3 {
            let d = abs(Int(cg.pixels[i]) - Int(sw.pixels[i]))
            sum += d; n += 1
            if d > 24 { over += 1 }
        }
        return (Double(sum) / Double(n), Double(over) / Double(n))
    }

    func frame(_ h: ShellHost, atlas: GlyphAtlas, scale: Float, w: Int, hgt: Int) -> DrawList {
        let theme = DrawTheme(scale: scale)
        h.measure = TextMeasure(atlas: atlas, scale: scale)
        h.size = CGSize(width: CGFloat(Float(w) / scale), height: CGFloat(Float(hgt) / scale))
        var c = Canvas(width: Float(w), height: Float(hgt), atlas: atlas, scale: scale)
        c.fill(CGRect(origin: .zero, size: h.size), theme.canvas)
        h.drawBar(&c, theme: theme)
        h.drawOverlays(&c, theme: theme)
        return c.list
    }

    @Test func startScreenMatchesTheReference() throws {
        let atlas = try #require(GlyphAtlas())
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault, recents: RecentProjects(entries: []))
        Self.hosts.append(h)
        h.showStart(defaults: UserDefaults(suiteName: "sq.test.cg.\(UUID())")!)
        let list = frame(h, atlas: atlas, scale: 2, w: 1600, hgt: 1000)
        #expect(list.quads.count > 50)
        let d = try Self.compare(list, 1600, 1000, atlas: atlas)
        #expect(d.mean < 1.0)
        #expect(d.over < 0.005)
    }

    @Test func openMenuMatchesTheReference() throws {
        let atlas = try #require(GlyphAtlas())
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        Self.hosts.append(h)
        _ = frame(h, atlas: atlas, scale: 1, w: 900, hgt: 600)
        let title = try #require(h.menuBar.titleFrames.first)
        _ = h.handle(.mouseDown(x: Float(title.midX), y: Float(title.midY), modifiers: []), scale: 1)
        _ = h.handle(.mouseUp(x: Float(title.midX), y: Float(title.midY)), scale: 1)
        #expect(h.menuBar.controller.isOpen)
        let list = frame(h, atlas: atlas, scale: 1, w: 900, hgt: 600)
        let d = try Self.compare(list, 900, 600, atlas: atlas)
        #expect(d.mean < 1.0)
        #expect(d.over < 0.005)
    }
}
#endif
