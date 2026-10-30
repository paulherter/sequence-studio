import Foundation
import Testing
import SQCore
import SQAudioFX
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// Track audio controls on the shared toolkit (Windows): the Mac `TrackAudioInspectorView` rows through `TrackAudioDraw`.
@MainActor @Suite struct TrackAudioDrawTests {
    private func block() -> TrackAudioDraw {
        let b = TrackAudioDraw(model: TrackAudioInspectorModel())
        b.width = 320
        return b
    }

    @Test func drawsElevenRowsWithTheStrip() {
        let b = block()
        #expect(b.rows.count == 11)
        #expect(b.height == 10 * ControlsGrid.rowHeight + TrackAudioDraw.bandsHeight + ControlsGrid.gap)
        var c = Canvas(width: 320, height: Float(b.height), atlas: nil, scale: 1)
        b.draw(&c)
        #expect(!c.list.quads.isEmpty)
    }

    @Test func gateCheckboxEnablesItsSlidersAndSliderDragIsOneChange() throws {
        let b = block(), m = b.model
        #expect(!b.isEnabled(.attack))
        let check = try #require(b.frame(.gate))
        b.mouseDown(at: CGPoint(x: check.midX, y: check.midY), clickCount: 1)
        b.mouseUp(at: CGPoint(x: check.midX, y: check.midY))
        #expect(m.gate.enabled && b.isEnabled(.attack))
        let track = b.sliderParts(try #require(b.frame(.slider(.denoise)))).track
        var changes = 0
        m.onBeginChange = { changes += 1 }
        b.mouseDown(at: CGPoint(x: track.minX + 1, y: track.midY), clickCount: 1)
        b.mouseDragged(to: CGPoint(x: track.midX, y: track.midY))
        b.mouseDragged(to: CGPoint(x: track.maxX, y: track.midY))
        b.mouseUp(at: CGPoint(x: track.maxX, y: track.midY))
        #expect(m.noiseReductionPercent == 100)
        #expect(changes == 1)
    }

    @Test func crossoverDragMovesTheBandEdge() throws {
        let b = block(), m = b.model
        let f = try #require(b.frame(.bands))
        let g = CompressorBandsGeometry(width: f.width)
        let before = m.compressor.crossoversHz[1]
        let x = f.minX + g.x(forHz: before)
        b.mouseDown(at: CGPoint(x: x, y: f.midY), clickCount: 1)
        b.mouseDragged(to: CGPoint(x: x + 20, y: f.midY))
        b.mouseUp(at: CGPoint(x: x + 20, y: f.midY))
        #expect(m.compressor.crossoversHz[1] > before)
    }

    @Test func popupsOfferRolesAndPresets() throws {
        let b = block(), m = b.model
        var shown: [SQMenuItem] = []
        b.onMenu = { items, _ in shown = items }
        let role = try #require(b.frame(.role))
        b.mouseDown(at: CGPoint(x: role.midX, y: role.midY), clickCount: 1)
        #expect(shown.map(\.title) == TrackAudioInspectorModel.roleTitles)
        shown[1].action?()
        #expect(m.role == AudioTag.allCases[0])
        let typed = try #require(b.frame(.slider(.mix)))
        #expect(b.help(at: CGPoint(x: typed.midX, y: typed.midY))?.hasPrefix("Warmth mix") == true)
    }
}
