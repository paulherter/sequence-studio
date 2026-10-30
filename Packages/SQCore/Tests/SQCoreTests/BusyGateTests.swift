import Testing
@testable import SQCore

@Suite struct BusyGateTests {
    @Test func refusesWhileBusyAndResetsOnLeave() {
        var g = BusyGate()
        let a = g.enter(), b = g.enter()
        g.leave()
        let c = g.enter()
        #expect(a && !b && c)
    }

    @Test func deferResetsAfterEarlyExit() {
        var g = BusyGate()
        func run(_ g: inout BusyGate, fail: Bool) -> Bool {
            guard g.enter() else { return false }
            defer { g.leave() }
            if fail { return true }
            return true
        }
        let first = run(&g, fail: true)
        let busy = g.isBusy
        let second = run(&g, fail: false)
        #expect(first && !busy && second)
    }
}
