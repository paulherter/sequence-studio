import Foundation
import Testing
@testable import SQEditorSession
@testable import SQUIKit

@Suite struct KeymapStoreTests {
    private func b(_ k: Character, _ m: KeyModifiers = []) -> KeyBinding { KeyBinding(.char(k), m) }
    private let sq = CommandMap.sqDefault

    private func defaults() -> UserDefaults {
        let name = "sq.test.keymap.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Ids and codes

    @Test func commandIDsRoundTrip() {
        for c in CommandCatalog.audited(.premiereDefault) {
            #expect(EditorCommand(id: c.id) == c, "\(c.id)")
        }
        #expect(EditorCommand.tool(.razor).id == "tool.razor")
        #expect(EditorCommand(id: "nonsense") == nil)
    }

    @Test func keyCodesRoundTrip() {
        for k in [Key.char("c"), .char("`"), .space, .left, .right, .up, .down, .home, .end, .delete, .function(9), .function(12)] {
            #expect(Key(code: k.code) == k)
        }
        #expect(Key(code: "bogus") == nil)
    }

    // MARK: Defaults

    @Test func sqDefaultHasQAndEOnRippleTrimAndNoDuplicates() {
        #expect(sq.command(for: b("q"), focus: .timeline) == .rippleTrimPrevious)
        #expect(sq.command(for: b("e"), focus: .timeline) == .rippleTrimNext)
        #expect(sq.command(for: b("w"), focus: .timeline) == .extendEdit)
        #expect(sq.command(for: b("c"), focus: .timeline) == .tool(.razor))
        #expect(sq.command(for: b("l"), focus: .timeline) == .shuttleForward)
        #expect(sq.command(for: b("k"), focus: .timeline) == .shuttleStop)
        #expect(sq.command(for: b("j"), focus: .timeline) == .shuttleReverse)
        #expect(sq.duplicates.isEmpty)
        // Premiere stays as it was.
        #expect(CommandMap.premiereDefault.command(for: b("w"), focus: .timeline) == .rippleTrimNext)
        #expect(CommandMap.premiereDefault.command(for: b("e"), focus: .timeline) == .extendEdit)
    }

    @Test func quickExportHasAFreeShortcutInBothSets() {
        let key = b("m", [.command, .option])
        for map in [CommandMap.sqDefault, CommandMap.premiereDefault] {
            #expect(map.binding(for: .quickExport) == key)
            #expect(map.entries.filter { $0.binding == key }.count == 1)
            #expect(map.duplicates.isEmpty)
        }
        #expect(CommandSupport.isSupported(.quickExport))
        #expect(EditorMenus.file.commands.contains(.quickExport))
    }

    @Test func sqDefaultIsPremiereMinusTheTwoSwapsAndTheShiftTTrade() {
        let d = Keymap.diff(base: .premiereDefault, edited: sq)
        #expect(d.count == 7)      // 2 swaps (E / W) + Shift+T: Keyword in, Trim mode to Ctrl+Shift+T (5 entries)
    }

    // MARK: Diff and merge

    @Test func emptyDiffIsTheBase() {
        let m = Keymap.apply([], to: sq)
        #expect(m.entries == sq.entries)
        #expect(Keymap.diff(base: sq, edited: sq).isEmpty)
    }

    @Test func diffThenApplyReproducesTheEditedMap() throws {
        // Razor from C to X, Hand loses H.
        var m = try #require(Keymap.assign(.tool(.razor), to: b("x"), scope: .global, in: sq,
                                           moving: .init(scope: .global, binding: b("c"), command: .tool(.razor))))
        m = Keymap.unbind(.init(scope: .global, binding: b("h"), command: .tool(.hand)), in: m)
        let d = Keymap.diff(base: sq, edited: m)
        let rebuilt = Keymap.apply(d, to: sq)
        #expect(rebuilt.command(for: b("x"), focus: .timeline) == .tool(.razor))
        #expect(rebuilt.command(for: b("c"), focus: .timeline) == nil)
        #expect(rebuilt.command(for: b("h"), focus: .timeline) == nil)
        #expect(Set(rebuilt.entries) == Set(m.entries))
        // X was Cut-with-Cmd only; the plain X stays Mark Clip? No: plain X is markClip in the base, so it was displaced.
        #expect(rebuilt.command(for: b("x", .command), focus: nil) == .cut)
    }

    @Test func unknownOverridesAreSkipped() {
        let bad = [
            KeymapOverride(scope: "nowhere", key: "c", modifiers: 0, command: "tool.razor"),
            KeymapOverride(scope: "global", key: "zzz", modifiers: 0, command: "tool.razor"),
            KeymapOverride(scope: "global", key: "c", modifiers: 0, command: "futureCommand"),
        ]
        #expect(Keymap.apply(bad, to: sq).entries == sq.entries)
    }

    @Test func overrideForANewSlotIsAppended() {
        let o = KeymapOverride(.global, b("y", .control), .tool(.razor))
        let m = Keymap.apply([o], to: sq)
        #expect(m.command(for: b("y", .control), focus: nil) == .tool(.razor))
        #expect(m.command(for: b("c"), focus: nil) == .tool(.razor))   // the old key stays: this was an add
    }

    @Test func nilOverrideRemovesABinding() {
        let m = Keymap.apply([KeymapOverride(.global, b("c"), nil)], to: sq)
        #expect(m.command(for: b("c"), focus: nil) == nil)
    }

    // MARK: Conflicts

    @Test func sameScopeConflictNamesTheOtherCommand() {
        let c = Keymap.conflicts(of: .tool(.razor), binding: b("v"), scope: .global, in: sq)
        #expect(c.contains { $0.kind == .sameScope && $0.entry?.command == .tool(.selection) })
        #expect(c.first?.message(for: b("v")).contains("Select Tool") == true)
    }

    @Test func freeKeyHasNoConflict() {
        #expect(Keymap.conflicts(of: .tool(.razor), binding: b("y", [.control, .option]), scope: .global, in: sq).isEmpty)
        // Already bound to this very command: not a conflict.
        #expect(Keymap.conflicts(of: .tool(.razor), binding: b("c"), scope: .global, in: sq).isEmpty)
    }

    @Test func panelAndGlobalOverlapWarn() {
        // Timeline Q is ripple trim; binding Razor globally to Q is shadowed in the timeline.
        let g = Keymap.conflicts(of: .tool(.razor), binding: b("q"), scope: .global, in: sq)
        #expect(g.contains { $0.kind == .shadowedInPanel && $0.entry?.scope == .timeline })
        // A timeline binding on C hides the global Razor tool there.
        let t = Keymap.conflicts(of: .rippleTrimNext, binding: b("c"), scope: .timeline, in: sq)
        #expect(t.contains { $0.kind == .shadowsGlobal && $0.entry?.command == .tool(.razor) })
    }

    @Test func reservedKeysAreRefused() {
        let k = b("q", .command)
        #expect(Keymap.conflicts(of: .tool(.razor), binding: k, scope: .global, in: sq).first?.kind == .reserved)
        #expect(Keymap.assign(.tool(.razor), to: k, scope: .global, in: sq) == nil)
    }

    @Test func assignDisplacesTheOtherCommandInTheSameScope() throws {
        let m = try #require(Keymap.assign(.tool(.razor), to: b("v"), scope: .global, in: sq))
        #expect(m.command(for: b("v"), focus: nil) == .tool(.razor))
        #expect(m.duplicates.isEmpty)
        #expect(m.entries.contains { $0.command == .tool(.selection) } == false)
    }

    // MARK: Persistence (remap Razor, restart, still remapped)

    @Test func remappedRazorSurvivesARestart() throws {
        let d = defaults()
        let store = KeymapStore(defaults: d)
        #expect(store.load() == .standard)

        var config = store.load()
        let razor = try #require(config.map.entries.first { $0.command == .tool(.razor) })
        config.set(map: try #require(Keymap.assign(.tool(.razor), to: b("x", .option), scope: .global, in: config.map, moving: razor)))
        store.save(config)

        let restarted = KeymapStore(defaults: d).load()
        #expect(restarted == config)
        #expect(restarted.map.command(for: b("x", .option), focus: .timeline) == .tool(.razor))
        #expect(restarted.map.command(for: b("c"), focus: .timeline) == nil)
        #expect(restarted.map.binding(for: .tool(.razor)) == b("x", .option))
        // The store holds only the diff, not the whole map.
        #expect(restarted.overrides.count == 2)
    }

    @Test func resetAndStandardClearTheStoredValue() {
        let d = defaults()
        let store = KeymapStore(defaults: d)
        var c = KeymapConfig.standard
        c.overrides = [KeymapOverride(.global, b("c"), nil)]
        store.save(c)
        #expect(d.data(forKey: KeymapStore.defaultsKey) != nil)
        c.resetOverrides()
        store.save(c)
        #expect(d.data(forKey: KeymapStore.defaultsKey) == nil)
        store.save(KeymapConfig(preset: .premiere))
        #expect(store.load().preset == .premiere)
        store.reset()
        #expect(store.load() == .standard)
    }

    @Test func corruptValueFallsBackToStandard() {
        let d = defaults()
        d.set(Data("not json".utf8), forKey: KeymapStore.defaultsKey)
        #expect(KeymapStore(defaults: d).load() == .standard)
    }

    @Test func switchingPresetDropsOverridesAndUsesThatBase() {
        var c = KeymapConfig.standard
        c.overrides = [KeymapOverride(.global, b("c"), nil)]
        c.switchPreset(.premiere)
        #expect(c.overrides.isEmpty)
        #expect(c.map.command(for: b("w"), focus: .timeline) == .rippleTrimNext)
    }

    // MARK: Rows and layout model

    @Test func rowsCoverBindingsAndMenuOnlyCommands() {
        let rows = KeymapRow.build(sq)
        #expect(rows.filter { $0.entry != nil }.count == sq.entries.count)
        #expect(rows.contains { $0.entry == nil && $0.command == .revert })
        #expect(KeymapRow.filter(rows, query: "blade").contains { $0.command == .tool(.razor) })
    }

    @Test func layoutModelColoursKeysByGroup() {
        let m = KeyboardLayoutModel(map: sq)
        #expect(m.group(for: .char("c")) == .tools)
        #expect(m.group(for: .char("q")) == .editing)
        #expect(m.group(for: .char("j")) == .transport)
        #expect(m.group(for: .char("y")) == .tools)
        let cmd = KeyboardLayoutModel(map: sq, modifiers: .command)
        #expect(cmd.group(for: .char("c")) == .clipboard)
        #expect(m.summary(for: .char("c")).contains("Blade"))
    }

    @Test func layoutHasAllLetterAndDigitKeys() {
        for style in KeyboardLayout.Style.allCases {
            let caps = KeyboardLayout.caps(style)
            let keys = Set(caps.compactMap(\.key))
            for ch in "abcdefghijklmnopqrstuvwxyz0123456789" { #expect(keys.contains(.char(ch)), "\(style) \(ch)") }
            #expect(keys.contains(.space) && keys.contains(.left) && keys.contains(.right) && keys.contains(.delete))
            for c in caps { #expect(c.x >= -0.001 && c.x + c.w <= KeyboardLayout.width + 0.001 && c.y + c.h <= KeyboardLayout.height + 0.001) }
        }
    }

    @Test func germanLayoutSwapsYAndZ() {
        func label(_ style: KeyboardLayout.Style, at row: Int, after lead: String) -> String? {
            let caps = KeyboardLayout.caps(style).filter { $0.y == Double(row) * (KeyboardLayout.keyHeight + KeyboardLayout.gap) }
            return caps.first(where: { $0.label == "T" }).flatMap { t in caps.first(where: { $0.x > t.x })?.label }
        }
        #expect(label(.german, at: 1, after: "T") == "Z")
        #expect(label(.us, at: 1, after: "T") == "Y")
        let de = KeyboardLayout.caps(.german).first { $0.label == "Z" }
        #expect(de?.key == .char("z"))
        #expect(KeyboardLayout.caps(.german).contains { $0.label == "ß" })
    }
}
