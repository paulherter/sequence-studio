import Testing
@testable import SQUIKit

/// Adobe-default keys that were open gaps (docs/MASTER-LIST.md, Settings, menus and panels).
@Suite struct ShortcutGapsTests {
    static let maps: [CommandMap] = [.premiereDefault, .sqDefault]

    @Test(arguments: maps) func adobeDefaultsAreBound(_ m: CommandMap) {
        func cmd(_ k: Key, _ mods: KeyModifiers, _ f: PanelID?) -> EditorCommand? { m.command(for: KeyBinding(k, mods), focus: f) }
        for f in [PanelID.timeline, .programMonitor, .project] {
            #expect(cmd(.char("u"), .command, f) == .makeSubclip)
            #expect(cmd(.char("e"), .command, f) == .editOriginal)
            #expect(cmd(.space, .control, f) == .playToOut)
        }
    }

    @Test(arguments: maps) func audioCommandsHaveKeys(_ m: CommandMap) {
        let mods: KeyModifiers = [.control, .option]
        #expect(m.command(for: KeyBinding(.char("l"), mods), focus: .timeline) == .matchLoudness)
        #expect(m.command(for: KeyBinding(.char("d"), mods), focus: .timeline) == .autoDuck)
        #expect(m.command(for: KeyBinding(.char("["), []), focus: .timeline) == .audioGainDown)
        #expect(m.command(for: KeyBinding(.char("]"), []), focus: .timeline) == .audioGainUp)
    }

    @Test(arguments: maps) func addKeyframeAndPlayFromStartHaveKeys(_ m: CommandMap) {
        func cmd(_ k: Key, _ mods: KeyModifiers, _ f: PanelID?) -> EditorCommand? { m.command(for: KeyBinding(k, mods), focus: f) }
        #expect(cmd(.char("k"), [.control, .option], .timeline) == .addKeyframe)
        #expect(cmd(.char("k"), [.control, .option], .effectControls) == .addKeyframe)
        #expect(cmd(.char("k"), .option, .programMonitor) == .playInToOut)
        #expect(cmd(.space, [.control, .shift], .timeline) == .playFromStart)
        #expect(EditorCommand(id: EditorCommand.addAndEditMarker.id) == .addAndEditMarker)
    }

    @Test(arguments: maps) func shiftSixNeverOpensLibrary(_ m: CommandMap) {
        let shift6 = KeyBinding(.char("6"), .shift)
        #expect(m.command(for: shift6, focus: nil) == .focusPanel(.audioMeter))
        #expect(!m.entries.contains { $0.command == .focusPanel(.library) })
    }

    @Test(arguments: maps) func panelKeysOnlyTargetExistingWindowPanels(_ m: CommandMap) {
        for e in m.entries {
            if case .focusPanel(let p) = e.command {
                #expect(EditorMenus.windowPanels.contains(p), "\(p)")
            }
        }
    }

    @Test(arguments: maps) func nudgeEditKeysDoNotShadowTrimKeys(_ m: CommandMap) {
        func cmd(_ k: Key, _ mods: KeyModifiers) -> EditorCommand? { m.command(for: KeyBinding(k, mods), focus: .timeline) }
        #expect(cmd(.left, [.control, .option]) == .nudgeAudioEditLeft)
        #expect(cmd(.right, [.control, .option]) == .nudgeAudioEditRight)
        #expect(cmd(.left, [.control, .option, .shift]) == .nudgeVideoEditLeft)
        #expect(cmd(.right, [.control, .option, .shift]) == .nudgeVideoEditRight)
        #expect(cmd(.left, .option) == .trimBackward)       // Opt+Left stays Trim Backward 1 frame
        #expect(cmd(.left, [.option, .shift]) == .trimBackward5)
        #expect(m.duplicates.isEmpty)
    }

    @Test func fitToFillAndReplaceAreInMenusWithoutKeys() {
        for c in [EditorCommand.fitToFill, .replaceClipFromSource, .nudgeAudioEditLeft, .nudgeVideoEditRight, .jCutByOffset, .lCutByOffset] {
            #expect(CommandCatalog.all.contains(c))
            #expect(CommandSupport.isCore(c))
            #expect(EditorCommand(id: c.id) == c)
            #expect(EditorMenus.all.flatMap(\.commands).contains(c), "\(c)")
        }
        for c in [EditorCommand.fitToFill] {
            #expect(CommandMap.premiereDefault.binding(for: c) == nil)
            #expect(CommandMap.sqDefault.binding(for: c) == nil)
        }
    }

    @Test(arguments: maps) func replaceAndOffsetSplitEditsHaveKeys(_ m: CommandMap) {
        for c in [EditorCommand.replaceClipFromSource, .replaceClipFromProject, .jCutByOffset, .lCutByOffset] {
            #expect(m.binding(for: c) != nil, "\(c)")
            #expect(!EditorMenus.menuOnly.contains(c))
        }
        #expect(m.command(for: KeyBinding(.char("j"), [.control, .option, .shift]), focus: .timeline) == .jCutByOffset)
        #expect(m.duplicates.isEmpty)
    }

    @Test(arguments: maps) func goToTimecodeTargetsAndPlayInToOutKeys(_ m: CommandMap) {
        func cmd(_ k: Key, _ mods: KeyModifiers, _ f: PanelID?) -> EditorCommand? { m.command(for: KeyBinding(k, mods), focus: f) }
        for f in [PanelID.timeline, .programMonitor, .project, .sourceMonitor] {
            #expect(cmd(.char("p"), .control, f) == .goToTimecode)
            #expect(cmd(.char("k"), .option, f) == .playInToOut)
        }
        #expect(cmd(.char("9"), .command, .timeline) == .toggleVideoTargets)
        #expect(cmd(.char("0"), .command, .timeline) == .toggleAudioTargets)
        #expect(m.duplicates.isEmpty)
        for c in [EditorCommand.goToTimecode, .toggleVideoTargets, .toggleAudioTargets] {
            #expect(EditorCommand(id: c.id) == c)
            #expect(EditorMenus.all.flatMap(\.commands).contains(c))
        }
    }

    @Test func noDuplicatesAfterNewKeys() {
        #expect(CommandMap.premiereDefault.duplicates.isEmpty)
        #expect(CommandMap.sqDefault.duplicates.isEmpty)
    }
}

@Suite struct UIScaleCommandTests {
    @Test func menuListsEntriesAndKeysAreUnique() {
        let cmds = EditorMenus.view.commands
        for c in [EditorCommand.uiScaleLarger, .uiScaleSmaller, .uiScaleReset] {
            #expect(cmds.contains(c))
            #expect(EditorCommand(id: c.id) == c)
            #expect(CommandSupport.isSupported(c))
            for m in [CommandMap.premiereDefault, CommandMap.sqDefault] {
                #expect(m.binding(for: c) != nil)
                #expect(m.duplicates.isEmpty)
            }
        }
        let bound = [EditorCommand.uiScaleLarger, .uiScaleSmaller, .uiScaleReset].compactMap { CommandMap.premiereDefault.binding(for: $0) }
        #expect(Set(bound).count == 3)
    }

    @Test func trackAndEditKeysAreBoundWithoutConflict() {
        for m in [CommandMap.premiereDefault, .sqDefault] {
            #expect(m.duplicates.isEmpty)
            func cmd(_ k: Character, _ mod: KeyModifiers) -> EditorCommand? { m.command(for: KeyBinding(.char(k), mod), focus: .timeline) }
            for n in 1...9 {
                let c = Character(String(n))
                #expect(cmd(c, .control) == .toggleTrackTarget(.video, n))
                #expect(cmd(c, [.control, .option]) == .toggleTrackTarget(.audio, n))
            }
            #expect(cmd("k", [.control, .shift]) == .toggleLockOfTargets)
            #expect(cmd("[", [.control, .option]) == .videoFadeIn)
            #expect(cmd("]", [.control, .option]) == .videoFadeOut)
            #expect(cmd("h", [.control, .shift]) == .addFrameHold)
            #expect(cmd("j", [.control, .option]) == .joinCuts)
            #expect(cmd("v", [.command, .option, .shift]) == .pasteToTargets)
            #expect(cmd("l", [.control, .shift]) == .toggleLinkedSelection)
        }
        #expect(EditorCommand(id: EditorCommand.toggleTrackTarget(.audio, 3).id) == .toggleTrackTarget(.audio, 3))
    }
}
