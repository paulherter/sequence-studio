import AppKit
import Foundation
import SQCore
import Testing
@testable import SQInspectorUI

/// Menus that build SQ rows directly (no NSMenu): titles, order, enabled state and shortcut text.
@MainActor
@Suite struct SQMenuRowsTests {
    private func titles(_ rows: [SQMenuItem]) -> [String] { rows.map { $0.kind == .separator ? "-" : $0.title } }

    @Test func graphEasingRowsStartWithModeAndRunTheirActions() {
        let g = KeyframeGraphView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        g.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 0), Keyframe(time: Time(4, 1), value: 100)])
        var mode: GraphMode?
        g.onModeChange = { mode = $0 }
        let rows = g.makeEasingItems()
        #expect(titles(rows).prefix(3) == ["Speed", "Value", "-"])
        #expect(rows[0].isChecked != rows[1].isChecked)
        rows[1].action?()
        #expect(mode == .value)
        // Without a selected key nothing can be saved as a preset.
        #expect(rows.first { $0.title == "Save as preset\u{2026}" }?.isEnabled == false)
    }

    @Test func transitionMenuRowsFollowTheShownKind() {
        let c = TransitionControlsView()
        #expect(c.contextItems().isEmpty)
        let tr = Transition(kind: .dipToColour, duration: Time(10, 30), outgoing: UUID(), incoming: UUID())
        c.update(transition: tr, resolved: nil, frameDuration: Time(1, 30))
        let rows = c.contextItems()
        #expect(titles(rows) == ["Reset", "-", "Use as Default for \(tr.kind.name)", "Reset Default to Factory"])
        #expect(!rows[3].isEnabled)
        var reset = 0
        c.onReset = { reset += 1 }
        rows[0].action?()
        #expect(reset == 1)
    }

    @Test func keystoneRowsForAClickedRowAndForEmptySpace() {
        let model = KeystonesPanelModel()
        let view = KeystonesPanelView(model: model)
        #expect(titles(view.contextItems(row: -1)) == ["Save Keystone from Selected Clip\u{2026}"])
        let rows = view.contextItems(row: 0)
        #expect(titles(rows) == ["Apply to Selected Clip", "-", "Edit Curve\u{2026}", "Use Keyframe Easing", "-",
                                           "Save Keystone from Selected Clip\u{2026}"])      // a built-in without saved changes: no Reset row
        #expect(!rows[3].isEnabled)
    }
}

/// Menu help text is a caption line in the SQ menu, never the system tooltip.
@MainActor
@Suite struct SQMenuHelpTests {
    @Test func helpTextCarriesFromNSMenuItemToATallerRow() {
        let menu = NSMenu()
        let a = NSMenuItem(title: "Plain", action: nil, keyEquivalent: "")
        let b = NSMenuItem(title: "Helpful", action: nil, keyEquivalent: "")
        b.sqHelp = "Needs a video clip"
        menu.addItem(a); menu.addItem(b)
        #expect(b.toolTip == nil)
        let rows = SQMenuItem.items(from: menu)
        #expect(rows[0].help == nil)
        #expect(rows[1].help == "Needs a video clip")
        let h = SQMenuLayout.heights(rows)
        #expect(h[1] == h[0] + SQMenuLayout.helpHeight)
    }
}
