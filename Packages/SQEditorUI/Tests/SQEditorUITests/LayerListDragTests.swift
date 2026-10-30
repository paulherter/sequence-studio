import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQTimelineUI

/// Layer list drag: every single-layer drop into every gap lands where the insertion line was drawn.
@MainActor @Suite struct LayerListDragTests {
    private func layer(_ name: String) -> GraphicsLayer {
        var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        l.name = name
        return l
    }

    /// Plain layers p0...p3 plus a group of two in the middle: bottom first p0, g0, g1, p1, p2, p3.
    private func mixed() -> (GraphicsDocument, [UUID]) {
        var d = GraphicsDocument()
        let ids = ["p0", "g0", "g1", "p1", "p2", "p3"].map { d.add(layer($0)) }
        _ = d.group([ids[1], ids[2]], name: "G")
        return (d, ids)
    }

    @Test func everyGapPutsTheLayerWhereTheLineWasDrawn() {
        let (d, ids) = mixed()
        let rows = LayerListLogic.rows(d)
        for moved in ids {
            for gap in 0...rows.count {
                guard let drop = LayerListLogic.drop(.layers([moved]), rows: rows, document: d, gap: gap) else { continue }
                var after = d
                after.move(drop.ids, toIndex: drop.toIndex, group: drop.group)
                let front = after.layers.reversed().map(\.id)
                let i = front.firstIndex(of: moved)!
                // The row the layer must stay above: first row at or after the gap that is not the dragged one.
                let below = rows[gap...].first { $0.layerID != moved }
                switch below?.kind {
                case nil: #expect(i == front.count - 1, "gap \(gap) moved \(moved)")
                case .layer(let id)?: #expect(front.indices.contains(i + 1) && front[i + 1] == id, "gap \(gap) moved \(moved)")
                case .group(let g)?:
                    let members = front.filter { after.layer($0)?.group == g }
                    guard let first = members.first else { continue }      // the group dissolved (moved was a member)
                    #expect(i + 1 == front.firstIndex(of: first)!, "gap \(gap) moved \(moved)")
                }
            }
        }
    }

    @Test func movingEachLayerToTheTopInTurnSortsTheList() {
        var d = GraphicsDocument()
        let ids = ["a", "b", "c", "d", "e"].map { d.add(layer($0)) }      // bottom first
        let wanted = [ids[2], ids[0], ids[4], ids[1], ids[3]]             // bottom first
        for id in wanted {
            let rows = LayerListLogic.rows(d)
            guard let drop = LayerListLogic.drop(.layers([id]), rows: rows, document: d, gap: 0) else { continue }
            d.move(drop.ids, toIndex: drop.toIndex, group: drop.group)
        }
        #expect(d.layers.map(\.id) == wanted)
    }
}
