import AppKit
import Testing
@testable import SSEditorUI

@Suite struct MeterBallisticsTests {
    @Test func dBMappingAndClamp() {
        #expect(MeterBallistics.dB(fromLinear: 1) == 0)
        #expect(abs(MeterBallistics.dB(fromLinear: 0.5) - (-6.0206)) < 0.001)
        #expect(MeterBallistics.dB(fromLinear: 0) == -60)
        #expect(MeterBallistics.dB(fromLinear: 1e-9) == -60)
        #expect(MeterBallistics.position(dB: -60) == 0 && MeterBallistics.position(dB: 0) == 1)
        #expect(MeterBallistics.position(dB: 6) == 1 && MeterBallistics.position(dB: -90) == 0)
        #expect(abs(MeterBallistics.position(dB: -30) - 0.5) < 1e-6)
    }

    @Test func zones() {
        #expect(MeterBallistics.zone(dB: -40) == .green)
        #expect(MeterBallistics.zone(dB: -12.5) == .green)
        #expect(MeterBallistics.zone(dB: -12) == .yellow)
        #expect(MeterBallistics.zone(dB: -3) == .yellow)
        #expect(MeterBallistics.zone(dB: -2.9) == .red)
    }

    @Test func attackInstantBarFalls() {
        var m = MeterBallistics()
        m.update(peak: 0.5, at: 0)
        #expect(abs(m.levelDB + 6.02) < 0.01)
        m.update(peak: 0, at: 0.25)
        #expect(abs(m.levelDB - (-6.02 - 6)) < 0.01)            // 24 dB/s * 0.25 s
        m.update(peak: 0, at: 10)
        #expect(m.levelDB == -60)
    }

    @Test func holdStaysThenFalls() {
        var m = MeterBallistics()
        m.update(peak: 0.5, at: 0)
        let held = m.holdDB
        m.update(peak: 0, at: 1.4)
        #expect(m.holdDB == held)
        m.update(peak: 0, at: 1.5)
        #expect(m.holdDB == held)
        m.update(peak: 0, at: 2.0)                               // 0.5 s past hold -> 12 dB down (bar already lower)
        #expect(abs(m.holdDB - (held - 12)) < 0.01)
        m.update(peak: 0.5, at: 2.1)                             // new peak restarts hold
        #expect(abs(m.holdDB - held) < 0.01)
        m.update(peak: 0, at: 3.5)
        #expect(abs(m.holdDB - held) < 0.01)
    }

    @Test func holdRestartsOnHigherPeakOnly() {
        var m = MeterBallistics()
        m.update(peak: 0.5, at: 0)
        m.update(peak: 0.25, at: 1.0)                            // lower: hold not restarted
        m.update(peak: 0, at: 1.6)
        #expect(m.holdDB < -6.02)
    }

    @Test func clipLatchesUntilReset() {
        var m = MeterBallistics()
        m.update(peak: 0.99, at: 0)
        #expect(!m.clipped)
        m.update(peak: 1.0, at: 0.1)
        m.update(peak: 0, at: 5)
        #expect(m.clipped)
        m.resetClip()
        #expect(!m.clipped)
    }

    @Test func settlesToFloor() {
        var m = MeterBallistics()
        m.update(peak: 1, at: 0)
        #expect(!m.isSettled)
        m.update(peak: 0, at: 1.5)
        m.update(peak: 0, at: 5)
        #expect(m.isSettled)
    }

    @Test func nonFiniteInputIsSafe() {
        var m = MeterBallistics()
        m.update(peak: .nan, at: 0)
        #expect(m.levelDB == -60)
    }
}

@MainActor @Suite struct AudioMeterViewTests {
    @Test func updateDrivesChannelsAndClipLatches() {
        let v = AudioMeterView(frame: NSRect(x: 0, y: 0, width: 40, height: 200))
        var t = 0.0
        v.clock = { t }
        v.update(peaks: [0.5, 1.0])
        #expect(v.channels.count == 2)
        #expect(v.channels[0].clipped == false && v.channels[1].clipped)
        t = 3
        v.update(peaks: [0, 0])
        #expect(v.channels[1].clipped)
        v.resetClip()
        #expect(!v.channels[1].clipped)
    }

    @Test func drawsWithoutCrashing() {
        let v = AudioMeterView(frame: NSRect(x: 0, y: 0, width: 40, height: 200))
        v.update(peaks: [0.3, 0.9])
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        #expect(rep.pixelsWide > 0)
    }
}
