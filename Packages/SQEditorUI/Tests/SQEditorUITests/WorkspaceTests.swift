import Foundation
import Testing
@testable import SQEditorUI

@Suite struct WorkspaceTests {
    @Test func pcStructure() {
        let w = Workspace.editingPC
        #expect(w.name == "Editing – PC")
        guard case .split(.horizontal, let top, let f) = w.root else { Issue.record("root"); return }
        #expect(top.count == 2 && f == [0.75, 0.25])
        guard case .split(.vertical, let left, _) = top[0],
              case .split(.horizontal, let upper, _) = left[0] else { Issue.record("left"); return }
        #expect(upper[0] == .tabs(panels: [.effectControls, .text, .colorInspector], selected: .effectControls))
        #expect(upper[1] == .tabs(panels: [.programMonitor, .sourceMonitor], selected: .programMonitor))
        #expect(left[1] == Workspace.timelineWithMeter)   // meter docked right of the timeline
        guard case .split(.vertical, let right, _) = top[1] else { Issue.record("right"); return }
        #expect(right[0] == .tabs(panels: [.library], selected: .library))
        #expect(right[1] == .tabs(panels: [.effects, .project, .scopes], selected: .effects))
        #expect(Set(w.allPanels) == Set(PanelID.allCases))
        #expect(w.isVisible(.audioMeter))
    }

    @Test func savedWorkspaceWithSourceSelectedOpensOnProgram() throws {
        var w = Workspace.editingPC
        w.root = LayoutNode.tabs(panels: [.programMonitor, .sourceMonitor], selected: .sourceMonitor)
        let data = try JSONEncoder().encode(w)
        let back = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(back.root == .tabs(panels: [.programMonitor, .sourceMonitor], selected: .programMonitor))
        // A group without Program keeps its selection.
        let only = LayoutNode.tabs(panels: [.sourceMonitor, .text], selected: .sourceMonitor)
        #expect(only.programPreferred == only)
    }

    @Test func oldSavedLayoutGetsTheMeterBesideTheTimeline() throws {
        // A workspace saved before the meter existed: timeline group and a monitor group.
        let old = LayoutNode.split(axis: .vertical, children: [
            .tabs(panels: [.programMonitor, .sourceMonitor], selected: .programMonitor),
            .tabs(panels: [.timeline], selected: .timeline),
        ], fractions: [0.5, 0.5])
        let data = try JSONEncoder().encode(Workspace(name: "Old", root: old))
        let back = try JSONDecoder().decode(Workspace.self, from: data)
        guard case .split(.vertical, let c, _) = back.root else { Issue.record("root"); return }
        #expect(c[1] == Workspace.timelineWithMeter)
        // Decoding again (or a layout that already has the meter) changes nothing.
        let again = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(back))
        #expect(again.root == back.root)
    }

    @Test func oldSavedColorLayoutGetsTheMeterHidden() throws {
        let old = LayoutNode.split(axis: .vertical, children: [
            .tabs(panels: [.programMonitor], selected: .programMonitor),
            .tabs(panels: [.timeline], selected: .timeline),
        ], fractions: [0.5, 0.5])
        let data = try JSONEncoder().encode(Workspace(name: Workspace.color.name, root: old))
        let back = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(back.allPanels.contains(.audioMeter) && back.hidden.contains(.audioMeter))
        #expect(!back.isVisible(.audioMeter))
    }

    @Test func macBookStructure() {
        let w = Workspace.editingMacBook
        guard case .split(.horizontal, let c, _) = w.root else { Issue.record("root"); return }
        #expect(c[1] == .tabs(panels: [.programMonitor, .sourceMonitor], selected: .programMonitor))   // full height, right
        guard case .split(.vertical, let left, _) = c[0],
              case .split(.horizontal, let upper, _) = left[0],
              case .split(.horizontal, let lower, _) = left[1] else { Issue.record("left"); return }
        #expect(upper[0] == .tabs(panels: [.library, .effects, .scopes], selected: .library))
        #expect(upper[1] == .tabs(panels: [.effectControls, .text, .colorInspector], selected: .effectControls))
        #expect(lower[0] == .tabs(panels: [.project], selected: .project))
        #expect(lower[1] == Workspace.timelineWithMeter)
        #expect(Set(w.allPanels) == Set(PanelID.allCases))
    }

    @Test func fractionsSumToOne() {
        for w in Workspace.builtIns { check(w.root) }
        func check(_ n: LayoutNode) {
            if case .split(_, let c, let f) = n {
                #expect(c.count == f.count)
                #expect(abs(f.reduce(0, +) - 1) < 1e-9)
                c.forEach(check)
            }
        }
    }

    @Test func hideShowRoundTrip() {
        var w = Workspace.editingPC
        let original = w
        w.hide(.library)
        #expect(!w.isVisible(.library))
        #expect(!(w.visibleRoot?.panels.contains(.library) ?? true))
        w.hide(.timeline)
        w.show(.timeline)
        w.show(.library)
        #expect(w.visibleRoot == original.visibleRoot)
        #expect(w == original)
    }

    @Test func hidingCollapsesAndRenormalises() {
        var w = Workspace.editingPC
        w.hide(.library); w.hide(.effects); w.hide(.project)   // whole right column gone
        #expect(w.visibleRoot?.panels.contains(.project) == false)
        if case .split(.vertical, _, _)? = w.visibleRoot {} else { Issue.record("root should collapse to the left column") }
        var all = Workspace.editingPC
        for p in PanelID.allCases { all.hide(p) }
        #expect(all.visibleRoot == nil)
    }

    @Test func hiddenTabFallsBackAndShowSelects() {
        var w = Workspace.editingPC
        w.hide(.effectControls)
        if case .split(_, let c, _)? = w.visibleRoot, case .split(_, let l, _) = c[0], case .split(_, let u, _) = l[0] {
            #expect(u[0] == .tabs(panels: [.text], selected: .text))
        } else { Issue.record("shape") }
        w.show(.effectControls)
        w.selectTab(.colorInspector)
        #expect(w.root.panels.count == PanelID.allCases.count)
        if case .split(_, let c, _) = w.root, case .split(_, let l, _) = c[0], case .split(_, let u, _) = l[0] {
            #expect(u[0] == .tabs(panels: [.effectControls, .text, .colorInspector], selected: .colorInspector))
        }
    }

    @Test func setFractionsNormalisesAndClamps() {
        var w = Workspace.editingPC
        do { let r = w.setFractions(at: [], [3, 1]); #expect(r) }
        guard case .split(_, _, let f) = w.root else { return }
        #expect(f == [0.75, 0.25])
        do { let r = w.setFractions(at: [], [1, 0]); #expect(r) }
        guard case .split(_, _, let g) = w.root else { return }
        #expect(abs(g.reduce(0, +) - 1) < 1e-12)
        #expect(g[1] >= Workspace.minFraction - 1e-12 && abs(g[1] - 0.05) < 1e-12)
        do { let r = w.setFractions(at: [], [1, 1, 1]); #expect(!r) }          // wrong count
        do { let r = w.setFractions(at: [1, 0], [1, 1]); #expect(!r) }         // tabs, not a split
        do { let r = w.setFractions(at: [0, 0], [1, 1]); #expect(r) }          // nested
    }

    @Test func normalizedEdgeCases() {
        #expect(Workspace.normalized([]) == [])
        #expect(Workspace.normalized([0, 0]) == [0.5, 0.5])
        #expect(Workspace.normalized([.nan, 1]).reduce(0, +) > 0.999)
        let n = Workspace.normalized([10, 0.001, 0.001])
        #expect(abs(n.reduce(0, +) - 1) < 1e-12 && n.min()! >= 0.05 - 1e-12)
        #expect(Workspace.normalized(Array(repeating: 1, count: 30)).allSatisfy { abs($0 - 1.0 / 30) < 1e-12 })
    }

    @Test func setFractionsWithHiddenSiblingKeepsHiddenShare() {
        var w = Workspace.editingPC
        w.hide(.library); w.hide(.effects); w.hide(.project)   // root collapses: path [] is the left vertical split
        do { let r = w.setFractions(at: [], [1, 1]); #expect(r) }                 // passes through the collapsed root
        guard case .split(_, let c, let f) = w.root, case .split(_, _, let inner) = c[0] else { return }
        #expect(f == [0.75, 0.25])                              // hidden right column keeps 0.25
        #expect(inner == [0.5, 0.5])
    }

    @Test func maximizeRestore() {
        var w = Workspace.editingPC
        let before = w
        w.toggleMaximize(.programMonitor)
        #expect(w.visibleRoot == .tabs(panels: [.programMonitor], selected: .programMonitor))
        w.toggleMaximize(.programMonitor)
        #expect(w == before)
        w.toggleMaximize(.timeline); w.hide(.timeline)
        #expect(w.maximized == nil)
        w.hide(.library); w.toggleMaximize(.library)
        #expect(w.maximized == nil)                              // hidden panels cannot be maximized
    }

    @Test func jsonRoundTrip() throws {
        var w = Workspace.editingMacBook
        w.hide(.project); w.toggleMaximize(.timeline)
        let data = try JSONEncoder().encode(w)
        #expect(try JSONDecoder().decode(Workspace.self, from: data) == w)
        for b in Workspace.builtIns {
            #expect(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(b)) == b)
        }
    }

    // MARK: Decode validation

    private func decode(_ root: LayoutNode) throws -> Workspace {
        // Encode a workspace carrying the malformed tree, then decode it the way a saved file would be read.
        let data = try JSONEncoder().encode(Workspace(name: "Bad", root: root))
        return try JSONDecoder().decode(Workspace.self, from: data)
    }

    @Test func decodeFixesFractionCountMismatch() throws {
        let bad = LayoutNode.split(axis: .horizontal, children: [
            .tabs(panels: [.library], selected: .library),
            .tabs(panels: [.timeline], selected: .timeline),
            .tabs(panels: [.project], selected: .project),
        ], fractions: [0.5, 0.5])
        var w = try decode(bad)
        guard case .split(_, let c, let f) = w.root else { Issue.record("root"); return }
        #expect(c.count == 3 && f.count == 3)
        #expect(abs(f.reduce(0, +) - 1) < 1e-9)
        w.hide(.project)
        #expect(w.visibleRoot != nil)                          // prune does not trap
        let applied = w.setFractions(at: [], [0.3, 0.7])
        #expect(applied)
    }

    @Test func decodeFixesFractionsNotSummingToOne() throws {
        let bad = LayoutNode.split(axis: .vertical, children: [
            .tabs(panels: [.library], selected: .library),
            .tabs(panels: [.timeline], selected: .timeline),
        ], fractions: [3, 9])
        let w = try decode(bad)
        guard case .split(_, _, let f) = w.root else { Issue.record("root"); return }
        #expect(f == [0.5, 0.5])
    }

    @Test func decodeRemovesEmptyGroupsAndDropsTheirFraction() throws {
        let bad = LayoutNode.split(axis: .horizontal, children: [
            .tabs(panels: [], selected: .library),
            .tabs(panels: [.timeline], selected: .library),   // selected not in panels
            .split(axis: .vertical, children: [], fractions: []),
        ], fractions: [0.2, 0.5, 0.3])
        let w = try decode(bad)
        #expect(w.root == Workspace.timelineWithMeter)   // repaired to one group, then the meter is docked beside it
    }

    @Test func decodeOfFullyEmptyLayoutFallsBackToDefault() throws {
        let w = try decode(.tabs(panels: [], selected: .library))
        #expect(w.root == Workspace.editingPC.root)
    }

    @Test func validLayoutIsUntouchedByDecode() throws {
        for b in Workspace.builtIns { #expect(try decode(b.root) == Workspace(name: "Bad", root: b.root)) }
    }
}
