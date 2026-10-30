import Foundation
import Testing
@testable import SQCore

/// Fixtures are SYNTHETIC, built from the documented structure of both formats (docs/KEYMAP.md "Premiere and Resolve import"):
/// no real .kys or Resolve preset was available. The tests pin our reading, not the apps' files.
@Suite struct ForeignKeymapPremiereResolveTests {
    static func kys(_ items: [(key: UInt32, mods: [String], cmd: String)], context: String = "context.global") -> Data {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<PremiereData Version=\"3\"><shortcuts Version=\"5\"><\(context)>\n"
        for (i, it) in items.enumerated() {
            s += "<item.\(i)><virtualkey>\(it.key)</virtualkey>"
            for m in it.mods { s += "<modifier.\(m)>true</modifier.\(m)>" }
            s += "<commandname>\(it.cmd)</commandname></item.\(i)>\n"
        }
        s += "</\(context)></shortcuts></PremiereData>\n"
        return Data(s.utf8)
    }

    static func ascii(_ c: Character) -> UInt32 { 0x8000_0000 | c.asciiValue.map(UInt32.init)! }

    // MARK: Premiere

    @Test func premiereReadsKeysModifiersAndCommands() throws {
        let data = Self.kys([
            (Self.ascii("G"), [], "cmd.tools.10hand"),
            (Self.ascii("K"), ["ctrl"], "cmd.edit.keyboardshortcuts"),
            (Self.ascii("Z"), ["ctrl", "shift"], "cmd.edit.redo"),
            (Self.ascii("["), ["alt"], "cmd.tlnav.trim.in.to.cti"),
            (11, [], "cmd.transport.toggleplay"),
            (Self.ascii(" "), [], "cmd.monitor.playstoptoggle"),
            (Self.ascii("\u{7F}"), [], "cmd.edit.clear"),
        ])
        let cmds = try PremiereKysReader.read(data)
        func chords(_ id: String) -> [ForeignChord] { cmds.first { $0.sourceID == id }?.chords ?? [] }
        #expect(chords("cmd.tools.10hand") == [ForeignChord(.char("g"))], "letters are lowercase")
        #expect(chords("cmd.edit.keyboardshortcuts") == [ForeignChord(.char("k"), .command)], "ctrl is Command")
        #expect(chords("cmd.edit.redo") == [ForeignChord(.char("z"), [.command, .shift])])
        #expect(chords("cmd.tlnav.trim.in.to.cti") == [ForeignChord(.char("["), .option)], "alt is Option")
        #expect(chords("cmd.transport.toggleplay") == [ForeignChord(.function(5))])
        #expect(chords("cmd.monitor.playstoptoggle") == [ForeignChord(.space)])
        #expect(chords("cmd.edit.clear") == [ForeignChord(.forwardDelete)])
    }

    @Test func premiereMergesContextsAndSkipsUnknownKeys() throws {
        let xml = """
        <PremiereData Version="3"><shortcuts Version="5">
        <context.global><item.0><virtualkey>2147483723</virtualkey><commandname>cmd.transport.stop</commandname></item.0></context.global>
        <context.timeline>
          <item.0><virtualkey>2147483723</virtualkey><commandname>cmd.transport.stop</commandname></item.0>
          <item.1><virtualkey>2147483724</virtualkey><commandname>cmd.transport.stop</commandname></item.1>
          <item.2><virtualkey>9999</virtualkey><commandname>cmd.edit.cut</commandname></item.2>
          <item.3><commandname>cmd.edit.copy</commandname></item.3>
        </context.timeline></shortcuts></PremiereData>
        """
        let cmds = try PremiereKysReader.read(Data(xml.utf8))
        let stop = cmds.first { $0.sourceID == "cmd.transport.stop" }
        #expect(stop?.chords == [ForeignChord(.char("k")), ForeignChord(.char("l"))], "same chord in two contexts counts once")
        let cut = cmds.first { $0.sourceID == "cmd.edit.cut" }
        #expect(cut?.chords.isEmpty == true)
        #expect(cut?.unreadable == ["key code 9999"])
        #expect(cmds.first { $0.sourceID == "cmd.edit.copy" }?.chords.isEmpty == true, "no key: unassigned")
    }

    @Test func premiereRejectsOtherFiles() {
        #expect(throws: PremiereKysReader.ReadError.notAKeyboardLayout) { try PremiereKysReader.read(Data("hello".utf8)) }
        #expect(throws: PremiereKysReader.ReadError.notAKeyboardLayout) { try PremiereKysReader.read(Data("<a><b/></a>".utf8)) }
    }

    // MARK: Resolve

    static let preset = """
    editBlade :=
    controlPlayToggle := Space
    controlPlayReverse := J
    editUndo := Ctrl+Z
    editRedo := Ctrl+Shift+Z
    editDelete := Alt+Backspace | Shift+Del
    controlGotoStart := Home
    controlClipPrev := PgUp
    viewZoomSubZoomIn := =
    controlKeyframeNext := Alt+'
    editNudgeTrimStepTrimMultiFrameRight := Shift+. | Ctrl+Shift+Right
    sessionPrinterLightsBlueMinus := Num+6
    markNumPlus := Ctrl+Num++
    viewPlus := Ctrl++
    controlFastForward := F9
    markStrange := Hyper+Q
    """

    @Test func resolveReadsChordsAndAlternatives() throws {
        let cmds = try ResolveKeymapReader.read(Data(Self.preset.utf8))
        func chords(_ id: String) -> [ForeignChord] { cmds.first { $0.sourceID == id }?.chords ?? [] }
        #expect(chords("controlPlayToggle") == [ForeignChord(.space)])
        #expect(chords("controlPlayReverse") == [ForeignChord(.char("j"))])
        #expect(chords("editUndo") == [ForeignChord(.char("z"), .command)], "Ctrl is Command on a Mac")
        #expect(chords("editRedo") == [ForeignChord(.char("z"), [.command, .shift])])
        #expect(chords("editDelete") == [ForeignChord(.backspace, .option), ForeignChord(.forwardDelete, .shift)])
        #expect(chords("controlGotoStart") == [ForeignChord(.home)])
        #expect(chords("controlClipPrev") == [ForeignChord(.pageUp)])
        #expect(chords("viewZoomSubZoomIn") == [ForeignChord(.char("="))])
        #expect(chords("controlKeyframeNext") == [ForeignChord(.char("'"), .option)])
        #expect(chords("editNudgeTrimStepTrimMultiFrameRight") == [ForeignChord(.char("."), .shift), ForeignChord(.right, [.command, .shift])])
        #expect(chords("sessionPrinterLightsBlueMinus") == [ForeignChord(.char("6"))], "keypad twin is the same chord")
        #expect(chords("markNumPlus") == [ForeignChord(.char("+"), .command)])
        #expect(chords("viewPlus") == [ForeignChord(.char("+"), .command)])
        #expect(chords("controlFastForward") == [ForeignChord(.function(9))])
        #expect(chords("editBlade").isEmpty)
        let strange = cmds.first { $0.sourceID == "markStrange" }
        #expect(strange?.chords.isEmpty == true)
        #expect(strange?.unreadable == ["Hyper+Q"])
    }

    @Test func resolveRejectsOtherFiles() {
        #expect(throws: ResolveKeymapReader.ReadError.notAKeyboardLayout) { try ResolveKeymapReader.read(Data("hello\nworld".utf8)) }
        #expect(throws: ResolveKeymapReader.ReadError.notAKeyboardLayout) { try ResolveKeymapReader.read(Data([0xFF, 0x00, 0x13])) }
    }

    // MARK: Detection and tables

    @Test func detectionPicksTheFormat() throws {
        #expect(try ForeignKeymapFile.read(Self.kys([(Self.ascii("G"), [], "cmd.tools.10hand")])).format == .premiere)
        #expect(try ForeignKeymapFile.read(Data(Self.preset.utf8)).format == .resolve)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Cut": ["characterString": "x", "modifiers": "command"]], format: .binary, options: 0)
        #expect(try ForeignKeymapFile.read(plist).format == .finalCut)
        #expect(throws: (any Error).self) { try ForeignKeymapFile.read(Data("nothing here".utf8)) }
    }

    @Test func tablesMapAndReportUnmapped() throws {
        let p = ForeignKeymap.translate(try PremiereKysReader.read(Self.kys([
            (Self.ascii("C"), [], "cmd.tools.06razor"),
            (Self.ascii("Q"), ["ctrl"], "cmd.file.quit"),
            (Self.ascii("X"), [], "cmd.not.in.our.table"),
        ])), table: PremiereCommandTable.rows)
        #expect(p.mapped.map(\.commandID) == ["tool.razor"])
        let reasons = Dictionary(uniqueKeysWithValues: p.unmapped.map { ($0.sourceID, $0.reason) })
        #expect(reasons["cmd.file.quit"] == .system)
        #expect(reasons["cmd.not.in.our.table"] == .noEquivalent)

        let r = ForeignKeymap.translate(try ResolveKeymapReader.read(Data(Self.preset.utf8)), table: ResolveCommandTable.rows)
        let mapped = Dictionary(uniqueKeysWithValues: r.mapped.map { ($0.sourceID, $0.commandID) })
        #expect(mapped["controlPlayToggle"] == "playPause")
        #expect(mapped["editUndo"] == "undo")
        #expect(r.unmapped.contains { $0.sourceID == "markStrange" }, "an unreadable key is still reported")
        #expect(r.unassigned == 1, "editBlade has no key")
    }

    @Test func humanizeHandlesDottedAndUnderscoreIds() {
        #expect(ForeignKeymap.humanize("cmd.sequence.lift") == "Sequence Lift")
        #expect(ForeignKeymap.humanize("editNudgeTrimStepTrimEnd") == "Edit Nudge Trim Step Trim End")
        #expect(ForeignKeymap.humanize("MediaPool.Context_setPosterFrame") == "Media Pool: Context Set Poster Frame")
        #expect(ForeignKeymap.humanize("BladeAtPlayhead") == "Blade At Playhead")
    }
}
