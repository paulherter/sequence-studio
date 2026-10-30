import Foundation
import Testing
@testable import SQCore

private struct Shadow: Codable, Equatable { var blur: Double; var opacity: Double }
private struct Style: Codable, Equatable {
    var size: Double
    var font: String
    var shadow: Shadow?
    var tags: [String] = []
}

@Suite struct MultiClipEditTests {
    // MARK: Common value

    @Test func commonValueIsTheSharedOneOrNil() {
        #expect(MultiValue.common([2.0, 2.0, 2.0]) == 2.0)
        #expect(MultiValue.common([2.0, 3.0]) == nil)
        #expect(MultiValue.common([Double]()) == nil)
        #expect(MultiValue.common(["a"]) == "a")
    }

    // MARK: Matching effects across clips

    private func clip(_ kinds: [String]) -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        c.effects = kinds.map { ClipEffect(kind: $0) }
        return c
    }

    @Test func effectsMatchByKindAndOccurrence() {
        let a = clip(["blur", "crop", "blur"]), b = clip(["crop", "blur", "tint", "blur"])
        #expect(b.matchingEffectID(for: a.effects[0].id, in: a) == b.effects[1].id)
        #expect(b.matchingEffectID(for: a.effects[2].id, in: a) == b.effects[3].id)
        #expect(b.matchingEffectID(for: a.effects[1].id, in: a) == b.effects[0].id)
        let c = clip(["blur"])
        #expect(c.matchingEffectID(for: a.effects[2].id, in: a) == nil)     // only one blur there
        #expect(c.matchingEffectID(for: UUID(), in: a) == nil)
    }

    // MARK: Carrying a style edit to other clips

    @Test func carryChangesOnlyTheEditedField() throws {
        let old = Style(size: 40, font: "A", shadow: Shadow(blur: 2, opacity: 0.5))
        var new = old; new.size = 60
        let peer = Style(size: 20, font: "B", shadow: nil)
        let out = try CodableMerge.carry(from: old, to: new, into: peer)
        #expect(out == Style(size: 60, font: "B", shadow: nil))
    }

    @Test func carryNestedFieldKeepsPeerSiblings() throws {
        let old = Style(size: 40, font: "A", shadow: Shadow(blur: 2, opacity: 0.5))
        var new = old; new.shadow?.blur = 9
        let peer = Style(size: 20, font: "B", shadow: Shadow(blur: 1, opacity: 0.9))
        let out = try CodableMerge.carry(from: old, to: new, into: peer)
        #expect(out.shadow == Shadow(blur: 9, opacity: 0.9))
    }

    @Test func carryNestedFieldIntoPeerWithoutTheGroupTakesTheWholeGroup() throws {
        let old = Style(size: 40, font: "A", shadow: Shadow(blur: 2, opacity: 0.5))
        var new = old; new.shadow?.blur = 9
        let peer = Style(size: 20, font: "B", shadow: nil)
        let out = try CodableMerge.carry(from: old, to: new, into: peer)
        #expect(out.shadow == Shadow(blur: 9, opacity: 0.5))
    }

    @Test func carrySwitchingAGroupOffAndOn() throws {
        let on = Style(size: 40, font: "A", shadow: Shadow(blur: 2, opacity: 0.5))
        var off = on; off.shadow = nil
        let peer = Style(size: 20, font: "B", shadow: Shadow(blur: 7, opacity: 0.1))
        #expect(try CodableMerge.carry(from: on, to: off, into: peer).shadow == nil)
        let bare = Style(size: 20, font: "B", shadow: nil)
        #expect(try CodableMerge.carry(from: off, to: on, into: bare).shadow == Shadow(blur: 2, opacity: 0.5))
    }

    @Test func carryReplacesArraysWhole() throws {
        let old = Style(size: 1, font: "A", shadow: nil, tags: ["x"])
        var new = old; new.tags = ["x", "y"]
        let peer = Style(size: 2, font: "B", shadow: nil, tags: ["z"])
        #expect(try CodableMerge.carry(from: old, to: new, into: peer).tags == ["x", "y"])
    }

    @Test func noChangeLeavesPeerAlone() throws {
        let s = Style(size: 1, font: "A", shadow: nil)
        let peer = Style(size: 2, font: "B", shadow: Shadow(blur: 1, opacity: 1))
        #expect(try CodableMerge.carry(from: s, to: s, into: peer) == peer)
    }

    // MARK: Which fields differ

    @Test func differingPathsListLeavesAndPresence() throws {
        let a = Style(size: 40, font: "A", shadow: Shadow(blur: 2, opacity: 0.5))
        let b = Style(size: 40, font: "B", shadow: Shadow(blur: 3, opacity: 0.5))
        let c = Style(size: 40, font: "A", shadow: nil)
        #expect(try CodableMerge.differingPaths([a, b]) == ["font", "shadow.blur"])
        #expect(try CodableMerge.differingPaths([a, c]) == ["shadow"])
        #expect(try CodableMerge.differingPaths([a, a]).isEmpty)
        #expect(try CodableMerge.differingPaths([a]).isEmpty)
    }

    // MARK: Forcing a field the edit did not change (a mixed field set to the shown clip's own value)

    @Test func forcedFieldIsCopiedEvenWhenUnchanged() throws {
        let s = Style(size: 40, font: "A", shadow: nil)
        let peer = Style(size: 20, font: "B", shadow: nil)
        let out = try CodableMerge.carry(from: s, to: s, into: peer, forcing: ["size"])
        #expect(out == Style(size: 40, font: "B", shadow: nil))
    }

    @Test func forcedGroupIsCopiedWholeOrRemoved() throws {
        let on = Style(size: 1, font: "A", shadow: Shadow(blur: 2, opacity: 0.5))
        let bare = Style(size: 2, font: "B", shadow: nil)
        #expect(try CodableMerge.carry(from: on, to: on, into: bare, forcing: ["shadow"]).shadow == Shadow(blur: 2, opacity: 0.5))
        var off = on; off.shadow = nil
        let withShadow = Style(size: 2, font: "B", shadow: Shadow(blur: 7, opacity: 1))
        #expect(try CodableMerge.carry(from: off, to: off, into: withShadow, forcing: ["shadow"]).shadow == nil)
    }

    @Test func forcedNestedFieldKeepsPeerSiblings() throws {
        let s = Style(size: 1, font: "A", shadow: Shadow(blur: 2, opacity: 0.5))
        let peer = Style(size: 2, font: "B", shadow: Shadow(blur: 9, opacity: 0.1))
        let out = try CodableMerge.carry(from: s, to: s, into: peer, forcing: ["shadow.blur"])
        #expect(out.shadow == Shadow(blur: 2, opacity: 0.1))
        // A nested field into a peer without the group: nothing to set it in, the peer stays.
        let bare = Style(size: 2, font: "B", shadow: nil)
        #expect(try CodableMerge.carry(from: s, to: s, into: bare, forcing: ["shadow.blur"]) == bare)
    }
}
