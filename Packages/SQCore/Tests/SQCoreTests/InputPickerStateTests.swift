import Testing
@testable import SQCore

/// W9.3: state behind the inspector's camera / Log / SDR-HLG-PQ picker.
@Suite struct InputPickerStateTests {
    @Test func automaticHasNoSpace() {
        let s = InputPickerState(override: nil)
        #expect(s.camera == nil)
        #expect(s.space == nil)
    }

    @Test func everySpaceRoundTrips() {
        for id in ColorSpaceID.allCases {
            #expect(InputPickerState(override: id).space == id)
        }
    }

    @Test func choosingACameraWithLogSelectsItsLog() {
        var s = InputPickerState(override: nil)
        s.setCamera(.sony)
        #expect(s.space == .sLog3SGamut3Cine)
        s.setCamera(.panasonic)
        #expect(s.space == .vLogVGamut)
    }

    @Test func canonVariantsAreKeptAndResetByACameraChange() {
        var s = InputPickerState(override: nil)
        s.setCamera(.canon)
        #expect(s.space == .canonLog3CinemaGamut)
        s.setLogVariant(.canonLog2BT2020)
        #expect(s.space == .canonLog2BT2020)
        s.setLog(false)
        #expect(s.space == .rec709)
        s.setLog(true)
        #expect(s.space == .canonLog2BT2020)
        s.setLogVariant(.vLogVGamut)                 // not a Canon space: ignored
        #expect(s.space == .canonLog2BT2020)
        s.setCamera(.sony)
        #expect(s.space == .sLog3SGamut3Cine)
        s.setCamera(.canon)
        #expect(s.space == .canonLog3CinemaGamut)
        var auto = InputPickerState(override: nil)
        auto.setLogVariant(.canonLogBT709)
        #expect(auto.space == nil)
    }

    @Test func cameraWithoutLogFallsBackToSDR() {
        var s = InputPickerState(override: .sLog3SGamut3Cine)
        s.setCamera(.goPro)
        #expect(!s.log)
        #expect(s.space == .rec709)
        #expect(!s.logAvailable)
    }

    @Test func logOffKeepsTheRange() {
        var s = InputPickerState(override: .sLog3SGamut3Cine)
        s.setLog(false)
        #expect(s.space == .rec709)
        s.setRange(.hlg)
        #expect(s.space == .hlgBT2020)
        s.setRange(.pq)
        #expect(s.space == .pqBT2020)
    }

    @Test func logCannotBeTurnedOnWithoutACurve() {
        var s = InputPickerState(override: .rec709)
        s.setLog(true)
        #expect(!s.log)
        #expect(s.space == .rec709)
    }

    @Test func automaticIgnoresEdits() {
        var s = InputPickerState(override: nil)
        s.setLog(true); s.setRange(.hlg)
        #expect(s.space == nil)
    }

    @Test func settingNilCameraGoesBackToAutomatic() {
        var s = InputPickerState(override: .appleLog)
        s.setCamera(nil)
        #expect(s.space == nil)
    }
}
