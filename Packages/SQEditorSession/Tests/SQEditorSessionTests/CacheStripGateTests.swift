import Testing
import SQCore
@testable import SQEditorSession

@Suite struct CacheStripGateTests {
    private let span = TimeRange(start: Time(0, 1), end: Time(1, 1))

    @Test func firstLookFetchesThenWaitsForAChange() {
        var g = CacheStripGate(interval: 0.5)
        var calls = 0
        func look(_ now: Double, _ gen: Int) -> [TimeRange]? {
            g.spans(now: now, generation: gen, duration: Time(10, 1), undoName: nil) { calls += 1; return [span] }
        }
        #expect(look(0, 1) == [span])
        #expect(look(1, 1) == nil)          // nothing changed
        #expect(look(2, 2) == [span])       // the frame cache changed
        #expect(calls == 2)
    }

    @Test func throttlesWithinTheInterval() {
        var g = CacheStripGate(interval: 0.5)
        _ = g.spans(now: 0, generation: 1, duration: nil, undoName: nil) { [] }
        #expect(g.spans(now: 0.2, generation: 2, duration: nil, undoName: nil) { [span] } == nil)
        #expect(g.spans(now: 0.6, generation: 2, duration: nil, undoName: nil) { [span] } == [span])
    }

    @Test func sequenceLengthOrUndoStepRefetches() {
        var g = CacheStripGate(interval: 0)
        _ = g.spans(now: 0, generation: 1, duration: Time(1, 1), undoName: "a") { [] }
        #expect(g.spans(now: 1, generation: 1, duration: Time(2, 1), undoName: "a") { [span] } == [span])
        #expect(g.spans(now: 2, generation: 1, duration: Time(2, 1), undoName: "b") { [] } == [])
    }
}
