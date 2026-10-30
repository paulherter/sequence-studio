import Testing
import SQMedia
@testable import SQEditorSession

@Suite struct MonitorQualityMappingTests {
    @Test func mapsToAndFromDecodeScale() {
        for q in [MonitorQuality.full, .half, .quarter] {
            #expect(MonitorQuality(q.decodeScale) == q)
        }
        #expect(MonitorQuality.half.decodeScale == .half)
        #expect(MonitorQuality.quarter.decodeScale == .quarter)
        #expect(MonitorQuality.full.decodeScale == .full)
    }
}
