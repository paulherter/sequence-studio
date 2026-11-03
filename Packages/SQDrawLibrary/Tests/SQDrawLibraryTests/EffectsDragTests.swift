import CoreGraphics
import Foundation
import SQDrawKit
import Testing
@testable import SQDrawLibrary

@MainActor
@Suite struct EffectsDragTests {
    @Test func dragFromAnEffectRowReportsMovesAndTheRelease() throws {
        let panel = EffectsDrawPanel(defaults: UserDefaults(suiteName: "EffectsDrag.\(UUID().uuidString)")!)
        panel.size = CGSize(width: 260, height: 600)
        var seen: [(ids: [String], phase: EffectsDrawPanel.DragPhase)] = []
        panel.onDrag = { ids, phase, _ in seen.append((ids, phase)) }
        panel.setQuery("blur")
        let i = try #require(panel.rows.firstIndex { !$0.isFolder && !$0.isHeader })
        let p = CGPoint(x: 60, y: panel.rowRect(i).midY)
        panel.mouseDown(at: p, modifiers: [])
        panel.mouseDragged(to: CGPoint(x: p.x + 40, y: p.y - 20))
        #expect(panel.isDragging)
        #expect(seen.last?.phase == .moved && seen.last?.ids == [panel.rows[i].itemID])
        panel.mouseUp(at: CGPoint(x: p.x + 300, y: p.y - 20))
        #expect(seen.last?.phase == .ended)
    }

    @Test func dragFromAGridTileReportsMovesAndTheRelease() throws {
        let panel = EffectsDrawPanel(defaults: UserDefaults(suiteName: "EffectsDrag.\(UUID().uuidString)")!)
        panel.size = CGSize(width: 260, height: 600)
        panel.setViewMode(.grid)
        var seen: [(ids: [String], phase: EffectsDrawPanel.DragPhase)] = []
        panel.onDrag = { ids, phase, _ in seen.append((ids, phase)) }
        panel.setQuery("blur")
        let tile = try #require(panel.grid.items.first { !$0.isHeader })
        let p = CGPoint(x: tile.frame.midX, y: tile.frame.midY + EffectsDrawPanel.searchRowHeight)
        panel.mouseDown(at: p, modifiers: [])
        panel.mouseDragged(to: CGPoint(x: p.x + 40, y: p.y - 20))
        #expect(panel.isDragging)
        #expect(seen.last?.phase == .moved)
        panel.mouseUp(at: CGPoint(x: p.x + 300, y: p.y - 20))
        #expect(seen.last?.phase == .ended)
    }

    @Test func aSavedPresetRowDragsOutLikeAnEffect() throws {
        let panel = EffectsDrawPanel(defaults: UserDefaults(suiteName: "EffectsDrag.\(UUID().uuidString)")!)
        panel.size = CGSize(width: 260, height: 600)
        let id = UUID()
        panel.presetEntries = [EffectsCatalog.Entry(id: "preset.\(id.uuidString)", title: "Mine",
                                                    category: EffectFolderOutline.presetsFolder, symbol: .toolMask)]
        var seen: [[String]] = []
        panel.onDrag = { ids, _, _ in seen.append(ids) }
        panel.setQuery("Mine")
        let i = try #require(panel.rows.firstIndex { !$0.isFolder && !$0.isHeader })
        let p = CGPoint(x: 60, y: panel.rowRect(i).midY)
        panel.mouseDown(at: p, modifiers: [])
        panel.mouseDragged(to: CGPoint(x: p.x + 40, y: p.y - 20))
        #expect(seen.last == ["preset.\(id.uuidString)"])
    }
}
