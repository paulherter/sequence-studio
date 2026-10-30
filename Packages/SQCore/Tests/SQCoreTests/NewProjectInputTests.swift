import Testing
import Foundation
@testable import SQCore

@Suite struct NewProjectInputTests {
    private let base = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30), audioSampleRate: 48_000)

    @Test func sizeInsideLimitsIsTaken() {
        let f = NewProjectInput.resolve(base: base, width: 3840, height: 2160, rateIndex: -1, sampleRate: nil)
        #expect(f.width == 3840 && f.height == 2160 && f.frameDuration == base.frameDuration)
    }
    @Test func sizeOutsideLimitsKeepsTemplate() {
        let m = SequenceFormatPresets.maxDimension
        for (w, h) in [(0, 1080), (1920, 0), (-5, -5), (m + 1, 1080), (1920, m + 1)] {
            let f = NewProjectInput.resolve(base: base, width: w, height: h, rateIndex: 0, sampleRate: nil)
            #expect(f.width == 1080 && f.height == 1920)
        }
        let edge = NewProjectInput.resolve(base: base, width: m, height: 1, rateIndex: 0, sampleRate: nil)
        #expect(edge.width == m && edge.height == 1)
    }
    @Test func rateAndSampleRate() {
        let i = SequenceFormatPresets.frameRates.count - 1
        let f = NewProjectInput.resolve(base: base, width: 1080, height: 1920, rateIndex: i, sampleRate: 44_100)
        #expect(f.frameDuration == SequenceFormatPresets.frameRates[i].frameDuration && f.audioSampleRate == 44_100)
        let bad = NewProjectInput.resolve(base: base, width: 1080, height: 1920, rateIndex: 999, sampleRate: 0)
        #expect(bad.frameDuration == base.frameDuration && bad.audioSampleRate == 48_000)
    }
    @Test func nameIsTrimmedWithDefault() {
        #expect(NewProjectInput.name(typed: "  My Film \n") == "My Film")
        #expect(NewProjectInput.name(typed: "   ") == NewProjectInput.defaultName)
        #expect(NewProjectInput.name(typed: "") == NewProjectInput.defaultName)
    }
}
