import Testing
import SSMedia
@testable import SSEditorUI

@Suite struct MonitorQualityMappingTests {
    @Test func mapsToAndFromDecodeScale() {
        for q in MonitorQuality.allCases {
            #expect(MonitorQuality(q.decodeScale) == q)
        }
        #expect(MonitorQuality.half.decodeScale == .half)
        #expect(MonitorQuality.quarter.decodeScale == .quarter)
        #expect(MonitorQuality.full.decodeScale == .full)
    }
}
