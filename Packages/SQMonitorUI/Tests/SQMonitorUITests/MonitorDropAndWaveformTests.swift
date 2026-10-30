import Testing
import AppKit
import SQCore
import SQMedia
@testable import SQMonitorUI

@Suite struct DropIndicatorTests {
    @Test func staysQuietWithoutDrops() {
        var d = DropIndicator()
        d.update(dropped: 0, isPlaying: true, now: 0)
        d.update(dropped: 0, isPlaying: true, now: 1)
        #expect(!d.isAmber(now: 1) && d.lastRunDrops == 0 && d.hasRun)
        #expect(d.tooltip == "Last play: no dropped frames")
    }

    @Test func amberForTwoSecondsAfterADrop() {
        var d = DropIndicator()
        d.update(dropped: 5, isPlaying: false, now: 0)          // old drops from before: not this run
        d.update(dropped: 5, isPlaying: true, now: 1)
        d.update(dropped: 7, isPlaying: true, now: 2)
        #expect(d.isAmber(now: 2) && d.isAmber(now: 3.9) && !d.isAmber(now: 4))
        #expect(d.lastRunDrops == 2 && d.tooltip == "Last play: 2 dropped frames")
    }

    @Test func newDropExtendsAndRunCountSurvivesPause() {
        var d = DropIndicator()
        d.update(dropped: 0, isPlaying: true, now: 0)
        d.update(dropped: 1, isPlaying: true, now: 1)
        d.update(dropped: 2, isPlaying: true, now: 2.5)
        #expect(d.isAmber(now: 4.4))
        d.update(dropped: 2, isPlaying: false, now: 3)
        #expect(d.lastRunDrops == 2 && d.tooltip == "Last play: 2 dropped frames")
        d.update(dropped: 2, isPlaying: true, now: 10)          // next run starts from zero
        #expect(d.lastRunDrops == 0 && !d.isAmber(now: 10))
    }

    @Test func dropsWhileNotPlayingAreIgnoredAndNewEngineRebases() {
        var d = DropIndicator()
        d.update(dropped: 0, isPlaying: false, now: 0)
        d.update(dropped: 3, isPlaying: false, now: 1)
        #expect(!d.isAmber(now: 1) && !d.hasRun)
        d.update(dropped: 3, isPlaying: true, now: 2)
        d.update(dropped: 1, isPlaying: true, now: 3)           // counter restarted (new engine)
        #expect(!d.isAmber(now: 3) && d.lastRunDrops == 0)
        d.update(dropped: 2, isPlaying: true, now: 4)
        #expect(d.isAmber(now: 4) && d.lastRunDrops == 1)
    }

    @Test func settingDefaultsOnAndRoundTrips() {
        #expect(AppSettings.standard.dropIndicator)
        let name = "sq-drop-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        var s = AppSettings.standard
        s.dropIndicator = false
        s.save(to: d)
        #expect(!AppSettings.load(from: d).dropIndicator)
    }

    @MainActor @Test func modelPublishesAmberAndTooltip() {
        let m = MonitorPanelModel(frameDuration: Time(1, 30))
        m.updateDrops(dropped: 0, isPlaying: true, now: 0)
        m.updateDrops(dropped: 4, isPlaying: true, now: 1)
        #expect(m.dropAmber && m.dropTooltip == "Last play: 4 dropped frames")
        m.updateDrops(dropped: 4, isPlaying: true, now: 3.5)
        #expect(!m.dropAmber)
    }
}

@MainActor @Suite struct SourceWaveformModeTests {
    @Test func resolveMode() {
        #expect(SourceViewerMode.resolve(isOpen: false, hasVideo: false, hasAudio: true) == .empty)
        #expect(SourceViewerMode.resolve(isOpen: true, hasVideo: false, hasAudio: true) == .waveform)
        #expect(SourceViewerMode.resolve(isOpen: true, hasVideo: true, hasAudio: true) == .picture)
        #expect(SourceViewerMode.resolve(isOpen: true, hasVideo: true, hasAudio: false) == .picture)
        // Nothing known about the streams: the picture path decides, never a blank waveform.
        #expect(SourceViewerMode.resolve(isOpen: true, hasVideo: false, hasAudio: false) == .picture)
    }

    @Test func panelSwitchesBetweenPictureAndWaveform() async {
        let m = MonitorPanelModel(frameDuration: Time(1, 30), mode: .source)
        let panel = MonitorPanelView(model: m)
        panel.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        panel.layoutSubtreeIfNeeded()
        #expect(!panel.isShowingWaveform)
        m.duration = Time(10, 1)
        m.viewerMode = .waveform
        m.sourceWaveform = WaveformData(sampleRate: 48_000, channelCount: 1, totalFrames: 480_000, baseBucketSize: 256,
                                        levels: [Array(repeating: Float(0.5), count: 2 * (480_000 / 256))].map { l in
                                            var o = l; for i in stride(from: 0, to: o.count, by: 2) { o[i] = -0.5 }; return o })
        m.currentTime = Time(5, 1)
        m.markIn = Time(2, 1)
        for _ in 0..<5 { await Task.yield() }                      // the panel re-reads the model on the next main-actor turn
        #expect(panel.isShowingWaveform)
        let v = panel.waveformView
        v.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)                      // draws peaks, In range and playhead without crashing
        m.viewerMode = .picture
        for _ in 0..<5 { await Task.yield() }
        #expect(!panel.isShowingWaveform)
    }

    @Test func scrubbingMapsXToTimeAndReports() {
        let m = MonitorPanelModel(frameDuration: Time(1, 30), mode: .source)
        m.duration = Time(10, 1)
        let v = SourceWaveformView(model: m)
        v.frame = NSRect(x: 0, y: 0, width: 616, height: 200)
        var began = 0, ended = 0
        var seen: [Time] = []
        m.onScrubBegan = { began += 1 }
        m.onScrub = { seen.append($0) }
        m.onScrubEnded = { ended += 1 }
        v.scrub(began: true, x: 308)
        v.scrub(began: false, x: 616)
        v.endScrub()
        #expect(began == 1 && ended == 1)
        #expect(seen.first == Time(5, 1))
        #expect(seen.last == Time(10, 1) - Time(1, 30))
    }
}
