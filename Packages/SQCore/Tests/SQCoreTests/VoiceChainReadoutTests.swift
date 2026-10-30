import Testing
@testable import SQCore

@Suite struct VoiceChainReadoutTests {
    @Test func reportsDeltaToTheDialogueTarget() {
        let r = VoiceChainReadout(measuredLUFS: [-20, -20])
        #expect(r != nil)
        #expect(abs(r!.lufs - -20) < 0.001)
        #expect(r!.targetLUFS == AudioTag.dialogue.targetLUFS)
        #expect(abs(r!.deltaLU - (-6)) < 0.001)
        #expect(r!.status == .quiet)
    }

    @Test func statusBands() {
        #expect(VoiceChainReadout(measuredLUFS: [-14.5])!.status == .onTarget)
        #expect(VoiceChainReadout(measuredLUFS: [-9])!.status == .loud)
        #expect(VoiceChainReadout(measuredLUFS: [-30])!.status == .quiet)
    }

    @Test func silenceAndUnmeasuredClipsAreIgnored() {
        #expect(VoiceChainReadout(measuredLUFS: []) == nil)
        #expect(VoiceChainReadout(measuredLUFS: [nil, -80, .infinity]) == nil)
        let r = VoiceChainReadout(measuredLUFS: [nil, -16, -90])
        #expect(abs(r!.lufs - -16) < 0.001)
    }

    @Test func unequalClipsMixByEnergy() {
        // -10 and -20 LUFS: energy mean is about -12.6, not the dB average -15.
        let r = VoiceChainReadout(measuredLUFS: [-10, -20])!
        #expect(abs(r.lufs - -12.6) < 0.05)
    }

    @Test func textFormatsOneDecimalWithSignedDelta() {
        let r = VoiceChainReadout(measuredLUFS: [-19.2])!
        #expect(r.lufsText == "-19.2")
        #expect(r.deltaText == "-5.2")
        #expect(VoiceChainReadout(measuredLUFS: [-12.0])!.deltaText == "+2.0")
    }
}
