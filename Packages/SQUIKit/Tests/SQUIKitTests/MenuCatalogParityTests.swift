import Testing
@testable import SQUIKit

/// Audit F (A8, D4, D25): every menu item is an EditorCommand, listed in the catalog (palette, keymap window), and the
/// commands the audit named have a key or a menu door.
@Suite struct MenuCatalogParityTests {
    static let maps: [CommandMap] = [.premiereDefault, .sqDefault]

    /// The commands that used to be inserted into the File menu by the app.
    static let importExport: [EditorCommand] = [
        .importTimeline, .exportEDL, .exportFCPXML, .exportFinalCutXML, .exportOpenTimelineIO,
        .importLottie, .importMotionGraphicsTemplate, .importPremiereProject, .importPremierePresets, .importProject,
    ]

    @Test func everyMenuCommandIsInTheCatalog() {
        let catalog = Set(CommandCatalog.all)
        for m in EditorMenus.all {
            for c in m.commands where !catalog.contains(c) {
                // Parametrised families are generated; plain commands must be listed by hand.
                switch c {
                case .speedRampPreset, .splitScreen: continue
                default: Issue.record("\(m.title) > \(c) is missing from CommandCatalog.plain")
                }
            }
        }
    }

    @Test func importExportItemsAreFileMenuCommands() {
        let file = EditorMenus.file.commands
        for c in Self.importExport {
            #expect(file.contains(c), "\(c) is not in the File menu")
            #expect(CommandSupport.isSupported(c), "\(c) is not wired")
            #expect(EditorMenus.menuOnly.contains(c), "\(c) has no key, so it is menu only")
            #expect(CommandCatalog.plain.contains(c), "\(c)")
            #expect(EditorCommand(id: c.id) == c)
        }
    }

    @Test(arguments: maps) func auditedCommandsHaveKeys(_ m: CommandMap) {
        let keyed: [EditorCommand] = [.nextKeyframe, .previousKeyframe, .toggleLinkedSelection, .addVideoTrack, .addAudioTrack]
        for c in keyed {
            let b = m.binding(for: c)
            #expect(b != nil, "\(c) has no key")
            #expect(!EditorMenus.menuOnly.contains(c), "\(c) has a key and is no longer menu only")
            if let b { #expect(m.command(for: b, focus: .timeline) == c) }
        }
        #expect(m.duplicates.isEmpty, "\(m.duplicates.map { "\($0.scope) \($0.command)" })")
    }

    @Test func graphEditorHasAMenuDoor() {
        #expect(EditorMenus.view.commands.contains(.toggleGraphEditor))
        #expect(CommandSupport.isSupported(.toggleGraphEditor))
        #expect(EditorMenus.menuOnly.contains(.toggleGraphEditor))
    }

    @Test func addTrackCommandsAreInTheSequenceMenu() {
        #expect(EditorMenus.sequence.commands.contains(.addVideoTrack))
        #expect(EditorMenus.sequence.commands.contains(.addAudioTrack))
        #expect(CommandSupport.isTimelineOp(.addVideoTrack) && CommandSupport.isTimelineOp(.addAudioTrack))
    }

    @Test func placeOnTopIsInMenuAndKeyed() {
        #expect(EditorMenus.sequence.commands.contains(.placeOnTop))
        #expect(CommandMap.premiereDefault.binding(for: .placeOnTop) != nil)
    }

    @Test func newCommandsHaveGermanTitles() {
        let new: [EditorCommand] = Self.importExport + [.addVideoTrack, .addAudioTrack, .toggleGraphEditor]
        for c in new { #expect(SQL10n.string(c.title, language: "de") != c.title, "\(c.title)") }
    }
}
