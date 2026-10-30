import Foundation
import SQDrawKit
import SQDrawMonitor
import SQInspectorUI
import Testing
@testable import SQAppShell

@MainActor
@Suite struct ColorPageLoupeTests {
    /// 20 x 10 frame whose pixel (x, y) has red x / 19 and green y / 9 (linear).
    func ramp() -> ProgramLinearFrame {
        var px: [SIMD3<Float>] = []
        for y in 0..<10 { for x in 0..<20 { px.append(SIMD3(Float(x) / 19, Float(y) / 9, 0)) } }
        return ProgramLinearFrame(width: 20, height: 10, pixels: px)
    }

    @Test func theGridIsElevenPixelsAroundThePointerAndCutAtTheEdge() throws {
        let f = ramp()
        let mid = try #require(f.loupe(at: SIMD2(0.5, 0.5)))
        #expect(mid.width == 11 && mid.height == 10 && mid.centerX == 5 && mid.centerY == 5)
        #expect(mid.center == ProgramLinearFrame.display8(SIMD3(10.0 / 19, 5.0 / 9, 0)))
        let corner = try #require(f.loupe(at: SIMD2(0, 0)))
        #expect(corner.width == 6 && corner.height == 6 && corner.centerX == 0 && corner.centerY == 0)
        #expect(f.loupe(at: SIMD2(1.2, 0.5)) == nil)
    }

    @Test func displayValuesUseTheRec709CurveAndClamp() {
        #expect(ProgramLinearFrame.display8(SIMD3(0, 1, 2)) == SIMD3(0, 255, 255))
        #expect(ProgramLinearFrame.display8(SIMD3(0.18, -1, .nan)) == SIMD3(104, 0, 0))   // mid gray 0.409 encoded
    }

    @Test func pickingOverTheProgramPictureShowsTheLoupeFromOneReadBack() throws {
        let rigs = ColorPageHostTests()
        let (_, shell, host) = try rigs.rig()
        shell.dock.setPage(.color)
        host.layout()
        var reads: [Int?] = []
        host.readProgramFrame = { w in reads.append(w); return ramp() }
        let panel = rigs.monitor(host)
        let r = panel.canvasRect
        let model = try #require(host.controller.model)
        let e = try #require(model.effects.first?.id)
        model.onPickWhiteBalance?(e)
        _ = host.handle(.mouseMoved(x: Float(r.midX), y: Float(r.midY)), scale: 1)
        let grid = try #require(host.loupe?.grid)
        #expect(grid.width == 11 && reads == [ColorPageHost.loupeWidth])
        _ = host.handle(.mouseMoved(x: Float(r.midX + 4), y: Float(r.midY)), scale: 1)
        #expect(host.loupe != nil && reads.count == 1, "later moves reuse the frame")
        _ = host.handle(.mouseMoved(x: Float(r.maxX + 20), y: Float(r.midY)), scale: 1)
        #expect(host.loupe == nil)
        _ = host.handle(.keyDown(.escape, modifiers: []), scale: 1)
        model.onPickWhiteBalance?(e)
        _ = host.handle(.mouseMoved(x: Float(r.midX), y: Float(r.midY)), scale: 1)
        #expect(reads.count == 2, "a new pick reads a new frame")
    }
}
