import Testing
import SQCore
@testable import SQPlayback

@Suite struct PlayProbeTests {
    @Test func percentilesOfKnownValues() {
        let s = PlayProbe.Stats((1...100).map(Double.init))
        #expect(s.count == 100 && s.p50 == 50 && s.p95 == 95 && s.p99 == 99 && s.worst == 100)
        #expect(PlayProbe.Stats([]).count == 0)
    }

    @Test func seekStagesAreMeasuredFromT0() {
        let p = PlayProbe()
        p.begin("ruler", now: 10)
        p.note(.session, now: 10.001)
        p.note(.request, target: Time(5, 1), now: 10.002)
        #expect(p.awaitingFrame == Time(5, 1))
        p.note(.firstFrame, now: 10.050)
        p.note(.exact, now: 10.100)
        #expect(p.awaitingApply)
        p.note(.applied, now: 10.104)
        p.glass(at: 10.120)
        let d = p.completed()
        #expect(d.count == 1)
        #expect(abs(d[0].ms(.session)! - 1) < 0.001 && abs(d[0].ms(.exact)! - 100) < 0.001 && abs(d[0].ms(.glass)! - 120) < 0.001)
        #expect(p.awaitingFrame == nil)
    }

    @Test func commandWithoutBeginStartsAJumpAndFirstMarkWins() {
        let p = PlayProbe()
        p.note(.request, now: 1)                       // nothing pending: ignored
        #expect(p.awaitingFrame == nil)
        p.note(.session, now: 2)
        p.note(.request, target: Time(1, 1), now: 2.01)
        p.note(.request, target: Time(1, 1), now: 2.50)  // the exact seek of a scrub release: first mark stays
        p.note(.exact, now: 2.6); p.glass(at: 2.7)
        #expect(abs(p.completed()[0].ms(.request)! - 10) < 0.001)
    }

    @Test func glassNeverShownDoesNotComplete() {
        let p = PlayProbe()
        p.begin("x", now: 1); p.note(.request, target: .zero, now: 1.1); p.note(.exact, now: 1.2)
        p.glass(at: 0)
        #expect(p.completedCount == 0)
    }
}
