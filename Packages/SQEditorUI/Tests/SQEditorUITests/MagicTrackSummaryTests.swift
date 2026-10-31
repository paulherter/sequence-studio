import Testing
import SQCore
@testable import SQEditorUI

/// The line a finished Magic track leaves (the end of `MacMagicMasks.runMagicTrack` in the shared UI).
@Suite struct MagicTrackSummaryTests {
    @Test func noFrameSaysWhyAndLostFramesPointToThePick() {
        #expect(MagicTrackSummary.message(frames: 0, lost: 0, unsure: 0, covers: false, part: nil).hasPrefix("Nothing to follow"))
        #expect(MagicTrackSummary.message(frames: 0, lost: 4, unsure: 0, covers: false, part: nil).hasPrefix("The object was not found"))
    }

    @Test func aCleanRunCountsTheFrames() {
        let m = MagicTrackSummary.message(frames: 120, lost: 0, unsure: 0, covers: false, part: nil)
        #expect(m.contains("120") && !m.contains("check"))
    }

    @Test func lostFramesDifferForCoverMasksAndNameTheStrip() {
        let plain = MagicTrackSummary.message(frames: 50, lost: 3, unsure: 0, covers: false, part: nil)
        #expect(plain.contains("marked on the strip") && plain.contains("50") && plain.contains("3"))
        let cover = MagicTrackSummary.message(frames: 50, lost: 3, unsure: 0, covers: true, part: nil)
        #expect(cover.contains("enlarged estimate") && !cover.contains("strip"))
    }

    @Test func unsureFramesAreCheckedAndSkinIsNamed() {
        #expect(MagicTrackSummary.message(frames: 10, lost: 0, unsure: 2, covers: true, part: .skin).contains("the skin was not found"))
        #expect(MagicTrackSummary.message(frames: 10, lost: 0, unsure: 2, covers: true, part: .face).contains("the face was not found"))
    }
}
