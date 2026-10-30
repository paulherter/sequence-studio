import Foundation
import SQDrawKit
@testable import SQDrawMonitor
import Testing

/// The Mac `ScopesPanelView` parity of the drawn Scopes card: the "Measuring X" line above the scopes.
@MainActor
@Suite struct ScopesHintTests {
    @Test func theHintLinePushesTheScopesDown() throws {
        let p = ScopesPanel()
        p.layout(DrawRect(x: 0, y: 0, w: 320, h: 520), scale: 1)
        #expect(p.hintFrame == nil)
        let top = try #require(p.slots.first).popup.minY
        #expect(top == ScopeBoxLayout.top)
        p.hint = "On screen: B-roll"
        p.layout(DrawRect(x: 0, y: 0, w: 320, h: 520), scale: 1)
        let line = try #require(p.hintFrame)
        #expect(line == CGRect(x: 12, y: 4, width: 296, height: ScopesPanel.hintLineHeight))
        #expect(p.slots.first?.popup.minY == top + ScopesPanel.hintLineHeight + 4)
        #expect(p.slots.count == 2)
        p.hint = nil
        p.layout(DrawRect(x: 0, y: 0, w: 320, h: 520), scale: 1)
        #expect(p.hintFrame == nil && p.slots.first?.popup.minY == top)
    }

    @Test func theHintSaysWhatIsMeasured() {
        #expect(ScopesPanel.hintText("On screen: B-roll") == "Measuring B-roll, not the graded clip")
        #expect(ScopesPanel.hintText("On screen: no clip") == "Measuring no clip, not the graded clip")
    }
}
