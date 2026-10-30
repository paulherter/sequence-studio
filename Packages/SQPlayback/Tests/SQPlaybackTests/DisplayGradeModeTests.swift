import Testing
import SQMedia
@testable import SQPlayback

/// Playback perf: the monitor grades pointwise layers at display size only while playing, scrubbing or at a reduced
/// preview quality; a settled full-quality frame is graded like export.
@Test func displaySizeGradeOnlyForPreview() {
    #expect(RenderLoop.gradesAtDisplaySize(playing: true, scrubbing: false, quality: .full, enabled: true))
    #expect(RenderLoop.gradesAtDisplaySize(playing: false, scrubbing: true, quality: .full, enabled: true))
    #expect(RenderLoop.gradesAtDisplaySize(playing: false, scrubbing: false, quality: .half, enabled: true))
    #expect(RenderLoop.gradesAtDisplaySize(playing: false, scrubbing: false, quality: .quarter, enabled: true))
    #expect(!RenderLoop.gradesAtDisplaySize(playing: false, scrubbing: false, quality: .full, enabled: true))
    #expect(!RenderLoop.gradesAtDisplaySize(playing: true, scrubbing: true, quality: .half, enabled: false))
}
