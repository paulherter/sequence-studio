import Foundation
import SQMediaFFmpeg
import Testing

@Suite struct FFmpegErrorTextTests {
    /// The status line shows `localizedDescription`; an Error enum without LocalizedError printed
    /// "The operation could not be completed. (SQMediaFFmpeg.FFmpegError error 1.)" on Windows.
    @Test func theLocalizedTextIsTheMessage() {
        #expect(FFmpegError.message("no video stream").localizedDescription == "no video stream")
        #expect(FFmpegError.failed("open", -2).localizedDescription == "open failed (-2)")
    }
}
