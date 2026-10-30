import Foundation
import SQCore
import Testing
@testable import SQUIKit

/// Premiere `.kys` and Resolve layout import through the shared pipeline. Fixtures are synthetic (docs/KEYMAP.md).
@Suite struct PremiereResolveImportTests {
    private let german = KeyCharacterResolver.table(["c": .init(key: .char("c"), needsShift: false), "z": .init(key: .char("z"), needsShift: false), "s": .init(key: .char("s"), needsShift: false)])

    @Test func everyTableRowNamesARealCommand() {
        for (name, target) in PremiereCommandTable.rows {
            if case .command(let id) = target { #expect(EditorCommand(id: id) != nil, "Premiere \(name) -> \(id) is not a command of ours") }
        }
        for (name, target) in ResolveCommandTable.rows {
            if case .command(let id) = target { #expect(EditorCommand(id: id) != nil, "Resolve \(name) -> \(id) is not a command of ours") }
        }
    }

    @Test func premiereFileBindsMappedCommands() throws {
        let xml = """
        <PremiereData Version="3"><shortcuts Version="5"><context.global>
        <item.0><virtualkey>2147483715</virtualkey><commandname>cmd.tools.06razor</commandname></item.0>
        <item.1><virtualkey>2147483738</virtualkey><modifier.ctrl>true</modifier.ctrl><commandname>cmd.edit.undo</commandname></item.1>
        </context.global></shortcuts></PremiereData>
        """
        let file = try ForeignKeymapFile.read(Data(xml.utf8))
        #expect(file.format == .premiere)
        let r = KeymapImport.build(file.commands, base: .sqDefault, table: file.format.table, resolver: german)
        #expect(r.importedCommands == 2)
        #expect(r.unmapped.isEmpty)
    }

    @Test func resolveFileBindsMappedCommandsAndListsTheRest() throws {
        let text = """
        controlPlayToggle := Space
        editUndo := Ctrl+Z
        colorNodeAddSerial := Alt+S
        editBlade :=
        """
        let file = try ForeignKeymapFile.read(Data(text.utf8))
        #expect(file.format == .resolve)
        let r = KeymapImport.build(file.commands, base: .sqDefault, table: file.format.table, resolver: german)
        #expect(r.importedCommands == 2)
        #expect(r.unmapped.map(\.sourceID) == ["colorNodeAddSerial"])
        #expect(r.unmapped.first?.title == "Color Node Add Serial")
    }
}
