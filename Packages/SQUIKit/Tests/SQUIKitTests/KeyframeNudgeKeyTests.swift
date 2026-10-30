import Testing
@testable import SQUIKit

@Suite struct KeyframeNudgeKeyTests {
    @Test func nudgeKeysMapToFrameCounts() {
        #expect(EditorCommand.insert.keyframeNudgeFrames == -1)
        #expect(EditorCommand.overwrite.keyframeNudgeFrames == 1)
        #expect(EditorCommand.focusPanel(.keystones).keyframeNudgeFrames == -10)
        #expect(EditorCommand.placeOnTop.keyframeNudgeFrames == 10)
        #expect(EditorCommand.nudgeLeft.keyframeNudgeFrames == -1)
        #expect(EditorCommand.nudgeRight10.keyframeNudgeFrames == 10)
        #expect(EditorCommand.nudgeLeft10.keyframeNudgeFrames == -10)
        #expect(EditorCommand.nudgeLeft5.keyframeNudgeFrames == -10)
        #expect(EditorCommand.playPause.keyframeNudgeFrames == nil)
    }
}
