import AppKit
import Testing
@testable import SQMonitorUI

@Suite struct MeterBallisticsTests {
    @Test func dBMappingAndClamp() {
        #expect(MeterBallistics.dB(fromLinear: 1) == 0)
        #expect(abs(MeterBallistics.dB(fromLinear: 0.5) - (-6.0206)) < 0.001)
        #expect(MeterBallistics.dB(fromLinear: 0) == -60)
        #expect(MeterBallistics.dB(fromLinear: 1e-9) == -60)
        #expect(MeterBallistics.position(dB: -60) == 0 && MeterBallistics.position(dB: 0) == 1)
        #expect(MeterBallistics.position(dB: 6) == 1 && MeterBallistics.position(dB: -90) == 0)
        // Board scale: the labels sit at 0.211 / 0.436 / 0.661 / 0.848 of the bar height (non-linear taper).
        #expect(abs(MeterBallistics.position(dB: -30) - 0.211) < 1e-6)
        #expect(abs(MeterBallistics.position(dB: -12) - 0.661) < 1e-6)
        #expect(abs(MeterBallistics.position(dB: -6) - 0.848) < 1e-6)
    }

    @Test func zones() {
        #expect(MeterBallistics.zone(dB: -40) == .green)
        #expect(MeterBallistics.zone(dB: -8.5) == .green)
        #expect(MeterBallistics.zone(dB: -8) == .yellow)
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

    @Test func silenceDropsToZeroAtOnceButKeepsClip() {
        var m = MeterBallistics()
        m.update(peak: 1, at: 0)
        m.silence()
        #expect(m.levelDB == -60 && m.holdDB == -60 && m.isSettled)
        #expect(m.clipped)
    }

    @Test func silentSignalWhilePlayingIsZeroAtOnce() {
        var m = MeterBallistics()
        m.update(peak: 0.5, at: 0)
        m.update(peak: 0, at: 0.03, isSignal: true)             // buffer of digital silence: no slow fall
        #expect(m.levelDB == -60 && m.holdDB == -60)
        m.update(peak: 0.5, at: 0.1)
        m.update(peak: 0.25, at: 0.13)                           // quieter sound: still falls by ballistics
        #expect(m.levelDB > -60 && m.holdDB > -60)
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

    @Test func stoppedEngineZeroesBarsInstantly() {
        let v = AudioMeterView(frame: NSRect(x: 0, y: 0, width: 40, height: 200))
        var t = 0.0
        v.clock = { t }
        v.update(peaks: [0.5, 0.5])
        t = 0.01
        v.silence()
        #expect(v.channels.allSatisfy { $0.levelDB == -60 && $0.holdDB == -60 })
    }

    @Test func drawsWithoutCrashing() {
        let v = AudioMeterView(frame: NSRect(x: 0, y: 0, width: 40, height: 200))
        v.update(peaks: [0.3, 0.9])
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        #expect(rep.pixelsWide > 0)
    }
}


@Suite struct MeterFeedTests {
    private let o1 = NSObject(), o2 = NSObject()   // alive, so the identities differ
    private var e1: ObjectIdentifier { ObjectIdentifier(o1) }
    private var e2: ObjectIdentifier { ObjectIdentifier(o2) }

    @Test func feedsOnlyNewBuffers() {
        var feed = MeterFeed()
        #expect(feed.peaks(for: nil) == nil)                               // no audio engine
        #expect(feed.peaks(for: (e1, 5, [0.5, 0.25])) == [0.5, 0.25])
        #expect(feed.peaks(for: (e1, 5, [0.5, 0.25])) == nil)              // same buffer again: let the bars fall
        #expect(feed.peaks(for: (e1, 6, [0.1, 0.1])) == [0.1, 0.1])
    }

    @Test func aRestartedCounterIsANewBuffer() {
        var feed = MeterFeed()
        _ = feed.peaks(for: (e1, 900, [1, 1]))
        #expect(feed.peaks(for: (e1, 1, [0.3, 0.3])) == [0.3, 0.3])
    }

    @Test func aNewEngineWithTheSameCounterIsNotSuppressed() {
        var feed = MeterFeed()
        _ = feed.peaks(for: (e1, 5, [1, 1]))
        #expect(feed.peaks(for: (e2, 5, [0.2, 0.2])) == [0.2, 0.2])
    }
}


@MainActor @Suite struct AudioMeterPanelTests {
    @Test func barsGoToZeroWhenNoNewBufferArrives() {
        let o = NSObject()
        let panel = AudioMeterPanelView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        var t = 0.0
        panel.clock = { t }
        var seq = 1
        panel.reading = { (ObjectIdentifier(o), seq, [0.5, 0.5]) }
        panel.poll()
        #expect(panel.meter.channels[0].levelDB > -10)
        t = 0.05; seq = 2
        panel.poll()
        #expect(panel.meter.channels[0].levelDB > -10)           // still playing
        t = 0.3                                                  // paused: same buffer
        panel.poll()
        #expect(panel.meter.channels[0].levelDB == -60 && panel.meter.channels[0].holdDB == -60)
    }

    @Test func meterIsCentredAboveTheMonitorStrip() {
        let panel = AudioMeterPanelView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        panel.layout()
        #expect(panel.meter.frame.height == 400 - AudioMeterPanelView.monitorStripHeight && panel.meter.frame.width == AudioMeterView.width)
        // The peak bars and the loudness columns beside them are centered together as one group.
        let group = panel.meter.frame.union(panel.loudness.frame)
        #expect(abs(group.midX - 150) <= 0.5)
    }
}

@MainActor @Suite struct MonoMeterTests {
    @Test func monoShowsOneBarOfTheLouderSide() {
        let v = AudioMeterView(frame: NSRect(x: 0, y: 0, width: 48, height: 200))
        #expect(v.channels.count == 2 && v.channelNames == ["L", "R"])
        v.isMono = true
        #expect(v.channels.count == 1 && v.channelNames == ["M"])
        v.update(peaks: [0.25, 0.5])
        #expect(v.channels.count == 1 && abs(v.channels[0].levelDB + 6.02) < 0.01)
        v.isMono = false
        #expect(v.channels.count == 2)
    }
}

@Suite struct MeterStyleTests {
    @Test func standardMatchesTheOldConstants() {
        #expect(MeterStyle.standard.fallDBPerSecond == MeterBallistics.barFallDBPerSecond)
        #expect(MeterStyle.standard.holdSeconds == MeterBallistics.holdSeconds)
    }

    @Test func fastFallsQuickerAndSmoothSlower() {
        func level(_ s: MeterStyle) -> Float {
            var m = MeterBallistics(style: s)
            m.update(peak: 1, at: 0)
            m.update(peak: 0, at: 0.25)
            return m.levelDB
        }
        #expect(level(.fast) < level(.standard) && level(.standard) < level(.smooth))
        #expect(abs(level(.fast) - (-15)) < 0.01 && abs(level(.smooth) - (-3)) < 0.01)
    }

    @Test func holdTimeFollowsTheStyle() {
        func hold(_ s: MeterStyle, at t: Double) -> Float {
            var m = MeterBallistics(style: s)
            m.update(peak: 0.5, at: 0)
            m.update(peak: 0, at: t)
            return m.holdDB
        }
        let peak = hold(.standard, at: 0.1)
        #expect(hold(.fast, at: 0.4) == peak)           // still held
        #expect(hold(.fast, at: 1.0) < peak)            // fast released after 0.5 s
        #expect(hold(.standard, at: 1.0) == peak)       // standard still holds
        #expect(hold(.smooth, at: 2.5) == peak)         // smooth holds for 3 s
    }

    @Test func settingIsReadAndFallsBackToStandard() {
        let d = UserDefaults(suiteName: "sq.test.meterstyle.\(UUID().uuidString)")!
        #expect(MeterStyle.current(d) == .standard)
        d.set("fast", forKey: MeterStyle.defaultsKey)
        #expect(MeterStyle.current(d) == .fast)
        d.set("zzz", forKey: MeterStyle.defaultsKey)
        #expect(MeterStyle.current(d) == .standard)
    }
}
