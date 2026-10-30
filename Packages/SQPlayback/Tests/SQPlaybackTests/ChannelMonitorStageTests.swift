import Testing
import SQAudioFX
@testable import SQPlayback

@Suite struct ChannelMonitorStageTests {
    private func block(_ v: Float, _ n: Int) -> [Float] { [Float](repeating: v, count: n) }

    @Test func neutralStageLeavesTheBlockUntouched() {
        let stage = ChannelMonitorStage()
        var l = block(0.5, 8), r = block(-0.25, 8)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            stage.process(left: lp.baseAddress!, right: rp.baseAddress!, count: 8)
        } }
        #expect(l == block(0.5, 8) && r == block(-0.25, 8))
    }

    @Test func muteSilencesAfterTheRampAndKeepsTheOtherChannel() {
        let stage = ChannelMonitorStage()
        var m = ChannelMonitor(); m.toggleMute([0]); stage.set(m)
        var l = block(1, 4), r = block(1, 4)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            stage.process(left: lp.baseAddress!, right: rp.baseAddress!, count: 4)     // ramps 1 -> 0
        } }
        #expect(r == block(1, 4))
        #expect(l[0] == 1 && l[3] < l[0])
        var l2 = block(1, 4), r2 = block(1, 4)
        l2.withUnsafeMutableBufferPointer { lp in r2.withUnsafeMutableBufferPointer { rp in
            stage.process(left: lp.baseAddress!, right: rp.baseAddress!, count: 4)     // settled
        } }
        #expect(l2 == block(0, 4) && r2 == block(1, 4))
    }

    @Test func soloKeepsOnlyTheSoloedChannel() {
        let stage = ChannelMonitorStage()
        var m = ChannelMonitor(); m.toggleSolo([1]); stage.set(m)
        for _ in 0..<2 {
            var l = block(1, 4), r = block(1, 4)
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                stage.process(left: lp.baseAddress!, right: rp.baseAddress!, count: 4)
            } }
            if l == block(0, 4) { #expect(r == block(1, 4)) }
        }
        #expect(stage.state.gains == [0, 1])
    }

    /// The meter reads the block before the stage: a muted channel still shows its level.
    @Test func meterStillSeesAMutedChannel() {
        let store = AudioMeterStore()
        let drain = MeterDrain(store: store)
        let stage = ChannelMonitorStage()
        var m = ChannelMonitor(); m.toggleMute([0, 1]); stage.set(m)
        let n = MeterDrain.bufferFrames
        for _ in 0..<2 {
            var l = block(0.5, n), r = block(0.25, n)
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                drain.push(left: lp.baseAddress!, right: rp.baseAddress!, count: n)
                stage.process(left: lp.baseAddress!, right: rp.baseAddress!, count: n)
            } }
        }
        #expect(drain.drainOnce() == 2)
        let s = store.snapshot
        #expect(s.left.peak == 0.5 && s.right.peak == 0.25 && s.sequence == 2)
    }

    @Test func manualAudioDefaultsNeutral() {
        #expect(ManualAudio().channelMonitorState.isNeutral)
    }
}
