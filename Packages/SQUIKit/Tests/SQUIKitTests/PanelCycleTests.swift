import Testing
@testable import SQUIKit

@Suite struct PanelCycleTests {
    @Test func stepsAndWraps() {
        let p: [PanelID] = [.project, .timeline, .programMonitor]
        #expect(PanelCycle.step(from: .project, in: p, forward: true) == .timeline)
        #expect(PanelCycle.step(from: .programMonitor, in: p, forward: true) == .project)
        #expect(PanelCycle.step(from: .project, in: p, forward: false) == .programMonitor)
    }
    @Test func unknownOrNoFocusStartsAtTheEnds() {
        let p: [PanelID] = [.project, .timeline]
        #expect(PanelCycle.step(from: nil, in: p, forward: true) == .project)
        #expect(PanelCycle.step(from: .scopes, in: p, forward: false) == .timeline)
        #expect(PanelCycle.step(from: .project, in: [], forward: true) == nil)
    }
    @Test func defaultKeysAreBoundAndSupported() {
        #expect(CommandSupport.isShellCommand(.selectNextPanel) && CommandSupport.isShellCommand(.selectPreviousPanel))
        #expect(CommandMap.current.binding(for: .selectNextPanel) != nil)
    }
}
