import Foundation
import Testing
@testable import SQEditorSession

@Suite struct WorkspaceDockingTests {
    private func groupNode(_ w: Workspace, _ p: PanelID) -> LayoutNode? {
        func find(_ n: LayoutNode) -> LayoutNode? {
            switch n {
            case .tabs(let ps, _): ps.contains(p) ? n : nil
            case .split(_, let c, _): c.lazy.compactMap(find).first
            }
        }
        return find(w.root)
    }
    private func group(_ w: Workspace, _ p: PanelID) -> [PanelID]? {
        if case .tabs(let ps, _) = groupNode(w, p) { return ps }
        return nil
    }
    private func checkValid(_ w: Workspace, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(w.validationProblems == [], sourceLocation: sourceLocation)
        #expect(Set(w.allPanels) == Set(PanelID.dockable), sourceLocation: sourceLocation)
        #expect(w.allPanels.count == PanelID.dockable.count, sourceLocation: sourceLocation)
    }

    // MARK: geometry
    @Test func zones() {
        let r = (x: 100.0, y: 50.0, width: 400.0, height: 200.0)
        #expect(DropZone.zone(for: (300, 150), in: r) == .center)
        #expect(DropZone.zone(for: (110, 150), in: r) == .left)
        #expect(DropZone.zone(for: (490, 150), in: r) == .right)
        #expect(DropZone.zone(for: (300, 55), in: r) == .top)
        #expect(DropZone.zone(for: (300, 245), in: r) == .bottom)
        #expect(DropZone.zone(for: (99, 150), in: r) == nil)
        #expect(DropZone.zone(for: (300, 251), in: r) == nil)
        #expect(DropZone.zone(for: (300, 150), in: (x: 0, y: 0, width: 0, height: 10)) == nil)
        #expect(DropZone.zone(for: (105, 80), in: r) == .left)   // u=.0125, v=.15
        #expect(DropZone.zone(for: (150, 52), in: r) == .top)    // u=.125, v=.01
        #expect(DropZone.zone(for: (200, 100), in: r) == .center) // boundary belongs to center
        #expect(Workspace.dropZone(for: (300, 150), in: r) == .center)
    }

    // MARK: center
    @Test func centerAppendsAndSelects() {
        var w = Workspace.editingPC
        #expect(dk(&w, .timeline, onto: .library, zone: .center))
        #expect(group(w, .library) == [.library, .effects, .timeline])
        guard case .tabs(_, let sel) = groupNode(w, .library) else { Issue.record("group"); return }
        #expect(sel == .timeline)
        checkValid(w)
    }

    @Test func centerWithinSameGroupMovesToEnd() {
        var w = Workspace.editingPC
        #expect(dk(&w, .effectControls, onto: .text, zone: .center))
        #expect(group(w, .text) == [.text, .graphics, .colorInspector, .effectControls])
        checkValid(w)
    }

    // MARK: edges
    @Test(arguments: [DropZone.left, .right, .top, .bottom])
    func edgeSplits(zone: DropZone) {
        var w = Workspace.editingPC
        #expect(dk(&w, .project, onto: .timeline, zone: zone))
        #expect(group(w, .project) == [.project])
        #expect(group(w, .effects) == [.library, .effects])
        checkValid(w)
    }

    /// The timeline sits beside the audio meter: left column of the PC layout is [upper, [timeline | meter]].
    private func timelineRow(_ w: Workspace) -> (left: [LayoutNode], fractions: [Double], row: [LayoutNode], rowFractions: [Double])? {
        guard case .split(_, let c, _) = w.root, case .split(.vertical, let left, let f) = c[0],
              case .split(.horizontal, let row, let rf) = left[1] else { return nil }
        return (left, f, row, rf)
    }

    @Test func edgeSplitBelowTheTimelineLeavesTheMeterFullHeight() {
        var w = Workspace.editingPC
        #expect(dk(&w, .library, onto: .timeline, zone: .bottom))
        guard let r = timelineRow(w), case .split(.vertical, let stack, let sf) = r.row[0] else { Issue.record("shape"); return }
        #expect(r.fractions == [0.521, 0.479])
        #expect(stack == [.tabs(panels: [.timeline], selected: .timeline), .tabs(panels: [.library], selected: .library)])
        #expect(sf == [0.5, 0.5])
        #expect(r.row[1] == .tabs(panels: [.audioMeter], selected: .audioMeter))
        checkValid(w)
    }

    @Test func edgeSplitAboveTheTimelineInsertsFirst() {
        var w = Workspace.editingPC
        #expect(dk(&w, .library, onto: .timeline, zone: .top))
        guard let r = timelineRow(w), case .split(.vertical, let stack, _) = r.row[0] else { Issue.record("shape"); return }
        #expect(stack == [.tabs(panels: [.library], selected: .library), .tabs(panels: [.timeline], selected: .timeline)])
    }

    @Test func edgeSplitLeftOfTheTimelineSharesTheRowWithTheMeter() {
        var w = Workspace.editingPC
        #expect(dk(&w, .library, onto: .timeline, zone: .left))
        guard let r = timelineRow(w) else { Issue.record("shape"); return }
        #expect(r.row == [.tabs(panels: [.library], selected: .library), .tabs(panels: [.timeline], selected: .timeline),
                          .tabs(panels: [.audioMeter], selected: .audioMeter)])
        #expect(abs(r.rowFractions.reduce(0, +) - 1) < 1e-9)
        checkValid(w)
    }

    @Test func splitOwnGroupWithSiblingTab() {
        var w = Workspace.editingPC
        #expect(dk(&w, .sourceMonitor, onto: .programMonitor, zone: .right))
        #expect(group(w, .programMonitor) == [.programMonitor])
        #expect(group(w, .sourceMonitor) == [.sourceMonitor])
        checkValid(w)
    }

    // MARK: removal / collapse
    @Test func dragLastTabOutCollapsesGroup() {
        var w = Workspace.editingPC
        #expect(dk(&w, .library, onto: .programMonitor, zone: .center))
        guard case .split(.horizontal, let c, let f) = w.root else { Issue.record("root"); return }
        // right column (Library | Effects over Project | Keystones): Library leaves, Effects stays with its group
        guard case .split(.vertical, let right, _) = c[1] else { Issue.record("right"); return }
        #expect(right[0] == .tabs(panels: [.effects], selected: .effects))
        #expect(f == [0.762, 0.238])
        checkValid(w)
    }

    @Test func selectedTabAfterRemoval() {
        var w = Workspace.editingPC
        #expect(dk(&w, .effectControls, onto: .timeline, zone: .center))
        #expect(groupNode(w, .text) == .tabs(panels: [.text, .graphics, .colorInspector], selected: .text))
    }

    @Test func sameAxisFlatten() {
        let w0 = Workspace(name: "t", root: .split(axis: .horizontal, children: [
            .tabs(panels: [.library], selected: .library),
            .split(axis: .horizontal, children: [
                .tabs(panels: [.effects], selected: .effects),
                .tabs(panels: [.project], selected: .project),
            ], fractions: [0.5, 0.5]),
        ], fractions: [0.5, 0.5]))
        var w = w0
        #expect(dk(&w, .library, onto: .effects, zone: .center))
        guard case .split(.horizontal, let c, let f) = w.root else { Issue.record("root"); return }
        #expect(c.count == 2 && f == [0.5, 0.5])
        #expect(w.validationProblems == [])

        var w2 = w0
        #expect(dk(&w2, .library, onto: .project, zone: .right))
        guard case .split(.horizontal, let c2, let f2) = w2.root else { Issue.record("root"); return }
        #expect(c2.count == 3)
        #expect(abs(f2[0] - 0.5) < 1e-9 && abs(f2[1] - 0.25) < 1e-9 && abs(f2[2] - 0.25) < 1e-9)
        #expect(w2.validationProblems == [])
    }

    @Test func dockShowsHiddenAndClearsMaximize() {
        var w = Workspace.editingPC
        w.hide(.library)
        w.toggleMaximize(.timeline)
        #expect(dk(&w, .library, onto: .timeline, zone: .center))
        #expect(w.isVisible(.library))
        #expect(w.maximized == nil)
    }

    @Test func rejectsBadInput() {
        var w = Workspace.editingPC
        let before = w
        #expect(!dk(&w, .library, onto: .library, zone: .center))
        #expect(w == before)
        var small = Workspace(name: "s", root: .tabs(panels: [.timeline], selected: .timeline))
        #expect(!dk(&small, .library, onto: .timeline, zone: .center))
        #expect(!mv(&small, .library, toIndex: 0))
    }

    // MARK: reorder
    @Test func moveTab() {
        var w = Workspace.editingPC
        #expect(mv(&w, .colorInspector, toIndex: 0))
        #expect(group(w, .text) == [.colorInspector, .effectControls, .text, .graphics])
        #expect(mv(&w, .colorInspector, toIndex: 99))
        #expect(group(w, .text) == [.effectControls, .text, .graphics, .colorInspector])
        #expect(mv(&w, .text, toIndex: -5))
        #expect(group(w, .text) == [.text, .effectControls, .graphics, .colorInspector])
        guard case .tabs(_, let sel) = groupNode(w, .text) else { return }
        #expect(sel == .effectControls)
        checkValid(w)
    }

    // MARK: invariants under many drops
    @Test func randomDropsKeepInvariants() {
        var rng = SplitMix(seed: 42)
        let all = PanelID.dockable
        for start in Workspace.builtIns {
            var w = start
            for _ in 0..<300 {
                let p = all[Int(rng.next() % UInt64(all.count))], t = all[Int(rng.next() % UInt64(all.count))]
                let z = DropZone.allCases[Int(rng.next() % 5)]
                _ = w.dock(p, onto: t, zone: z)
                if rng.next() % 4 == 0 { _ = w.moveTab(p, toIndex: Int(rng.next() % 4)) }
                if !w.validationProblems.isEmpty || Set(w.allPanels) != Set(all) || w.allPanels.count != all.count {
                    Issue.record("invariant broken: \(w.validationProblems) after \(p) -> \(t) \(z)")
                    return
                }
            }
        }
    }

    // MARK: library
    @Test func libraryBasics() {
        var lib = WorkspaceLibrary()
        #expect(lib.names == Workspace.builtIns.map(\.name))
        var w = Workspace.editingPC
        w.dock(.library, onto: .timeline, zone: .center)
        #expect(lb(&lib) { $0.saveAs("  Color  ", from: w) })
        #expect(lib.names.last == "Color")
        #expect(lib.workspace(named: "color")?.root == w.root)
        #expect(!lb(&lib) { $0.saveAs("", from: w) })
        #expect(!lb(&lib) { $0.saveAs("editing – pc", from: w) })
        #expect(lb(&lib) { $0.saveAs("Color", from: Workspace.editingMacBook) })   // overwrite
        #expect(lib.userWorkspaces.count == 1)
        #expect(lb(&lib) { $0.rename("Color", to: "Audio") })
        #expect(lib.workspace(named: "Color") == nil && lib.workspace(named: "Audio") != nil)
        #expect(lb(&lib) { $0.saveAs("Other", from: w) })
        #expect(!lb(&lib) { $0.rename("Audio", to: "other") })
        #expect(!lb(&lib) { $0.rename("Editing – PC", to: "X") })
        #expect(!lb(&lib) { $0.rename("Audio", to: "Editing – MacBook") })
        #expect(!lb(&lib) { $0.delete("Editing – PC") })
        #expect(lb(&lib) { $0.delete("Audio") })
        #expect(!lb(&lib) { $0.delete("Audio") })
        #expect(lib.names == Workspace.builtIns.map(\.name) + ["Other"])
    }

    @Test func builtInOverrideAndReset() {
        var lib = WorkspaceLibrary()
        var w = Workspace.editingPC
        w.hide(.effects)
        #expect(lb(&lib) { $0.update(w) })
        #expect(lib.isModifiedBuiltIn("Editing – PC"))
        #expect(lib.workspace(named: "Editing – PC")?.hidden == [.effects, .colorInspector, .scopes])
        #expect(lib.names.count == Workspace.builtIns.count)
        #expect(lb(&lib) { $0.resetBuiltIn("Editing – PC") })
        #expect(lib.workspace(named: "Editing – PC") == Workspace.editingPC)
        #expect(!lb(&lib) { $0.resetBuiltIn("Editing – PC") })
        #expect(!lb(&lib) { $0.update(Workspace(name: "nope", root: .tabs(panels: [.timeline], selected: .timeline))) })
    }

    @Test func jsonRoundTripAndVersion() throws {
        var lib = WorkspaceLibrary()
        lib.saveAs("Mine", from: .editingMacBook)
        var w = Workspace.editingPC; w.hide(.text); lib.update(w)
        let data = try lib.encoded()
        #expect(try WorkspaceLibrary.decoded(from: data) == lib)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"version\" : 1"))
        let future = text.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
        #expect(throws: WorkspaceLibrary.LoadError.unsupportedVersion(99)) { try WorkspaceLibrary.decoded(from: Data(future.utf8)) }
        #expect(throws: (any Error).self) { try WorkspaceLibrary.decoded(from: Data("{}".utf8)) }
    }
}

struct SplitMix {
    var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func dk(_ w: inout Workspace, _ p: PanelID, onto t: PanelID, zone: DropZone) -> Bool { w.dock(p, onto: t, zone: zone) }
private func mv(_ w: inout Workspace, _ p: PanelID, toIndex i: Int) -> Bool { w.moveTab(p, toIndex: i) }
private func lb(_ l: inout WorkspaceLibrary, _ f: (inout WorkspaceLibrary) -> Bool) -> Bool { f(&l) }
