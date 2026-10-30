import Testing
@testable import SQCore

@Suite struct CutDownPlannerTests {
    private func pt(_ s: Int64, _ name: String = "cut-down") -> Marker {
        Marker(time: Time(seconds: s), name: name, color: .green)
    }

    @Test func pointMarkersPairIntoRanges() {
        let r = CutDownPlanner.ranges(from: [pt(0), pt(10), pt(20), pt(35), pt(50, "intro")])
        #expect(r.map(\.range) == [TimeRange(start: Time(seconds: 0), end: Time(seconds: 10)),
                                   TimeRange(start: Time(seconds: 20), end: Time(seconds: 35))])
    }

    @Test func durationMarkerIsARangeAndColorCounts() {
        let m = Marker(time: Time(seconds: 5), name: "x", color: CutDownPlanner.cutDownColor, duration: Time(seconds: 4))
        #expect(CutDownPlanner.ranges(from: [m]).first?.range == TimeRange(start: Time(seconds: 5), duration: Time(seconds: 4)))
    }

    @Test func plansFillEachTargetInOrder() {
        // 20 s, 20 s, 25 s: 60 takes 20+20 (the 25 would be 65); 30 takes 20; 15 and 6 take nothing.
        let ms = [pt(0), pt(20), pt(100), pt(120), pt(200), pt(225)]
        let p = CutDownPlanner.plans(from: ms)
        #expect(p.map(\.targetSeconds) == [60, 30, 15, 6])
        #expect(p[0].ranges.count == 2 && p[0].duration == Time(seconds: 40) && p[0].status == .short)
        #expect(p[1].ranges.count == 1 && p[1].duration == Time(seconds: 20))
        #expect(p[2].status == .empty && p[3].status == .empty)
    }

    @Test func taggedRangesBelongToOneTarget() {
        let ms = [pt(0, "cut-down 15"), pt(15, "cut-down 15"), pt(30, "cut-down 6s"), pt(36)]
        let p = CutDownPlanner.plans(from: ms)
        #expect(p[0].status == .empty)
        #expect(p[2].duration == Time(seconds: 15) && p[2].status == .exact)
        #expect(p[3].duration == Time(seconds: 6) && p[3].status == .exact)
    }

    @Test func noMarkersMeansEmptyPlans() {
        #expect(CutDownPlanner.plans(from: []).allSatisfy { $0.status == .empty && $0.name.hasPrefix("Cut-down") })
    }
}
