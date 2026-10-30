import CoreGraphics
import Testing
@testable import SQEditorUI

@Suite struct SplashSceneTests {
    @Test func xMappingAndStations() {
        #expect(abs(SplashScene.X(36) - 52) < 0.001)
        #expect(abs(SplashScene.pose(at: 0).x - SplashScene.stations[0]) < 0.001)
        #expect(abs(SplashScene.pose(at: SplashScene.driveEnd).x - SplashScene.stations[4]) < 0.001)
    }

    @Test func clipsGrowBehindPipAndNeverShrink() {
        var last = [CGFloat](repeating: 0, count: SplashScene.clips.count)
        var t = 0.0
        while t <= SplashScene.endTime {
            for (i, c) in SplashScene.clips.enumerated() {
                let w = SplashScene.clipWidth(c, at: t)
                #expect(w >= last[i] - 0.0001)
                #expect(w <= c.end - c.start + 0.0001)
                last[i] = w
            }
            t += 0.02
        }
        // Approved design: clips follow Pip's furthest x + 8 and stay short of full at the end of the driving part.
        let far = SplashScene.stations[4] + 8
        for (i, c) in SplashScene.clips.enumerated() {
            #expect(abs(last[i] - max(0, min(c.end - c.start, far - c.start))) < 0.001)
        }
    }

    @Test func progressMapsToSceneTime() {
        #expect(SplashScene.tau(progress: 0, ready: false, readyElapsed: 0) == 0)
        #expect(SplashScene.tau(progress: 1, ready: false, readyElapsed: 0) == SplashScene.driveEnd)
        #expect(SplashScene.tau(progress: 1, ready: true, readyElapsed: 0.3) > SplashScene.driveEnd)
    }

    @Test func travelIsMonotoneWithoutStepsBack() {
        var prev = -CGFloat.infinity
        var t = 0.0
        while t <= SplashScene.endTime {
            let x = SplashScene.pose(at: t).x
            #expect(x >= prev)
            prev = x
            t += 0.01
        }
    }

    @Test func tipStandsOnRulerLine() {
        #expect(SplashScene.tipY == 322)
        #expect(SplashScene.pose(at: 0).y == 0)
    }
}
