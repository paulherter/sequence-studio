import Testing
import CoreGraphics
@testable import SQUIKit

@Suite struct SQFlyToIndicatorTests {
    let source = CGRect(x: 100, y: 200, width: 800, height: 600)
    let target = CGRect(x: 1400, y: 4, width: 20, height: 20)   // bottom right (non-flipped: low y)

    var plan: SQFlyToIndicator.Plan { SQFlyToIndicator.plan(source: source, target: target, reduceMotion: false) }

    @Test func startsOnCardAndLandsExactlyOnTarget() {
        let p = plan
        #expect(p.flies)
        #expect(p.positions.first == CGPoint(x: source.midX, y: source.midY))
        let end = p.positions.last!
        #expect(abs(end.x - target.midX) < 0.001 && abs(end.y - target.midY) < 0.001)
        #expect(p.scaleX.first == 1 && p.scaleY.first == 1)
        #expect(abs(p.scaleX.last! - 20.0 / 800) < 1e-9 && abs(p.scaleY.last! - 20.0 / 600) < 1e-9)
        #expect(p.opacity.last! == 0 && p.rotation.last!.magnitude < 1e-9)
    }

    @Test func totalWithinBriefAndPulseOverlapsLanding() {
        let p = plan
        #expect(p.total >= 0.45 && p.total <= 0.6)
        #expect(p.pulseBegin < p.cardDuration && p.pulseGrowth > 1)
    }

    @Test func tracksShareMonotonicKeyTimes() {
        let p = plan
        #expect(p.keyTimes.first == 0 && p.keyTimes.last == 1)
        #expect(zip(p.keyTimes, p.keyTimes.dropFirst()).allSatisfy { $0 < $1 })
        for n in [p.positions.count, p.scaleX.count, p.scaleY.count, p.rotation.count, p.opacity.count, p.tint.count,
                  p.shadow.count, p.cornerRadius.count] {
            #expect(n == p.keyTimes.count)
        }
    }

    @Test func pressDipsThenShrinksWithoutGrowingBack() {
        let p = plan
        let pressEnd = p.keyTimes.lastIndex { $0 <= SQFlyToIndicator.pressShare }!
        #expect(p.scaleX[pressEnd] < 0.98 && p.scaleX[pressEnd] > 0.96)
        #expect(p.scaleY[pressEnd] < p.scaleX[pressEnd])            // squash: Y dips more
        #expect(p.positions[pressEnd] == p.positions[0])            // no travel during the press
        for i in 1..<p.scaleX.count {
            #expect(p.scaleX[i] <= p.scaleX[i - 1] + 1e-12 && p.scaleY[i] <= p.scaleY[i - 1] + 1e-12)
        }
    }

    @Test func smoothTravelWithoutBacktrackingOrJitter() {
        let p = plan
        // X only ever moves toward the target; step lengths rise then fall once (no velocity jitter).
        for i in 1..<p.positions.count { #expect(p.positions[i].x >= p.positions[i - 1].x) }
        let steps = zip(p.positions, p.positions.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let moving = steps.drop { $0 == 0 }
        let peak = moving.firstIndex(of: moving.max()!)!
        #expect(zip(moving[..<peak], moving[..<peak].dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
        #expect(zip(moving[peak...], moving[peak...].dropFirst()).allSatisfy { $0 >= $1 - 1e-9 })
    }

    @Test func arcLiftsAwayFromTargetFirst() {
        let c = plan.control
        #expect(c.x > source.midX && c.x < target.midX)
        #expect(c.y > source.midY - (source.midY - target.midY) * 0.15)   // lifted up against the dive
    }

    @Test func swayIsSlightAndFoldEndsAsPill() {
        let p = plan
        #expect(p.rotation.allSatisfy { $0.magnitude <= SQFlyToIndicator.maxSway + 1e-12 })
        #expect(p.rotation.contains { $0 < -0.02 })
        #expect(p.cornerRadius.last! == 300)
        #expect(p.tint.last! == 1 && p.shadow.last! == 0)
        let half = p.keyTimes.count / 2
        #expect(p.opacity[..<half].allSatisfy { $0 == 1 })
    }

    @Test func reduceMotionIsPlainCrossFade() {
        let p = SQFlyToIndicator.plan(source: source, target: target, reduceMotion: true)
        #expect(!p.flies && p.pulseGrowth == 1)
        #expect(p.positions.allSatisfy { $0 == p.positions[0] } && p.scaleX == [1, 1] && p.rotation == [0, 0])
        #expect(p.opacity == [1, 0] && p.cardDuration > 0 && p.cardDuration <= 0.25)
    }

    @Test func emptyFrameDoesNotFly() {
        #expect(!SQFlyToIndicator.plan(source: .zero, target: target, reduceMotion: false).flies)
        #expect(SQFlyToIndicator.plan(source: .zero, target: target, reduceMotion: false).cardDuration == 0)
        #expect(!SQFlyToIndicator.plan(source: source, target: .zero, reduceMotion: false).flies)
    }
}
