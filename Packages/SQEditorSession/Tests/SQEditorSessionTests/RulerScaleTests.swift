import Foundation
import SQCore
import Testing
@testable import SQEditorSession

@Suite struct RulerTimecodeFormatTests {
    let df = TimecodeFormat(frameDuration: Time(1001, 30000))
    let ndf = TimecodeFormat(frameDuration: Time(1001, 30000), preferDropFrame: false)
    let f25 = TimecodeFormat(frameDuration: Time(1, 25))

    @Test func startFrameShiftsLabelsAndFramesDisplayCounts() {
        var f = f25
        f.startFrame = 25 * 3600
        #expect(f.string(forFrame: 0) == "01:00:00:00" && f.string(forFrame: 26) == "01:00:01:01")
        f.framesOnly = true
        #expect(f.string(forFrame: 26) == String(25 * 3600 + 26))
    }

    @Test func formatDetection() {
        #expect(df.nominalFPS == 30 && df.dropFrame)
        #expect(ndf.nominalFPS == 30 && !ndf.dropFrame)
        #expect(f25.nominalFPS == 25 && !f25.dropFrame)
        let f2398 = TimecodeFormat(frameDuration: Time(1001, 24000))
        #expect(f2398.nominalFPS == 24 && !f2398.dropFrame)
        let f5994 = TimecodeFormat(frameDuration: Time(1001, 60000))
        #expect(f5994.nominalFPS == 60 && f5994.dropFrame)
        let f30 = TimecodeFormat(frameDuration: Time(1, 30), preferDropFrame: true)
        #expect(!f30.dropFrame)
    }

    @Test func nonDrop2997() {
        #expect(ndf.string(forFrame: 0) == "00:00:00:00")
        #expect(ndf.string(forFrame: 29) == "00:00:00:29")
        #expect(ndf.string(forFrame: 30) == "00:00:01:00")
        #expect(ndf.string(forFrame: 1800) == "00:01:00:00")
        #expect(ndf.string(forFrame: 108_000) == "01:00:00:00")
    }

    @Test func dropFrame2997() {
        #expect(df.string(forFrame: 0) == "00:00:00;00")
        #expect(df.string(forFrame: 1799) == "00:00:59;29")
        #expect(df.string(forFrame: 1800) == "00:01:00;02")      // frames 00 and 01 skipped
        #expect(df.string(forFrame: 1801) == "00:01:00;03")
        #expect(df.string(forFrame: 3597) == "00:01:59;29")
        #expect(df.string(forFrame: 3598) == "00:02:00;02")
        #expect(df.string(forFrame: 17_981) == "00:09:59;29")
        #expect(df.string(forFrame: 17_982) == "00:10:00;00")    // every tenth minute keeps its frames
        #expect(df.string(forFrame: 17_983) == "00:10:00;01")
        #expect(df.string(forFrame: 107_892) == "01:00:00;00")    // one real hour of 29.97 = 107892 frames
    }

    @Test func dropFrame5994() {
        let f = TimecodeFormat(frameDuration: Time(1001, 60000))
        #expect(f.string(forFrame: 3599) == "00:00:59;59")
        #expect(f.string(forFrame: 3600) == "00:01:00;04")
        #expect(f.string(forFrame: 35_964) == "00:10:00;00")
    }

    @Test func rate25() {
        #expect(f25.string(forFrame: 24) == "00:00:00:24")
        #expect(f25.string(forFrame: 25) == "00:00:01:00")
        #expect(f25.string(forFrame: 90_000) == "01:00:00:00")
        #expect(f25.string(forFrame: 90_000 + 25 * 61 + 7) == "01:01:01:07")
    }

    @Test func fromTimeAndNegative() {
        let fd = Time(1, 25)
        #expect(f25.string(for: Time(3, 1), frameDuration: fd) == "00:00:03:00")
        #expect(f25.string(for: Time(3, 1) + Time(1, 50), frameDuration: fd) == "00:00:03:00")   // floor
        #expect(f25.string(forFrame: -26) == "-00:00:01:01")
    }
}

@Suite struct RulerScaleTests {
    @Test func zoomedInToFrames() {
        // 40 pt per frame: every frame is labeled... 96 pt needs 3 frames, candidate 5.
        let s = RulerScale.scale(pointsPerFrame: 40, nominalFPS: 25)
        #expect(s.majorFrames == 5)
        #expect(s.minorFrames == 1)
        #expect(RulerScale.scale(pointsPerFrame: 100, nominalFPS: 25).majorFrames == 1)
    }

    @Test func secondsMinutesHours() {
        // 25 fps, 4 pt/frame = 100 pt/s: labels every 1 s.
        #expect(RulerScale.scale(pointsPerFrame: 4, nominalFPS: 25).majorFrames == 25)
        // 40 pt/s: 2.4 s -> 5 s.
        #expect(RulerScale.scale(pointsPerFrame: 1.6, nominalFPS: 25).majorFrames == 125)
        // 1 pt/s: 96 s -> 120 s.
        #expect(RulerScale.scale(pointsPerFrame: 0.04, nominalFPS: 25).majorFrames == 3000)
        // 0.05 pt/s: 1920 s -> 1800 s too short (90 pt) -> 3600 s.
        #expect(RulerScale.scale(pointsPerFrame: 0.002, nominalFPS: 25).majorFrames == 90_000)
    }

    @Test func labelSpacingAlwaysHonoured() {
        for fps in [24, 25, 30, 60] {
            var ppf = 500.0
            while ppf > 0.0001 {
                let s = RulerScale.scale(pointsPerFrame: ppf, nominalFPS: fps)
                #expect(Double(s.majorFrames) * ppf >= 96)
                #expect(s.majorFrames % s.minorFrames == 0)
                ppf *= 0.83
            }
        }
    }

    @Test func minorTicksNeedRoom() {
        // Major 1 s at 100 pt/s: tenths of 10 pt would be 2.5 frames, not whole; 5 -> 5 frames, 20 pt.
        let s = RulerScale.scale(pointsPerFrame: 4, nominalFPS: 25)
        #expect(s.minorFrames == 5)
        // Tight zoom: minor spacing below 6 pt collapses to no minor ticks.
        let tight = RulerScale.scale(pointsPerFrame: 0.04, nominalFPS: 25)   // major 120 s = 3000 frames, 120 pt
        #expect(tight.minorFrames == tight.majorFrames || Double(tight.minorFrames) * 0.04 >= 6)
    }

    @Test func extremeZoomOutStillTerminates() {
        let s = RulerScale.scale(pointsPerFrame: 1e-9, nominalFPS: 30)
        #expect(Double(s.majorFrames) * 1e-9 >= 96)
    }
}
