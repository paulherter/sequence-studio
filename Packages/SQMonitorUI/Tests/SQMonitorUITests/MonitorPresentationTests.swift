import Foundation
import Testing
import SQCore
import SQEditorSession
@testable import SQMonitorUI

@Suite struct RealtimeStateTests {
    @Test func fewDropsAreCountedButRealtimeHolds() {
        var d = DropIndicator()
        d.update(dropped: 0, isPlaying: true, now: 0)
        d.update(dropped: 2, isPlaying: true, now: 1)
        #expect(!d.realtimeNotAchieved)
        #expect(d.badgeText == "2 dropped")
    }

    @Test func manyDropsSetPersistentStateUntilNextRun() {
        var d = DropIndicator()
        d.update(dropped: 0, isPlaying: true, now: 0)
        d.update(dropped: DropIndicator.realtimeThreshold, isPlaying: true, now: 1)
        #expect(d.realtimeNotAchieved)
        #expect(d.badgeText == "Realtime not achieved · \(DropIndicator.realtimeThreshold) dropped")
        d.update(dropped: DropIndicator.realtimeThreshold, isPlaying: false, now: 60)   // stopped long ago: still there
        #expect(d.realtimeNotAchieved && d.badgeText != nil)
        d.update(dropped: DropIndicator.realtimeThreshold, isPlaying: true, now: 61)    // next run starts clean
        #expect(!d.realtimeNotAchieved && d.badgeText == nil)
    }

    @Test func noRunNoBadge() {
        #expect(DropIndicator().badgeText == nil)
    }
}

@MainActor @Suite struct MonitorPresentationTests {
    private func model(_ mode: MonitorMode = .program) -> MonitorPanelModel {
        MonitorPanelModel(frameDuration: Time(1, 30), mode: mode)
    }

    // MARK: Timecode hint

    @Test func acceptedFormsParseAndGarbageHasAHint() {
        let m = model()
        m.duration = Time(600, 1)
        m.currentTime = Time(5, 1)
        var seeks: [Time] = []
        m.onSeek = { seeks.append($0) }
        for text in ["123", "+10", "-10", "01:00:00:00"] { #expect(m.commitTimecodeText(text), "\(text)") }
        #expect(seeks.count == 4)
        #expect(!m.commitTimecodeText("abc"))
        let hint = MonitorPanelModel.timecodeHint(for: "abc")
        #expect(hint.contains("“abc”"))
        for form in ["123", "+10", "-10", "01:00:00:00"] { #expect(hint.contains(form)) }
    }

    @Test func emptyTextHasNoHint() {
        #expect(MonitorPanelModel.timecodeHint(for: "  ").isEmpty)
    }

    // MARK: Quality

    @Test func qualityMenuHasNoEighthSixteenthAndAutoShowsItsLevel() {
        let m = model()
        var titles = m.qualityMenu().compactMap { $0.title }
        #expect(!titles.contains("1/8") && !titles.contains("1/16"))
        #expect(titles.last == "Auto (Full)")
        m.setAutoBase(.half)
        m.setQuality(.auto)
        titles = m.qualityMenu().compactMap { $0.title }
        #expect(titles.last == "Auto (1/2)")
    }

    @Test func autoReportsTheResolvedQualityAndStepsDownOnDrops() {
        let m = model()
        var seen: [MonitorQuality] = []
        m.onQualityChange = { seen.append($0) }
        m.setAutoBase(.full)
        m.setQuality(.auto)
        #expect(m.quality == .auto && seen == [.full])
        #expect(m.qualityBadgeText == "Auto")
        m.updateDrops(dropped: 0, isPlaying: true, now: 0)
        m.updateDrops(dropped: AutoQualityGovernor.dropsPerStep, isPlaying: true, now: 1)
        #expect(seen.last == .half && m.effectiveQuality == .half)
        #expect(m.qualityBadgeText == "Auto · 1/2")
    }

    @Test func fixedQualityIgnoresDrops() {
        let m = model()
        var seen: [MonitorQuality] = []
        m.onQualityChange = { seen.append($0) }
        m.setQuality(.quarter)
        m.updateDrops(dropped: 0, isPlaying: true, now: 0)
        m.updateDrops(dropped: 100, isPlaying: true, now: 1)
        #expect(seen == [.quarter] && m.effectiveQuality == .quarter)
    }

    // MARK: Badge, grid, offline

    @Test func resolutionBadgeTextAndDefaultOff() {
        let m = model()
        let was = m.showsResolutionBadge
        defer { m.setShowsResolutionBadge(was) }
        m.setShowsResolutionBadge(false)
        m.pictureSize = (1080, 1920)
        #expect(m.resolutionBadgeText == nil)
        m.setShowsResolutionBadge(true)
        #expect(m.resolutionBadgeText == "1080 × 1920")
    }

    @Test func transparencyGridReportsChanges() {
        let m = model()
        var got: [Bool] = []
        m.onTransparencyGridChange = { got.append($0) }
        let before = m.showsTransparencyGrid
        defer { m.setShowsTransparencyGrid(before) }
        m.setShowsTransparencyGrid(!before)
        m.setShowsTransparencyGrid(before)
        #expect(got == [!before, before])
    }

    @Test func offlineCardTexts() {
        let m = model()
        #expect(m.offlineCardDetail == nil)
        m.offlineFileName = "A001.mov"
        #expect(m.offlineCardTitle == "Media offline")
        #expect(m.offlineCardDetail == "A001.mov was moved or renamed")
    }

    @Test func sourceMonitorGetsTheSameDropState() {
        let m = model(.source)
        m.updateDrops(dropped: 0, isPlaying: true, now: 0)
        m.updateDrops(dropped: 9, isPlaying: true, now: 1)
        #expect(m.dropRealtimeNotAchieved)
        #expect(m.dropBadgeText?.hasPrefix("Realtime not achieved") == true)
    }
}
