import Testing
import Foundation
import SQRender
@testable import SQExport

@Suite struct HDRToSDRSettingTests {
    @Test func absentByDefaultAndRoundTrips() throws {
        var s = ExportSettings()
        #expect(s.hdrToSDR == nil)
        let plain = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(!plain.contains("hdrToSDR"))
        s.hdrToSDR = HDRToSDR(exposureStops: 0.5)
        let back = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(s))
        #expect(back.hdrToSDR == HDRToSDR(exposureStops: 0.5, compressesGamut: true))
    }

    @Test func appliesToToneMapping() {
        let t = HDRToSDR(exposureStops: 9, compressesGamut: true).applied(to: ToneMapping(knee: 0.7))
        #expect(t.knee == 0.7 && t.exposureStops == 4 && t.compressesGamut)
    }
}
