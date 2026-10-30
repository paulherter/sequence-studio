import Foundation
import Testing
@testable import SQCore

@Suite struct LiveDuckingDialogueMediaTests {
    /// Export and bake build the waveforms of exactly these media before mixing.
    @Test func dialogueMediaAreTheHeardDialogueClips() throws {
        var t = LiveDuckingTests.timeline(dialogue: [(10, 5), (30, 5)])
        let heard = Set(t.tracks[0].clips.map(\.media))
        #expect(LiveDucking.dialogueMedia(in: t) == heard)
        var off = t.tracks[0].clips[1]; off.isEnabled = false
        try t.replaceClip(off)
        #expect(LiveDucking.dialogueMedia(in: t) == [t.tracks[0].clips[0].media])
        t.tracks[0].isMuted = true
        #expect(LiveDucking.dialogueMedia(in: t).isEmpty)
    }
}
