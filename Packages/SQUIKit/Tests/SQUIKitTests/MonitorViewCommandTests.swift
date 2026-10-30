import Testing
@testable import SQUIKit

@Suite struct MonitorViewCommandTests {
    @Test func viewMenuHasOverlaysAndOneItemPerGamma() {
        let cmds = EditorMenus.view.commands
        #expect(cmds.contains(.toggleOverlays))
        #expect(CommandSupport.isSupported(.toggleOverlays))
        for g in ViewGammaChoice.allCases {
            #expect(cmds.contains(.viewGamma(g)))
            #expect(CommandSupport.isSupported(.viewGamma(g)))
        }
        #expect(ViewGammaChoice.allCases.map(\.rawValue) == ["mac", "web", "broadcast"])
    }

    @Test func gammaCommandIdsRoundTrip() {
        for g in ViewGammaChoice.allCases {
            let c = EditorCommand.viewGamma(g)
            #expect(c.id == "viewGamma.\(g.rawValue)")
            #expect(EditorCommand(id: c.id) == c)
        }
        #expect(EditorCommand(id: EditorCommand.toggleOverlays.id) == .toggleOverlays)
    }
}
