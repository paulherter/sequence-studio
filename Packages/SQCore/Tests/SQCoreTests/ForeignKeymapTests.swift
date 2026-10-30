import Foundation
import Testing
@testable import SQCore

@Suite struct ForeignKeymapTests {
    /// Synthetic command set with the structure of a real `.commandset` (binary plist, dict or array per command).
    static func fixture() throws -> Data {
        func k(_ ch: String, _ words: String, _ mask: Int? = nil) -> [String: Any] {
            var d: [String: Any] = ["character": ch, "characterString": ch, "modifiers": words]
            if let mask { d["modifierMask"] = mask }
            return d
        }
        let plist: [String: Any] = [
            "BladeAtPlayhead": [k("b", "command"), k("b", "")],                       // two chords
            "Cut": k("x", "command"),                                                 // single description, not an array
            "ZoomIn": [k("+", "command"), k("+", "command keypad")],                  // keypad twin collapses
            "JumpToStart": k("NSHomeFunctionKey", "function"),                        // fn flag dropped
            "NudgeLeftMany": k("NSLeftArrowFunctionKey", "option shift"),
            "ReplaceWithGap": [k("NSDeleteCharacter", "shift"), k("NSDeleteFunctionKey", "")],
            "InsertGap": [k("w", "option"), k("NSCarriageReturnCharacter", "")],      // Return: not a key of ours
            "AppendWithSelectedMedia": k("e", ""),                                    // planned (Fast Cut)
            "Quit": k("q", "command"),
            "ColorBoard-SelectNextPuck": k("", ""),                                   // no key
            "360Difference": k("6", "control option command"),                        // no equivalent
            "OnlyMask": ["character": "m", "characterString": "m", "modifierMask": 1_835_008],   // words missing: mask decides
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    @Test func readsKeyDescriptionsIntoChords() throws {
        let cmds = try FCPCommandSetReader.read(Self.fixture())
        func chords(_ id: String) -> [ForeignChord] { cmds.first { $0.sourceID == id }?.chords ?? [] }
        #expect(chords("BladeAtPlayhead") == [ForeignChord(.char("b"), .command), ForeignChord(.char("b"))])
        #expect(chords("Cut") == [ForeignChord(.char("x"), .command)])
        #expect(chords("ZoomIn") == [ForeignChord(.char("+"), .command)], "keypad twin is the same chord")
        #expect(chords("JumpToStart") == [ForeignChord(.home)], "function flag is not a modifier")
        #expect(chords("NudgeLeftMany") == [ForeignChord(.left, [.option, .shift])])
        #expect(chords("ReplaceWithGap") == [ForeignChord(.backspace, .shift), ForeignChord(.forwardDelete)])
        #expect(chords("InsertGap") == [ForeignChord(.char("w"), .option), ForeignChord(.returnKey)])
        #expect(chords("OnlyMask") == [ForeignChord(.char("m"), [.control, .option, .command])], "mask used when words are missing")
        #expect(chords("ColorBoard-SelectNextPuck").isEmpty)
        #expect(cmds.map(\.sourceID) == cmds.map(\.sourceID).sorted(), "stable order")
    }

    @Test func specialKeyNames() {
        let names: [(String, ForeignKey)] = [
            ("NSLeftArrowFunctionKey", .left), ("NSRightArrowFunctionKey", .right), ("NSUpArrowFunctionKey", .up),
            ("NSDownArrowFunctionKey", .down), ("NSEndFunctionKey", .end), ("NSPageUpFunctionKey", .pageUp),
            ("NSCarriageReturnCharacter", .returnKey), ("NSTabCharacter", .tab), ("NSDeleteCharacter", .backspace),
            ("NSProEscapeCharacter", .escape), ("NSF9FunctionKey", .function(9)), (" ", .space), ("F", .char("f")), ("ß", .char("ß")),
        ]
        for (name, key) in names { #expect(FCPCommandSetReader.key(from: name) == key, "\(name)") }
        #expect(FCPCommandSetReader.key(from: "NSSomethingNewFunctionKey") == nil)
        #expect(FCPCommandSetReader.key(from: "ab") == nil)
    }

    @Test func modifierMaskBits() {
        #expect(FCPCommandSetReader.modifiers(words: nil, mask: 131_072) == .shift)
        #expect(FCPCommandSetReader.modifiers(words: nil, mask: 262_144) == .control)
        #expect(FCPCommandSetReader.modifiers(words: nil, mask: 524_288) == .option)
        #expect(FCPCommandSetReader.modifiers(words: nil, mask: 1_048_576) == .command)
        #expect(FCPCommandSetReader.modifiers(words: "", mask: 1_048_576) == .command, "empty words fall back to the mask")
        #expect(FCPCommandSetReader.modifiers(words: "shift", mask: 1_048_576) == .shift, "non-empty words win")
        #expect(FCPCommandSetReader.modifiers(words: "", mask: 0) == [])
        #expect(FCPCommandSetReader.modifiers(words: nil, mask: 131_072 | 1_048_576) == [.shift, .command])
        #expect(FCPCommandSetReader.modifiers(words: "shift keypad function", mask: nil) == .shift)
    }

    @Test func rejectsFilesThatAreNotCommandSets() throws {
        #expect(throws: FCPCommandSetReader.ReadError.notAPropertyList) { try FCPCommandSetReader.read(Data([0xFF, 0x00, 0x13, 0x37, 0xAB])) }
        #expect(throws: FCPCommandSetReader.ReadError.notACommandSet) { try FCPCommandSetReader.read(Data("hello".utf8)) }   // a plain string plist
        let other = try PropertyListSerialization.data(fromPropertyList: ["Name": "x", "Count": 3], format: .binary, options: 0)
        #expect(throws: FCPCommandSetReader.ReadError.notACommandSet) { try FCPCommandSetReader.read(other) }
        let array = try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .binary, options: 0)
        #expect(throws: FCPCommandSetReader.ReadError.notACommandSet) { try FCPCommandSetReader.read(array) }
    }

    @Test func translateSplitsMappedPlannedSystemAndUnmapped() throws {
        let r = ForeignKeymap.translate(try FCPCommandSetReader.read(Self.fixture()))
        let mapped = Dictionary(uniqueKeysWithValues: r.mapped.map { ($0.sourceID, $0) })
        #expect(mapped["BladeAtPlayhead"]?.commandID == "addEdit")
        #expect(mapped["Cut"]?.commandID == "cut")
        #expect(mapped["JumpToStart"]?.commandID == "goToStart")
        #expect(mapped["ReplaceWithGap"]?.commandID == "delete")
        #expect(mapped["AppendWithSelectedMedia"]?.planned == true)
        #expect(mapped["Cut"]?.planned == false)
        let unmapped = Dictionary(uniqueKeysWithValues: r.unmapped.map { ($0.sourceID, $0) })
        #expect(unmapped["360Difference"]?.reason == .noEquivalent)
        #expect(unmapped["360Difference"]?.title == "360 Difference")
        #expect(unmapped["Quit"]?.reason == .system)
        #expect(unmapped["ColorBoard-SelectNextPuck"] == nil, "no key: only counted")
        #expect(r.unassigned == 1)
    }

    @Test func humanizeSplitsCamelCase() {
        #expect(ForeignKeymap.humanize("BladeAtPlayhead") == "Blade At Playhead")
        #expect(ForeignKeymap.humanize("ColorBoard-NudgePuckUp") == "Color Board: Nudge Puck Up")
        #expect(ForeignKeymap.humanize("Cut") == "Cut")
    }

    @Test func chordSpecs() {
        #expect(ForeignChord(spec: "cmd+shift+b") == ForeignChord(.char("b"), [.command, .shift]))
        #expect(ForeignChord(spec: "option+left") == ForeignChord(.left, .option))
        #expect(ForeignChord(spec: "control+=") == ForeignChord(.char("="), .control))
        #expect(ForeignChord(spec: "shift+delete") == ForeignChord(.backspace, .shift))
        #expect(ForeignChord(spec: "f9") == ForeignChord(.function(9)))
        #expect(ForeignChord(spec: "hyper+b") == nil)
        #expect(ForeignChord(spec: "") == nil)
    }

    @Test func builtInDefaultSetIsWellFormed() {
        for c in FCPDefaultSet.commands {
            #expect(!c.chords.isEmpty, "\(c.sourceID) has an unreadable spec")
            #expect(FCPCommandTable.rows[c.sourceID] != nil, "\(c.sourceID) is not in the table")
        }
        let r = ForeignKeymap.translate(FCPDefaultSet.commands)
        #expect(r.unmapped.isEmpty)
        // No two Final Cut commands share a chord in the default set.
        var seen: [ForeignChord: String] = [:]
        for c in FCPDefaultSet.commands { for ch in c.chords {
            #expect(seen[ch] == nil, "\(c.sourceID) and \(seen[ch] ?? "") share a key")
            seen[ch] = c.sourceID
        } }
    }
}
