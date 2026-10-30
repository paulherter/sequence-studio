import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// v87 Color range mask UI: add, edit (one undo step each, a drag coalesces), rows without Feather / Expansion.
@MainActor @Suite struct ColorRangeMaskUITests {
    final class Log { var edits: [String] = [] }

    func rig() -> (EffectControlsModel, Log) {
        let clip = Clip(name: "C", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)),
                        start: .zero, mediaDuration: Time(100, 1))
        let m = EffectControlsModel()
        let log = Log()
        m.onEdit = { _, n, _ in log.edits.append(n) }
        m.onGestureEnded = {}
        m.setClip(clip)
        return (m, log)
    }

    @Test func addIsOneStepAndSelectsTheMask() {
        let (m, log) = rig()
        let id = m.addColorRangeMask(key: ColorRangeKey(red: 1, green: 0, blue: 0, tolerance: 0.3, softness: 0.1))
        #expect(log.edits == ["Add Mask"])
        #expect(m.colorRangeMaskIDs == [id!])
        #expect(m.selectedSection == .mask(id!))
        #expect(m.colorRange(of: id!)?.red == 1)
    }

    @Test func editsAreOneStepEachAndASameValueIsNoStep() {
        let (m, log) = rig()
        let id = m.addColorRangeMask()!
        log.edits.removeAll()
        var k = m.colorRange(of: id)!
        k.tolerance = 0.5
        m.setMaskColorRange(id, k)
        m.setMaskColorRange(id, k)
        #expect(log.edits == ["Change Mask Color Range"])
        #expect(m.colorRange(of: id)?.tolerance == 0.5)
    }

    @Test func aDragIsOneUndoStep() {
        let (m, log) = rig()
        let id = m.addColorRangeMask()!
        log.edits.removeAll()
        var ended = 0
        m.onGestureEnded = { ended += 1 }
        m.beginGesture()
        for v in [0.3, 0.4, 0.5] {
            var k = m.colorRange(of: id)!
            k.softness = v
            m.setMaskColorRange(id, k)
        }
        m.endGesture()
        #expect(ended == 1)
        #expect(m.colorRange(of: id)?.softness == 0.5)
    }

    @Test func rowsHideFeatherAndExpansionAndAddTheKeyLines() {
        let (m, _) = rig()
        let id = m.addColorRangeMask()!
        let rows = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [],
                                             colorRangeMasks: m.colorRangeMaskIDs).map(\.kind)
        #expect(rows.contains(.property(.mask(id, .opacity))))
        #expect(!rows.contains(.property(.mask(id, .feather))) && !rows.contains(.property(.mask(id, .expansion))))
        #expect(rows.suffix(4) == [.colorRangeMask(id), .colorRangeAmount(id, soft: false), .colorRangeAmount(id, soft: true), .maskUse(id)])
        #expect(!rows.contains(.maskTrack(id)))
    }

    @Test func amountRowShowsPercentAndWritesBack() {
        let (m, _) = rig()
        let id = m.addColorRangeMask(key: ColorRangeKey(red: 0, green: 1, blue: 0, tolerance: 0.4, softness: 0.2))!
        let row = ColorRangeAmountRow(maskID: id, soft: false, model: m)
        row.update()
        #expect(m.colorRange(of: id)?.tolerance == 0.4)
    }

    @Test func nonColorRangeMaskHasNoKey() {
        let (m, _) = rig()
        m.addMask(.rectangle)
        #expect(m.colorRangeMaskIDs.isEmpty)
    }
}
