import Foundation
import SQCore
import Testing
@testable import SQUIKit

@Suite struct KeymapTemplateTests {
    private func b(_ k: Character, _ m: KeyModifiers = []) -> KeyBinding { KeyBinding(.char(k), m) }
    private func cmd(_ id: String, _ specs: String...) -> ForeignCommand {
        ForeignCommand(sourceID: id, chords: specs.compactMap { ForeignChord(spec: $0) })
    }

    /// Synthetic command set with the structure of a real Final Cut .commandset (binary plist).
    static func fixture() throws -> Data {
        func k(_ ch: String, _ words: String) -> [String: Any] { ["character": ch, "characterString": ch, "modifiers": words] }
        let plist: [String: Any] = [
            "BladeAtPlayhead": [k("b", "command"), k("b", "")],
            "Cut": k("x", "command"),
            "JumpToStart": k("NSHomeFunctionKey", "function"),
            "InsertGap": [k("w", "option"), k("NSCarriageReturnCharacter", "")],
            "AppendWithSelectedMedia": k("e", ""),
            "Quit": k("q", "command"),
            "360Difference": k("6", "control option command"),
            "ColorBoard-SelectNextPuck": k("", ""),
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    // MARK: Table

    @Test func everyNonPlannedTableRowNamesARealCommand() {
        for (fcp, target) in FCPCommandTable.rows {
            if case .command(let id) = target { #expect(EditorCommand(id: id) != nil, "\(fcp) -> \(id) is not a command of ours") }
        }
    }

    @Test func plannedRowsAreAllFastCutCommandsAndBindOnceTheyExist() {
        let planned = FCPCommandTable.rows.filter { if case .planned = $0.value { true } else { false } }
        #expect(planned.count >= 1)
        // Rows whose command is not built yet (Lift From Spine) are reported as coming later and bind nothing.
        let r = KeymapImport.build([cmd("LiftFromSpine", "q")], base: .sqDefault, table: ["LiftFromSpine": .planned("notBuiltYet")])
        #expect(r.importedCommands == 0)
        #expect(r.unmapped.map(\.reason) == [.plannedFeature])
        #expect(r.map.entries == CommandMap.sqDefault.entries, "an unbuilt command changes nothing")
        // The same row pointing at a command that exists binds it, with no other change.
        let r2 = KeymapImport.build([cmd("AppendWithSelectedMedia", "e")], base: .sqDefault, table: ["AppendWithSelectedMedia": .planned("quickExport")])
        #expect(r2.importedCommands == 1)
        #expect(r2.map.binding(for: .quickExport) == b("e"))
    }

    // MARK: Chords

    @Test func chordsBecomeOurKeyBindings() {
        #expect(KeyBinding(ForeignChord(spec: "cmd+shift+b")!) == b("b", [.command, .shift]))
        #expect(KeyBinding(ForeignChord(spec: "option+left")!) == KeyBinding(.left, .option))
        #expect(KeyBinding(ForeignChord(spec: "shift+delete")!) == KeyBinding(.delete, .shift))
        #expect(KeyBinding(ForeignChord(spec: "home")!) == KeyBinding(.home))
        #expect(KeyBinding(ForeignChord(spec: "space")!) == KeyBinding(.space))
        #expect(KeyBinding(ForeignChord(spec: "f9")!) == KeyBinding(.function(9)))
        #expect(KeyBinding(ForeignChord(spec: "control+=")!) == b("=", .control))
        for unsupported in ["tab", "esc"] { #expect(KeyBinding(ForeignChord(spec: unsupported)!) == nil, "\(unsupported)") }
    }

    @Test func unsupportedAndReservedKeysAreReportedNotBound() {
        let r = KeymapImport.build([cmd("InsertMedia", "w", "tab"), cmd("Cut", "cmd+q")], base: .sqDefault)
        #expect(r.map.binding(for: .insert) == b("w"))
        #expect(r.skippedKeys.count == 2)
        #expect(r.skippedKeys.contains { $0.message.contains("Tab") })
        #expect(r.skippedKeys.contains { $0.message.contains("reserved") })
        #expect(r.map.command(for: b("q", .command), focus: nil) == nil)
    }

    @Test func returnAndForwardDeleteAreBindable() {
        #expect(KeyBinding(ForeignChord(spec: "return")!) == KeyBinding(.returnKey))
        #expect(KeyBinding(ForeignChord(spec: "shift+fdelete")!) == KeyBinding(.forwardDelete, .shift))
        let r = KeymapImport.build([cmd("InsertMedia", "return"), cmd("Delete", "fdelete")], base: .sqDefault)
        #expect(r.map.binding(for: .insert) == KeyBinding(.returnKey))
        #expect(r.map.command(for: KeyBinding(.forwardDelete), focus: .timeline) == .rippleDelete)
        #expect(r.skippedKeys.isEmpty)
        for k in [Key.returnKey, .forwardDelete] { #expect(Key(code: k.code) == k) }
        #expect(PhysicalKeys.codes[36] == .returnKey && PhysicalKeys.codes[76] == .returnKey)
        #expect(PhysicalKeys.codes[117] == .forwardDelete && PhysicalKeys.codes[51] == .delete)
    }

    @Test func finalCutKeyCommandsOurModelHas() {
        let r = KeymapImport.build([cmd("JumpForward10Frames", "shift+right"), cmd("PlayToOut", "option+shift+o"),
                                    cmd("NextKeyframe", "option+k"), cmd("PreviousKeyframe", "option+j"),
                                    cmd("Solo", "option+s"), cmd("DetachAudio", "control+shift+s"),
                                    cmd("TrimSelection", "option+x")], base: .sqDefault)
        #expect(r.unmapped.isEmpty)
        #expect(r.map.command(for: KeyBinding(.right, .shift), focus: nil) == .stepForward10)
        #expect(r.map.command(for: b("o", [.option, .shift]), focus: nil) == .playToOut)
        #expect(r.map.command(for: b("s", .option), focus: .timeline) == .solo)
        #expect(r.map.command(for: b("s", [.control, .shift]), focus: .timeline) == .unlink)
        #expect(r.map.command(for: b("x", .option), focus: nil) == .trimToRange)
        #expect(r.map.command(for: b("k", .option), focus: nil) == .nextKeyframe)
        #expect(r.map.command(for: b("j", .option), focus: nil) == .previousKeyframe)
        #expect(r.map.duplicates.isEmpty)
    }

    /// The path the app takes: the user's real keyboard layout. Properties that hold on any layout.
    @Test func realLayoutImportBindsTheKeyThatTypesTheCharacter() {
        let layout = KeyCharacterResolver.currentLayout()
        let r = KeymapImport.build([cmd("BladeAtPlayhead", "cmd+b"), cmd("JumpToNextFrame", "right"), cmd("PlayPause", "space")],
                                   base: .sqDefault, resolver: layout)
        let want = layout.resolve("b")
        #expect(want != nil)
        if let want {
            var m: KeyModifiers = [.command]
            if want.needsShift { m.insert(.shift) }
            #expect(r.map.binding(for: .addEdit) == KeyBinding(want.key, m))
        }
        #expect(r.map.binding(for: .stepForward) == KeyBinding(.right))
        #expect(r.map.binding(for: .playPause) == KeyBinding(.space))
        #expect(r.skippedKeys.isEmpty)
        #expect(r.map.duplicates.isEmpty)
    }

    // MARK: Conflict rules

    @Test func importedBindingWinsAndDisplacedCommandLosesTheKey() {
        // sqDefault: B = Ripple tool (global). Final Cut: B = Blade tool.
        #expect(CommandMap.sqDefault.command(for: b("b"), focus: nil) == .tool(.ripple))
        let r = KeymapImport.build([cmd("SelectToolBlade", "b")], base: .sqDefault)
        #expect(r.map.command(for: b("b"), focus: nil) == .tool(.razor))
        #expect(r.map.binding(for: .tool(.ripple)) == nil, "the displaced tool has no key now")
        #expect(r.map.binding(for: .tool(.razor)) == b("b"), "the old C key of Blade is gone: the file defines it")
        #expect(r.conflicts.contains { $0.kind == .displaced && $0.message.contains("Ripple Tool") })
        #expect(r.map.duplicates.isEmpty)
    }

    @Test func unrelatedDefaultsSurvive() {
        let r = KeymapImport.build([cmd("SelectToolBlade", "b")], base: .sqDefault)
        #expect(r.map.command(for: b("s", .command), focus: nil) == .save)
        #expect(r.map.command(for: b("z", .command), focus: nil) == .undo)
    }

    @Test func globalImportTakesTheKeyFromPanelBindings() {
        // Timeline: S = snapping. Importing a global command on S must not hide behind the timeline binding.
        let r = KeymapImport.build([cmd("SelectToolHand", "s")], base: .sqDefault)
        #expect(r.map.command(for: b("s"), focus: .timeline) == .tool(.hand))
        #expect(r.map.command(for: b("s"), focus: nil) == .tool(.hand))
    }

    @Test func twoImportedCommandsOnOneKeyKeepTheFirst() {
        let r = KeymapImport.build([cmd("SelectToolBlade", "x"), cmd("SelectToolHand", "x")], base: .sqDefault)
        #expect(r.map.command(for: b("x"), focus: nil) == .tool(.razor))
        #expect(r.conflicts.contains { $0.kind == .sharedKey })
        #expect(r.map.duplicates.isEmpty)
    }

    @Test func panelBindingOverlappingGlobalImportIsNoted() {
        // The real-world case: Blade at Playhead (Timeline) and the Blade tool both on B.
        let r = KeymapImport.build([cmd("BladeAtPlayhead", "b"), cmd("SelectToolBlade", "b")], base: .sqDefault)
        #expect(r.map.command(for: b("b"), focus: .timeline) == .addEdit)
        #expect(r.map.command(for: b("b"), focus: .programMonitor) == .tool(.razor))
        #expect(r.conflicts.contains { $0.kind == .overlap })
    }

    @Test func sameCommandOnTwoSourceIDsIsNotAConflict() {
        let r = KeymapImport.build([cmd("Up", "up"), cmd("PreviousEdit", "up")], base: .sqDefault)
        #expect(r.conflicts.isEmpty)
        #expect(r.importedBindings >= 1)
    }

    @Test func summaryAndUnmappedList() throws {
        let data = try Self.fixture()
        let r = KeymapImport.build(try FCPCommandSetReader.read(data))
        #expect(r.importedCommands > 0)
        let names = r.unmapped.map { KeymapImport.title(of: $0) }
        #expect(names.contains("360 Difference"))
        #expect(names.contains("Quit (macOS handles it)"))
        #expect(r.summary == "\(r.importedCommands) imported, \(r.unmapped.count) have no equivalent in Sequence Studio, \(r.unassigned) unassigned in the file")
        #expect(r.unassigned == 1, "an empty key is unassigned, not a failure")
        #expect(r.map.duplicates.isEmpty)
    }

    // MARK: German layout and override

    /// A German-style layout: Trim Start lives on the "ß" key (our "-" position), "ü" on "[" with Shift for "+" on "]".
    private var german: KeyCharacterResolver {
        .table(["ß": .init(key: .char("-"), needsShift: false), "ü": .init(key: .char("["), needsShift: false),
                "+": .init(key: .char("]"), needsShift: false), "z": .init(key: .char("y"), needsShift: false),
                "y": .init(key: .char("z"), needsShift: false)])
    }

    @Test func typedCharactersResolveThroughTheLayout() {
        let r = KeymapImport.build([cmd("TrimStart", "ß"), cmd("TrimEnd", "ü")], base: .sqDefault, resolver: german)
        #expect(r.map.command(for: b("-"), focus: .timeline) == .rippleTrimPrevious)
        #expect(r.map.command(for: b("["), focus: .timeline) == .rippleTrimNext)
        #expect(r.skippedKeys.isEmpty)
        // A character neither the layout nor the US fallback knows is reported, not bound.
        let bad = KeymapImport.build([cmd("TrimStart", "ß")], base: .sqDefault, resolver: .us)
        #expect(bad.skippedKeys.count == 1)
    }

    @Test func shiftedSymbolsOnTheUSLayoutAddShift() {
        #expect(KeyBinding(ForeignChord(.char("+")), resolver: .us) == b("=", .shift))
    }

    @Test func importedKeyOverridesDefaultAndReleasesTheCommandsOwnDefault() {
        let old = CommandMap.sqDefault.binding(for: .rippleTrimPrevious)
        let r = KeymapImport.build([cmd("TrimStart", "ß")], base: .sqDefault, resolver: german)
        #expect(r.map.binding(for: .rippleTrimPrevious) == b("-"))
        if let old, old != b("-") { #expect(r.map.command(for: old, focus: .timeline) != .rippleTrimPrevious) }
        #expect(r.map.duplicates.isEmpty)
    }

    @Test func endToEndSyntheticSetPutsTrimStartOnAnotherKey() throws {
        func k(_ ch: String, _ words: String) -> [String: Any] { ["character": ch, "characterString": ch, "modifiers": words] }
        let plist: [String: Any] = ["TrimStart": k("ß", ""), "TrimEnd": k("ü", ""), "Cut": k("", "")]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let r = KeymapImport.build(try FCPCommandSetReader.read(data), resolver: german)
        #expect(r.importedCommands == 2)
        #expect(r.unassigned == 1)
        #expect(r.map.command(for: b("-"), focus: .timeline) == .rippleTrimPrevious)
    }

    @Test func tableCoversTheEditingCommands() {
        for id in ["TrimStart", "TrimEnd", "BladeAtPlayhead", "SelectToolBlade", "SelectToolTrim", "ExtendEdit", "Delete"] {
            #expect(FCPCommandTable.rows[id] != nil, Comment(rawValue: id))
        }
    }

    // MARK: Final Cut style preset

    @Test func finalCutPresetIsConsistent() {
        let m = CommandMap.finalCutDefault
        #expect(m.duplicates.isEmpty)
        #expect(m.command(for: b("b"), focus: nil) == .tool(.razor))
        #expect(m.command(for: b("b", .command), focus: .timeline) == .addEdit)
        #expect(m.command(for: b("w"), focus: nil) == .insert)
        #expect(m.command(for: b("d"), focus: nil) == .overwrite)
        #expect(m.command(for: b("n"), focus: .timeline) == .toggleSnapping)
        #expect(m.command(for: b("z", .command), focus: nil) == .undo)
        #expect(m.command(for: KeyBinding(.space), focus: nil) == .playPause)
        // Our default Premiere-style keys that Final Cut gives to something else are gone, the rest stays.
        #expect(m.command(for: b("s", .command), focus: nil) == .save)
        for p in KeymapPreset.allCases { #expect(p.map.duplicates.isEmpty, "\(p)") }
    }

    @Test func finalCutPresetKeyAudit() {
        let m = CommandMap.finalCutDefault
        #expect(m.command(for: b("t"), focus: .timeline) == .tool(.ripple))
        #expect(m.command(for: b("a"), focus: .timeline) == .tool(.selection))
        #expect(m.command(for: b("c"), focus: .timeline) == .selectClipAtPlayhead)
        #expect(m.command(for: b("x"), focus: .timeline) == .markClip)
        #expect(m.command(for: b("g", .option), focus: .timeline) == .group)
        #expect(m.command(for: b("g", [.command, .shift]), focus: .timeline) == .ungroup)
        #expect(m.command(for: b("v", [.command, .shift]), focus: .timeline) == .pasteAttached)
        #expect(m.command(for: b("h", .shift), focus: .timeline) == .insertFrameHold)
        #expect(m.command(for: b("j", .command), focus: nil) == .sequenceSettings)
        #expect(m.duplicates.isEmpty)
    }

    // MARK: Own sets

    @Test func customSetLifecycle() {
        var c = KeymapConfig.standard
        let imported = KeymapImport.build([cmd("SelectToolBlade", "b")]).map
        let set = c.addSet(name: "Tester", map: imported)
        #expect(c.activeSetID == set.id)
        #expect(c.map.command(for: b("b"), focus: nil) == .tool(.razor))
        #expect(c.baseTitle == "Tester")
        // An edit on top of the set is a diff over it, and switching away drops it.
        c.set(map: Keymap.unbind(.init(scope: .global, binding: b("b"), command: .tool(.razor)), in: c.map))
        #expect(c.isModified)
        #expect(c.map.command(for: b("b"), focus: nil) == nil)
        c.resetOverrides()
        #expect(c.map.command(for: b("b"), focus: nil) == .tool(.razor))
        c.switchPreset(.finalCut)
        #expect(c.activeSet == nil && c.customSets.count == 1, "switching keeps the saved set")
        c.switchToSet(set.id)
        #expect(c.activeSet?.name == "Tester")
        c.renameSet(set.id, to: "Optimum")
        #expect(c.baseTitle == "Optimum")
        c.deleteSet(set.id)
        #expect(c.customSets.isEmpty && c.activeSet == nil && c.preset == .sq)
    }

    @Test func namesStayUnique() {
        var c = KeymapConfig.standard
        c.addSet(name: "Mine", map: .sqDefault)
        c.addSet(name: "Mine", map: .sqDefault)
        c.addSet(name: "Final Cut style", map: .sqDefault)
        c.addSet(name: "  ", map: .sqDefault)
        #expect(c.customSets.map(\.name) == ["Mine", "Mine 2", "Final Cut style 2", "My Shortcuts"])
    }

    @Test func setSurvivesTheStoreAndOldConfigsStillLoad() throws {
        let name = "sq.test.keymaptemplates.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let store = KeymapStore(defaults: d)
        var c = KeymapConfig.standard
        c.addSet(name: "Tester", map: CommandMap.finalCutDefault)
        store.save(c)
        let back = store.load()
        #expect(back == c)
        #expect(back.map.entries == CommandMap.finalCutDefault.entries)
        // A config written before sets existed.
        d.set(Data(#"{"preset":"premiere","overrides":[]}"#.utf8), forKey: KeymapStore.defaultsKey)
        let old = store.load()
        #expect(old.preset == .premiere && old.customSets.isEmpty && old.activeSetID == nil)
        // An unknown preset from a newer build falls back to the standard set instead of losing the sets.
        d.set(Data(#"{"preset":"future","overrides":[]}"#.utf8), forKey: KeymapStore.defaultsKey)
        #expect(store.load() == .standard)
    }

    @Test func exportFormatRoundTrips() throws {
        let set = KeymapSet(name: "Tester", map: CommandMap.finalCutDefault)
        let back = try #require(KeymapSet(exported: set.exportData()))
        #expect(back.name == "Tester")
        #expect(back.map.entries == set.map.entries)
        #expect(back.id != set.id, "an imported file is a new set")
        #expect(KeymapSet(exported: Data(#"{"format":"other"}"#.utf8)) == nil)
        #expect(KeymapSet(exported: Data("nope".utf8)) == nil)
    }
}
