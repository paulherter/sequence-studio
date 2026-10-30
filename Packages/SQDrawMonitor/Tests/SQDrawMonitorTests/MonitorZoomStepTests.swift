import Foundation
import Testing
import SQCore
import SQDrawKit
@testable import SQDrawMonitor

@Suite struct MonitorZoomStepTests {
    @Test func zoomInWalksUpThePresets() {
        #expect(MonitorZoom.fit.stepped(zoomIn: true) == .percent(100))
        #expect(MonitorZoom.percent(100).stepped(zoomIn: true) == .percent(150))
        #expect(MonitorZoom.percent(800).stepped(zoomIn: true) == .percent(800))
    }

    @Test func zoomOutWalksDownAndEndsAtFit() {
        #expect(MonitorZoom.percent(100).stepped(zoomIn: false) == .percent(75))
        #expect(MonitorZoom.percent(10).stepped(zoomIn: false) == .fit)
        #expect(MonitorZoom.fit.stepped(zoomIn: false) == .fit)
    }

    @Test func pinchValuesStepToTheNextPresetBeyond() {
        #expect(MonitorZoom.custom(130).stepped(zoomIn: true) == .percent(150))
        #expect(MonitorZoom.custom(130).stepped(zoomIn: false) == .percent(100))
        #expect(MonitorZoom.custom(10).stepped(zoomIn: false) == .fit)
    }
}
