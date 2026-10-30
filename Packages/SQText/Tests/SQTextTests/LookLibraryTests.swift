import Foundation
import Testing
import SQCore
@testable import SQText

private let red = TextStyle(fontName: "Menlo", size: 50, weight: .bold, color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))
private var big: TextStyle { var s = red; s.size = 90; return s }
private let fade = KeyframeTemplate(tracks: [
    AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 2), 1, .linear)]),
], duration: Time(1, 2))

@Suite struct LookLibraryTests {
    // MARK: One API: list, save as new, update, rename, delete

    @Test func builtInsAreReadOnlyAndListedFirst() {
        var l = LookLibrary()
        let b = LookLibrary.builtIns
        #expect(b.count == 9 && Set(b.map(\.id)).count == 9 && b.allSatisfy(\.isBuiltIn))
        let id = l.add(name: " Mine ", style: red)!
        #expect(l.looks.map(\.id) == b.map(\.id) + [id])
        #expect(l.look(id)?.name == "Mine" && l.look(id)?.isBuiltIn == false)
        let r1 = l.rename(b[0].id, to: "X"), r2 = l.delete(b[0].id), r3 = l.update(b[0].id, style: red)
        #expect(!r1 && !r2 && !r3)
        let blank = l.add(name: "  ", style: red)
        let taken1 = l.add(name: "Taken", style: red, id: b[0].id), taken2 = l.add(name: "Taken", style: red, id: id)
        #expect(blank == nil && taken1 == nil && taken2 == nil)
    }

    @Test func updateKeepsIdAndNameAndTheRestOfTheLook() {
        var l = LookLibrary()
        let id = l.add(name: "A", style: red, animation: fade, karaoke: KaraokeStyle(red: 1, green: 0, blue: 0, keepSpoken: true))!
        let u1 = l.update(id, style: big)
        #expect(u1)
        #expect(l.look(id)?.style == big && l.look(id)?.animation == fade && l.look(id)?.karaoke != nil)
        let u2 = l.update(id) { $0.id = "other"; $0.name = "Other"; $0.animation = nil }
        #expect(u2)
        #expect(l.look(id)?.name == "A" && l.look(id)?.animation == nil && l.look("other") == nil)
        let renamed = l.rename(id, to: " B ")
        #expect(renamed && l.look(id)?.name == "B")
        let d1 = l.delete(id), d2 = l.delete(id)
        #expect(d1 && !d2 && l.look(id) == nil)
    }

    @Test func duplicateCopiesEverything() {
        var l = LookLibrary()
        let id = l.add(name: "A", style: red, animation: fade)!
        let copy = l.duplicate(id)!
        #expect(l.look(copy)?.name == "A Copy" && l.look(copy)?.values == l.look(id)?.values)
        let again = l.duplicate(copy)!
        #expect(l.look(again)?.name == "A Copy 2")
    }

    // MARK: Merging the old stores

    @Test func identicalLooksMergeAndTheOldIdStillResolves() {
        var l = LookLibrary()
        let kept = l.add(name: "Caption Look 1", style: red, animation: fade)!
        let map = l.merge([Look(id: "user-1", name: "Red", style: red, animation: fade),
                           Look(id: "user-2", name: "Big", style: big)])
        #expect(l.user.count == 2)
        #expect(map == ["user-1": kept, "user-2": "user-2"])
        #expect(l.look("user-1")?.id == kept && l.look("user-1")?.name == "Caption Look 1")
        #expect(l.aliases == ["user-1": kept])
        // Deleting the kept Look removes its aliases with it.
        let deleted = l.delete(kept)
        #expect(deleted)
        #expect(l.look("user-1") == nil && l.aliases.isEmpty)
    }

    /// An id that was merged into another Look stands for that Look: rename and update change it, delete only drops
    /// the old id (the Look may be in use under its own id).
    @Test func aMergedIdActsOnTheLookItResolvesTo() {
        var l = LookLibrary()
        let kept = l.add(name: "Kept", style: red, animation: fade)!
        _ = l.merge([Look(id: "old", name: "Red", style: red, animation: fade)])
        let renamed = l.rename("old", to: "New Name")
        #expect(renamed && l.look(kept)?.name == "New Name")
        let updated = l.update("old", style: big)
        #expect(updated && l.look(kept)?.style == big)
        let deleted = l.delete("old")
        #expect(deleted && l.look(kept) != nil && l.look("old") == nil && l.aliases.isEmpty)
        let again = l.delete("old")
        #expect(!again && l.user.count == 1)
        // A blank name adds nothing.
        #expect(l.add(name: "  ", style: red) == nil && l.user.count == 1)
    }

    @Test func noAnimationIsTheSameStoredEitherWay() {
        var l = LookLibrary()
        let a = l.add(name: "A", style: red, animation: KeyframeTemplate.none)!
        l.merge([Look(id: "t", name: "B", style: red)])
        #expect(l.user.count == 1 && l.look("t")?.id == a)
        // A Look with a real animation is a different Look.
        l.merge([Look(id: "u", name: "C", style: red, animation: fade)])
        #expect(l.user.count == 2)
    }

    @Test func nameClashesGetANumberAndIdClashesANewId() {
        var l = LookLibrary()
        let first = l.add(name: "Brand", style: red, id: "x")!
        let map = l.merge([Look(id: "x", name: "Brand", style: big),
                           Look(id: "y", name: "Brand", style: TextStyle()),
                           Look(id: "z", name: "Title", style: big.with { $0.size = 91 }),
                           Look(id: "x", name: "Brand", style: red)])
        #expect(l.user.map(\.name) == ["Brand", "Brand 2", "Brand 3", "Title 2"])
        #expect(map["y"] == "y" && map["z"] == "z")
        #expect(l.look(first)?.style == red)
        #expect(Set(l.user.map(\.id)).count == 4)
        // Merging the same Looks again changes nothing (a second migration run is harmless).
        let before = l
        l.merge(before.user)
        #expect(l == before)
    }

    @Test func libraryRoundTripsAndRefusesANewerFile() throws {
        var l = LookLibrary()
        l.add(name: "A", style: red, animation: fade, captionSegmentation: Data("{}".utf8))
        l.merge([Look(id: "old", name: "Same", style: red, animation: fade, captionSegmentation: Data("{}".utf8))])
        let data = try JSONEncoder().encode(l)
        #expect(try JSONDecoder().decode(LookLibrary.self, from: data) == l)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = LookLibrary.formatVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: CaptionLookError.newerVersion) { _ = try JSONDecoder().decode(LookLibrary.self, from: newer) }
    }

    // MARK: Edited state

    @Test func editedStateComparesTheItemWithItsLook() {
        var l = LookLibrary()
        let styleOnly = l.add(name: "S", style: red)!
        let animated = l.add(name: "A", style: big, animation: fade)!
        #expect(l.state(style: red, appliedLookID: nil) == .none)
        #expect(l.state(style: red, appliedLookID: "gone") == .none)
        #expect(l.state(style: red, appliedLookID: styleOnly) == .applied(styleOnly))
        // A Look without an animation does not care which animation the item has.
        #expect(l.state(style: red, animation: fade, appliedLookID: styleOnly) == .applied(styleOnly))
        #expect(l.state(style: big, appliedLookID: styleOnly) == .edited(styleOnly))
        #expect(l.state(style: big, animation: fade, appliedLookID: animated) == .applied(animated))
        #expect(l.state(style: big, animation: nil, appliedLookID: animated) == .edited(animated))
        #expect(l.state(style: red, animation: fade, appliedLookID: animated).isEdited)
        // Built-in Looks work the same; an alias reports the Look it resolves to.
        let b = LookLibrary.builtIns[0]
        #expect(l.state(style: b.style, appliedLookID: b.id) == .applied(b.id))
        l.merge([Look(id: "alias", name: "S again", style: red)])
        #expect(l.state(style: red, appliedLookID: "alias") == .applied(styleOnly))
    }

    // MARK: Project Looks (the kit)

    @Test func kitLooksKeepTheOldPayloadWhereItFits() throws {
        var kit = StyleKit()
        try kit.setLook(Look(id: "cap", name: "Caption", style: red, animation: fade))
        try kit.setLook(Look(id: "plain", name: "Plain", style: big))
        try kit.setLook(Look(id: "full", name: "Full", style: red, animation: fade,
                             karaoke: KaraokeStyle(red: 1, green: 1, blue: 0, keepSpoken: false), captionSegmentation: Data("{}".utf8)))
        #expect(kit.looks["cap"]?.payloadVersion == 1)
        #expect(kit.looks["plain"]?.payloadVersion == 2 && kit.looks["full"]?.payloadVersion == 2)
        // Version 1 is exactly what older builds wrote and read.
        let old = try CaptionLook(payload: kit.looks["cap"]!.payload, version: 1)
        #expect(old == CaptionLook(style: red, animation: fade))
        #expect(kit.projectLooks().map(\.id) == ["cap", "full", "plain"])
        #expect(kit.look("full")?.karaoke?.green == 1 && kit.look("plain")?.animation == nil)
        // Captions render every readable Look, whatever its payload version.
        let lib = CaptionPresetLibrary.base.applying(kit)
        #expect(lib.style(for: CaptionLook.styleID(for: StyleKit.lookID("plain"))) == big)
        #expect(lib.animation(for: CaptionLook.animationID(for: StyleKit.lookID("full"))) == fade)
    }

    @Test func aKitFromAnOlderBuildListsItsLooksUnchanged() throws {
        var kit = StyleKit()
        try kit.addLook(CaptionLook(style: red, animation: fade), id: "brand", name: "Brand")
        let before = kit
        let looks = kit.projectLooks()
        #expect(looks == [Look(id: "brand", name: "Brand", style: red, animation: fade)])
        try kit.setLook(looks[0])
        #expect(try CaptionLook(payload: kit.looks["brand"]!.payload, version: 1) == CaptionLook(style: red, animation: fade))
        #expect(kit.looks["brand"]?.payloadVersion == before.looks["brand"]?.payloadVersion)
        // A payload from a newer build is skipped, not misread.
        kit.looks["future"] = StyleKitLook(name: "Future", payload: Data("{}".utf8), payloadVersion: 99)
        #expect(kit.projectLooks().map(\.id) == ["brand"])
    }

    @Test func textTemplateRemembersItsLook() throws {
        var t = TextTemplate(name: "T", text: "Hi", style: red)
        #expect(!String(decoding: try t.encoded(), as: UTF8.self).contains("lookID"))
        t.lookID = "title"
        let back = try JSONDecoder().decode(TextTemplate.self, from: try t.encoded())
        #expect(back == t && back.lookID == "title")
    }
}

private extension TextStyle {
    func with(_ change: (inout TextStyle) -> Void) -> TextStyle { var s = self; change(&s); return s }
}
