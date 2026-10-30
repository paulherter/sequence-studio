import Foundation
import SQCore
import Testing
@testable import SQEditorSession

private final class Clock2: @unchecked Sendable { var t = 0.0 }

@Suite struct ShuttleResetTests {
    @Test func externalStopMakesNextLStartAtOneX() {
        let clock = Clock2()
        var r = KeyRouter(clock: { clock.t })
        _ = r.handle(KeyEvent(.char("l")))
        _ = r.handle(KeyEvent(.char("l"), phase: .up))
        _ = r.handle(KeyEvent(.char("l")))                 // 2x
        _ = r.handle(KeyEvent(.char("l"), phase: .up))
        r.transportStopped()                               // a click stopped playback
        let out = r.handle(KeyEvent(.char("l")))
        #expect(out == [.shuttle(.setRate(.forward))])
    }

    @Test func handledKeysAreKnownToTheRouter() {
        let clock = Clock2()
        let r = KeyRouter(clock: { clock.t })
        // Space (also its auto-repeat) and every mapped key must be consumed by the host, or AppKit beeps.
        #expect(r.consumes(KeyEvent(.space)))
        #expect(r.consumes(KeyEvent(.space, isRepeat: true)))
        #expect(r.consumes(KeyEvent(.char("l"))))
        #expect(!r.consumes(KeyEvent(.char("q"), [.command, .option, .control])))
    }

    /// Regression: Space / J / K / L must reach a command from every focused panel (no panel scope may shadow them).
    @Test func transportKeysWorkFromEveryFocus() {
        let clock = Clock2()
        let panels: [PanelID?] = [nil] + PanelID.allCases.map { Optional($0) }
        for f in panels {
            var r = KeyRouter(focus: f, clock: { clock.t })
            #expect(r.handle(KeyEvent(.space)) == [.command(.playPause, focus: f)])
            #expect(r.consumes(KeyEvent(.space)))
            _ = r.handle(KeyEvent(.space, phase: .up))
            #expect(r.handle(KeyEvent(.char("l"))) == [.shuttle(.setRate(.forward))])
            _ = r.handle(KeyEvent(.char("l"), phase: .up))
        }
    }
}
