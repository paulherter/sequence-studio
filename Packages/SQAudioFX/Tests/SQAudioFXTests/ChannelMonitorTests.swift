import Testing
@testable import SQAudioFX

@Suite struct ChannelMonitorTests {
    @Test func neutralPassesBoth() {
        let m = ChannelMonitor()
        #expect(m.isNeutral)
        #expect(m.gains == [1, 1])
    }

    @Test func muteSilencesOnlyThatChannel() {
        var m = ChannelMonitor()
        m.toggleMute([0])
        #expect(m.gains == [0, 1])
        m.toggleMute([0])
        #expect(m.isNeutral)
    }

    @Test func soloSilencesTheOthers() {
        var m = ChannelMonitor()
        m.toggleSolo([1])
        #expect(m.gains == [0, 1])
        m.toggleSolo([0])
        #expect(m.gains == [1, 1])
        m.toggleSolo([0, 1])
        #expect(m.isNeutral)
    }

    @Test func muteBeatsSolo() {
        var m = ChannelMonitor()
        m.toggleSolo([0]); m.toggleMute([0])
        #expect(m.gains == [0, 0])
    }

    @Test func groupToggleForMonoBar() {
        var m = ChannelMonitor()
        m.toggleMute([0, 1])
        #expect(m.gains == [0, 0])
        m.toggleMute([0, 1])
        #expect(m.isNeutral)
    }

    @Test func outOfRangeChannelIsIgnored() {
        var m = ChannelMonitor()
        m.toggleMute([5, -1])
        #expect(m.isNeutral)
        #expect(m.isAudible(7))
        #expect(ChannelMonitor(muteMask: 0xFF, soloMask: 0).muteMask == 0b11)
    }

    @Test func clearResets() {
        var m = ChannelMonitor()
        m.toggleMute([0]); m.toggleSolo([1])
        m.clear()
        #expect(m.isNeutral)
    }

    @Test func rampIdentityAtUnityAndSilenceAtZero() {
        var a: [Float] = [0.5, -0.25, 1, 0.1]
        a.withUnsafeMutableBufferPointer { ChannelMonitor.applyRamp($0.baseAddress!, count: 4, from: 1, to: 1) }
        #expect(a == [0.5, -0.25, 1, 0.1])
        a.withUnsafeMutableBufferPointer { ChannelMonitor.applyRamp($0.baseAddress!, count: 4, from: 0, to: 0) }
        #expect(a == [0, 0, 0, 0])
    }

    @Test func rampFadesWithoutStep() {
        var a = [Float](repeating: 1, count: 4)
        a.withUnsafeMutableBufferPointer { ChannelMonitor.applyRamp($0.baseAddress!, count: 4, from: 1, to: 0) }
        #expect(a == [1, 0.75, 0.5, 0.25])
    }
}
