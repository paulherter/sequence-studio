import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

@Suite struct SequenceTabsTests {
    @Test func openAddsAndActivates() {
        var t = SequenceTabs()
        t.open(a); t.open(b)
        #expect(t.tabs.map(\.root) == [a, b])
        #expect(t.current == b)
        t.open(a)   // already open: only activates
        #expect(t.tabs.count == 2)
        #expect(t.current == a)
    }

    @Test func closeActivatesNeighbour() {
        var t = SequenceTabs()
        t.open(a); t.open(b); t.open(c)
        t.select(b)
        #expect(t.close(b) == c)         // the one to the right
        #expect(t.current == c)
        #expect(t.close(c) == a)         // last one: the left neighbor
        #expect(t.close(a) == nil)
        #expect(t.tabs.isEmpty && t.current == nil)
    }

    @Test func closingInactiveTabKeepsActive() {
        var t = SequenceTabs()
        t.open(a); t.open(b); t.open(c)
        #expect(t.close(a) == c)
        #expect(t.current == c)
    }

    @Test func enterNestedBuildsBreadcrumb() {
        var t = SequenceTabs()
        t.open(a)
        t.enter(b); t.enter(c)
        #expect(t.current == c)
        #expect(t.breadcrumb == [a, b, c])
        #expect(t.tabs.count == 1)
        t.enter(c)                       // already there
        #expect(t.breadcrumb == [a, b, c])
        t.popTo(a)
        #expect(t.current == a && t.breadcrumb == [a])
    }

    @Test func selectTabShowsItsOwnPath() {
        var t = SequenceTabs()
        t.open(a); t.enter(b)
        t.open(c)
        t.select(a)
        #expect(t.current == b)
        #expect(t.breadcrumb == [a, b])
    }

    @Test func openOfSequenceInsideAPathActivatesThatTab() {
        var t = SequenceTabs()
        t.open(a); t.enter(b); t.open(c)
        t.open(b)
        #expect(t.tabs.count == 2)
        #expect(t.current == b && t.breadcrumb == [a, b])
    }

    @Test func openRootCutsItsPath() {
        var t = SequenceTabs()
        t.open(a); t.enter(b); t.open(c)
        t.open(a)
        #expect(t.current == a && t.breadcrumb == [a])
    }

    @Test func enterCycleTruncatesPath() {
        var t = SequenceTabs()
        t.open(a); t.enter(b); t.enter(c)
        t.enter(b)
        #expect(t.breadcrumb == [a, b])
    }

    @Test func moveReordersAndKeepsActiveTab() {
        var t = SequenceTabs()
        t.open(a); t.open(b); t.open(c)          // c active
        t.move(a, to: 2)
        #expect(t.tabs.map(\.root) == [b, c, a])
        #expect(t.current == c)
        t.move(a, to: 99); t.move(c, to: -5)
        #expect(t.tabs.map(\.root) == [c, b, a])
        #expect(t.current == c)
    }

    @Test func groupsAreNeverRootTabs() {
        var t = SequenceTabs()
        t.open(a); t.open(b)
        t.prune(existing: [a, b], rootable: [a])
        #expect(t.tabs.map(\.root) == [a])
        #expect(t.current == a)
    }

    @Test func pruneDropsDeletedSequences() {
        var t = SequenceTabs()
        t.open(a); t.enter(b); t.enter(c); t.open(d)
        t.prune(existing: [a, b, d])     // c gone
        #expect(t.tabs[0].path == [a, b])
        t.prune(existing: [b, d])        // a gone: tab a closes
        #expect(t.tabs.map(\.root) == [d])
        #expect(t.current == d)
        t.prune(existing: [])
        #expect(t.current == nil)
    }
}

@MainActor @Suite struct SequenceTabsSessionTests {
    private func session() -> (EditorSession, Timeline.ID) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        return (s, t.id)
    }

    @Test func startsWithActiveSequenceTab() {
        let (s, id) = session()
        #expect(s.sequenceTabs.tabs.map(\.root) == [id])
    }

    @Test func newSequenceOpensTabAndSwitchingKeepsBoth() {
        let (s, main) = session()
        let two = s.addSequence()
        #expect(s.sequenceTabs.tabs.map(\.root) == [main, two])
        #expect(s.activeTimelineID == two)
        s.selectSequenceTab(root: main)
        #expect(s.activeTimelineID == main)
        s.openSequenceTab(two)
        #expect(s.sequenceTabs.tabs.count == 2 && s.activeTimelineID == two)
    }

    @Test func closeKeepsLastTabAndActivatesNeighbour() {
        let (s, main) = session()
        let two = s.addSequence()
        s.closeSequenceTab(root: two)
        #expect(s.activeTimelineID == main)
        s.closeSequenceTab(root: main)
        #expect(s.sequenceTabs.tabs.count == 1)
    }

    @Test func doubleClickOnNestedSequenceOpensItAsTabAndWayBackIsTheTab() {
        let (s, main) = session()
        let inner = s.addSequence()
        s.closeSequenceTab(root: inner)
        #expect(s.sequenceTabs.tabs.map(\.root) == [main])
        s.enterNestedSequence(inner)
        #expect(s.activeTimelineID == inner)
        #expect(s.sequenceTabs.tabs.map(\.root) == [main, inner])
        #expect(s.sequenceTabs.breadcrumb == [inner])
        s.selectSequenceTab(root: main)
        #expect(s.activeTimelineID == main)
        // Same result as the project panel's double-click.
        s.enterNestedSequence(inner)
        #expect(s.sequenceTabs.tabs.count == 2 && s.activeTimelineID == inner)
    }

    @Test func groupsStillDrillIntoTheActiveTab() throws {
        let (s, main) = session()
        var g = Timeline(name: "G", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        g.group = TimelineGroup(sourceTracks: [:])
        s.newProject(Project(name: "P", timelines: [try #require(s.project.timeline(main)), g]))
        s.enterNestedSequence(g.id)
        #expect(s.sequenceTabs.tabs.count == 1)
        #expect(s.sequenceTabs.breadcrumb == [main, g.id])
        s.popSequence(to: main)
        #expect(s.activeTimelineID == main && s.sequenceTabs.breadcrumb == [main])
    }

    @Test func newProjectResetsTabs() {
        let (s, main) = session()
        _ = s.addSequence()
        let t2 = Timeline(name: "Other", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        s.newProject(Project(name: "Q", timelines: [t2]))
        #expect(s.sequenceTabs.tabs.map(\.root) == [t2.id])
        #expect(!s.sequenceTabs.tabs.map(\.root).contains(main))
    }

    @Test func deletingActiveSequenceFallsBackToTabNeighbour() throws {
        let (s, main) = session()
        let two = s.addSequence()
        let three = s.addSequence()
        s.selectSequenceTab(root: two)
        try s.perform("Delete Sequence") { p in p.timelines.removeAll { $0.id == two } }
        #expect(s.activeTimelineID == three)
        #expect(s.sequenceTabs.tabs.map(\.root) == [main, three])
    }

    @Test func groupSequenceNeverBecomesATab() throws {
        let (s, main) = session()
        var inner = Timeline(name: "Group 01", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        inner.group = TimelineGroup(sourceTracks: [:])
        try s.perform("Add Group") { p in p.timelines.append(inner) }
        s.enterNestedSequence(inner.id)
        #expect(s.sequenceTabs.tabs.map(\.root) == [main])          // shown in the breadcrumb of the Main tab
        #expect(s.sequenceTabs.breadcrumb == [main, inner.id])
        s.openSequenceTab(main)
        #expect(s.sequenceTabs.tabs.map(\.root) == [main])
    }

    @Test func movingTabsKeepsActiveSequence() {
        let (s, main) = session()
        let two = s.addSequence()
        s.moveSequenceTab(root: two, to: 0)
        #expect(s.sequenceTabs.tabs.map(\.root) == [two, main])
        #expect(s.activeTimelineID == two)
    }
}
