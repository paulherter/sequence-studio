import Testing
@testable import SQUIKit

/// Feedback 2026-10-17: the menu bar shows one entry per action, nothing scrolls. `EditorMenus.all` stays the full catalog
/// (Quick Apply, audit); `EditorMenus.visible` is what the menu bar builds.
@Suite struct MenuLimitsTests {
    private static func count(_ items: [MenuSpec.Item]) -> Int {
        items.filter { if case .separator = $0 { false } else { true } }.count
    }
    private static func submenus(_ items: [MenuSpec.Item]) -> [(String, [MenuSpec.Item])] {
        items.flatMap { item -> [(String, [MenuSpec.Item])] in
            if case .submenu(let t, let sub) = item { return [(t, sub)] + submenus(sub) }
            return []
        }
    }

    @Test func visibleMenusAreASubsetOfTheCatalog() {
        let all = Set(EditorMenus.all.flatMap(\.commands))
        for m in EditorMenus.visible {
            for c in m.commands { #expect(all.contains(c), "\(m.title) > \(c) is not in the catalog") }
        }
        #expect(EditorMenus.visible.map(\.title) == EditorMenus.all.map(\.title))
    }

    @Test func menusFitWithoutScrolling() {
        for m in EditorMenus.visible {
            #expect(Self.count(m.items) <= 15, "\(m.title) has \(Self.count(m.items)) entries")
            for (t, sub) in Self.submenus(m.items) {
                #expect(Self.count(sub) <= 8, "\(m.title) > \(t) has \(Self.count(sub)) entries")
            }
        }
    }

    @Test func oneImportAndOneExportEntry() {
        let file = EditorMenus.visible.first { $0.title == "File" }?.commands ?? []
        #expect(file.contains(.importMedia) && file.contains(.export))
        let variants: [EditorCommand] = [
            .importTimeline, .importLottie, .importMotionGraphicsTemplate, .importPremiereProject, .importPremierePresets, .importProject,
            .exportFrame, .exportMarkersCSV, .exportEDL, .exportFCPXML, .exportFinalCutXML, .exportOpenTimelineIO,
        ]
        for c in variants { #expect(!file.contains(c), "\(c) should live in the Import / Export dialog") }
    }

    @Test func noCommandAppearsTwice() {
        for m in EditorMenus.visible {
            let cmds = m.commands
            #expect(Set(cmds).count == cmds.count, "\(m.title) lists a command twice")
        }
    }
}
