import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Zone Board and color-volume mask editing in the Color panel model.
@MainActor @Suite struct ZoneBoardPanelTests {
    @Test func firstEditCreatesTheBoardAndOnlyThatZoneChanges() {
        let m = ColorInspectorModel()
        var changes = 0
        m.onChange = { _ in changes += 1 }
        #expect(m.color.effect(1)?.zoneBoard == nil && m.zoneBoard(1).isNeutral)
        m.setZoneSaturation(1, .shadows, percent: 50)
        #expect(changes == 1)
        let b = m.zoneBoard(1)
        #expect(b.shadows.saturation == 0.25)
        #expect(b.global.isNeutral && b.midtones.isNeutral && b.highlights.isNeutral)
        #expect(m.zoneSaturationPercent(1, .shadows) == 50)
    }

    @Test func puckAndExposureRoundTrip() {
        let m = ColorInspectorModel()
        m.setZonePuck(1, .highlights, hue: 90, amount: 0.5)
        let w = m.zonePuckWheel(1, .highlights)
        #expect(abs(w.hue - 90) < 0.01 && abs(w.amount - 0.5) < 0.001)
        m.setZoneExposure(1, .highlights, slider: 1)
        #expect(m.zoneBoard(1).highlights.exposure == 1)
        m.setZoneExposure(1, .highlights, slider: -9)
        #expect(m.zoneBoard(1).highlights.exposure == 0, "clamped")
    }

    @Test func resetZoneWithoutABoardCreatesNothing() {
        let m = ColorInspectorModel()
        var changes = 0
        m.onChange = { _ in changes += 1 }
        m.resetZone(1, .global)
        #expect(changes == 0 && m.color.effect(1)?.zoneBoard == nil)
        m.setZoneSaturation(1, .global, percent: 150)
        m.resetZone(1, .global)
        #expect(m.zoneBoard(1).isNeutral)
    }

    @Test func colorVolumeModeShowsItsOwnRows() {
        #expect(ColorRangeParam.volumeRadius.isShown(in: .volume) && !ColorRangeParam.volumeRadius.isShown(in: .ranges))
        #expect(ColorRangeParam.satMin.isShown(in: .ranges) && !ColorRangeParam.satMin.isShown(in: .volume))
        #expect(ColorRangeParam.hueCenter.isShown(in: .volume) && ColorRangeParam.softness.isShown(in: .volume))
        #expect(ColorRangeParam.saturation.isCorrection && ColorRangeParam.saturation.isShown(in: .volume))
        let m = ColorInspectorModel()
        m.setRangeMaskMode(1, .volume)
        m.setRange(1, .volumeRadius, 60)
        #expect(m.rangeMaskMode(1) == .volume && m.rangeValue(1, .volumeRadius) == 60)
    }
}
