import AppKit
import Testing
import SQCore
@testable import SQTimelineUI

@MainActor @Suite struct FastCutStripTests {
    @Test func stripCarriesTheKeyOnlyVerbsInEditOrder() {
        #expect(FastCutStrip.verbs.map(\.command) == [.appendToMainTrack, .insertSpacer, .liftOffMainTrack, .putOnMainTrack, .createStoryline])
        #expect(FastCutStrip.verbs.map(\.title) == ["Append", "Spacer", "Lift off", "Put on", "Storyline"])
    }

    @Test func clickRunsTheCommandAndEnabledFollowsTheOwner() {
        let strip = FastCutStrip(frame: .zero)
        var ran: [EditorCommand] = []
        strip.onVerb = { ran.append($0) }
        strip.setEnabled { $0 == .insertSpacer }
        let buttons = strip.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.map(\.isEnabled) == [false, true, false, false, false])
        strip.clicked(buttons[1] as! SQButton)
        #expect(ran == [.insertSpacer])
    }
}
