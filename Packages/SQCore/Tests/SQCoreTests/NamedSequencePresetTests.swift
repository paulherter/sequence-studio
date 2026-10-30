import Testing
@testable import SQCore

@Suite struct NamedSequencePresetTests {
    @Test func youtubeAndVerticalPresetsExist() {
        let all = SequenceFormatPresets.named
        for fps in [24, 25, 30, 50, 60] {
            #expect(all.contains { $0.name == "YouTube 1080p \(fps)" && $0.format.width == 1920 && $0.format.height == 1080
                && $0.format.frameDuration == Time(1, Int64(fps)) })
            #expect(all.contains { $0.name == "YouTube 4K \(fps)" && $0.format.width == 3840 && $0.format.height == 2160 })
        }
        let vertical = all.filter { $0.format.width == 1080 && $0.format.height == 1920 }
        #expect(vertical.count >= 6)
        #expect(vertical.allSatisfy { $0.deliveryTarget != nil })
        #expect(all.allSatisfy { $0.format.isValid && $0.format.audioSampleRate == 48_000 })
        #expect(Set(all.map(\.name)).count == all.count)
    }

    @Test func presetLookupByFormat() {
        let p = SequenceFormatPresets.named.first { $0.name == "YouTube 1080p 30" }!
        #expect(SequenceFormatPresets.preset(matching: p.format)?.name == "YouTube 1080p 30")
        #expect(SequenceFormatPresets.preset(matching: SequenceFormat(width: 1000, height: 500, frameDuration: Time(1, 30))) == nil)
    }
}
