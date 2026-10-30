import Foundation
import CoreGraphics
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// Color page on the shared toolkit, round 5: the Steps rename field takes the caret under a click and shows the I-beam.
@MainActor @Suite struct ColorRound5DrawTests {
    @Test func aClickInTheRenameFieldPlacesTheCaretAndKeepsItOpen() throws {
        let r3 = ColorRound3DrawTests()
        let (s, model, ids) = try r3.steps()
        let atlas = try #require(GlyphAtlas())
        s.beginRename(ids[0])
        var c = Canvas(width: Float(s.size.width), height: Float(s.size.height), atlas: atlas, scale: 1)
        s.draw(&c)
        let field = try #require(s.renameRect)
        let label = try #require(model.step(ids[0])?.label)
        #expect(!label.isEmpty)
        // The pointer over the open field is the I-beam.
        let hover = HostHover()
        HostHover.$current.withValue(hover) {
            hover.beginEvent(.mouseMoved(x: Float(field.midX), y: Float(field.midY)))
            s.mouseMoved(to: CGPoint(x: field.midX, y: field.midY))
            hover.endEvent(.mouseMoved(x: Float(field.midX), y: Float(field.midY)), now: 0)
        }
        #expect(hover.cursor == .iBeam)
        // A click at the field's left end puts the caret before the first letter; the name is not committed.
        s.mouseDown(at: CGPoint(x: field.minX + 3, y: field.midY), clickCount: 1)
        s.mouseUp(at: CGPoint(x: field.minX + 3, y: field.midY))
        let open = try #require(s.renaming)
        #expect(open.field.isEditing && open.field.editor?.caret == 0 && open.field.editor?.hasSelection == false)
        _ = s.key(.character("X"), modifiers: [])
        _ = s.key(.enter, modifiers: [])
        #expect(s.renaming == nil && model.step(ids[0])?.label == "X" + label)
        // A click outside an open field still commits it.
        s.beginRename(ids[0])
        s.draw(&c)
        s.mouseDown(at: CGPoint(x: 1, y: 1), clickCount: 1)
        #expect(s.renaming == nil)
    }
}
