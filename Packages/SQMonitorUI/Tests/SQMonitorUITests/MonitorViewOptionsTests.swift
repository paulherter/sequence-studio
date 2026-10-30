import Metal
import simd
import SQCore
import SQRender
import Testing
@testable import SQMonitorUI

@MainActor @Suite struct MonitorViewOptionsTests {
    @Test func viewGammaMenuChecksTheCurrentChoiceAndSetsIt() {
        var chosen: ViewGamma?
        let rows = MonitorMenus.viewGammaItems(current: .web, set: { chosen = $0 })
        #expect(rows.map(\.title) == ["Mac 1.96", "Web 2.2", "Broadcast 2.4"])
        #expect(rows.map(\.isChecked) == [false, true, false])
        #expect(rows.allSatisfy { $0.help?.isEmpty == false })
        rows[2].action?()
        #expect(chosen == .broadcast)
    }

    @Test func modelSharesTheGammaWithThePresenters() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        defer { ViewGamma.current = .mac }
        m.setViewGamma(.broadcast)
        #expect(m.viewGamma == .broadcast && ViewGamma.current == .broadcast)
    }

    @Test func displayViewMenuListsTheViewsAndSharesTheChoice() {
        var chosen: DisplayView?
        let rows = MonitorMenus.displayViewItems(current: .sdr, set: { chosen = $0 })
        #expect(rows.map(\.title) == ["SDR 100 nit Rec.709", "Display P3", "HDR 1000 nit", "Not Tone-Mapped"])
        #expect(rows.map(\.isChecked) == [true, false, false, false])
        rows[2].action?()
        #expect(chosen == .hdr1000)
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        defer { DisplayView.current = .sdr }
        m.setDisplayView(.displayP3)
        #expect(m.displayView == .displayP3 && DisplayView.current == .displayP3)
    }

    @Test func overlaysToggleKeepsTheirSettings() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        m.showsRulers = true
        m.toggleOverlays()
        #expect(m.overlaysHidden && m.showsRulers)
        m.toggleOverlays()
        #expect(!m.overlaysHidden)
    }

    @Test func magnifierGridReadsTheCenterAndCutsAtTheEdge() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 16, height: 8, mipmapped: false)
        let t = try #require(device.makeTexture(descriptor: d))
        var px: [Float16] = []
        for _ in 0..<8 { for x in 0..<16 { px += x == 5 ? [1, 0, 0, 1] : [0.5, 0.5, 0.5, 1] } }
        t.replace(region: MTLRegionMake2D(0, 0, 16, 8), mipmapLevel: 0, withBytes: px, bytesPerRow: 16 * 8)
        // Pointer on the red column: 5 x 5 patch, center cell red.
        let g = try #require(FrameSampler.gridNow(of: t, at: SIMD2((5.5) / 16, 0.5), radius: 2))
        #expect(g.width == 5 && g.height == 5 && g.centerX == 2 && g.centerY == 2)
        #expect(g.center.x == 1 && g.center.y == 0)
        #expect(g.readout == "R 255  G 0  B 0")
        // Corner: the patch is cut and the center cell is the corner pixel.
        let c = try #require(FrameSampler.gridNow(of: t, at: SIMD2(0, 0), radius: 2))
        #expect(c.width == 3 && c.height == 3 && c.centerX == 0 && c.centerY == 0)
    }

    @Test func magnifierStaysInsideAndFlipsNearEdges() {
        let size = CGSize(width: 100, height: 120)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let free = MagnifierView.frame(size: size, pointer: CGPoint(x: 50, y: 50), in: bounds)
        #expect(free.minX > 50 && free.minY > 50)
        let corner = MagnifierView.frame(size: size, pointer: CGPoint(x: 395, y: 295), in: bounds)
        #expect(corner.maxX <= 395 && corner.maxY <= 295 && bounds.contains(corner))
    }
}
