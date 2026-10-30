import SQMediaFFmpegCore
import Testing

/// Which streams go to D3D11VA at open: 4:2:0 only, and H.264 only at 8 bits (no PC decoder takes 4:2:2 or High 10 H.264,
/// e.g. Sony XAVC S 4K 4:2:2 10-bit), so those open the software decoder at once and report it.
@Suite struct FFmpegHardwareDecodeTests {
    @Test func fourTwoZeroStreamsOfHardwareCodecsGoToTheGPU() {
        #expect(FFmpegHardwareDecode.supports(codec: "h264", pixelFormat: "yuv420p"))
        #expect(FFmpegHardwareDecode.supports(codec: "h264", pixelFormat: "yuvj420p"))
        #expect(FFmpegHardwareDecode.supports(codec: "hevc", pixelFormat: "yuv420p10le"))
        #expect(FFmpegHardwareDecode.supports(codec: "av1", pixelFormat: "yuv420p10le"))
        #expect(FFmpegHardwareDecode.supports(codec: "vp9", pixelFormat: "yuv420p"))
        #expect(FFmpegHardwareDecode.supports(codec: "hevc", pixelFormat: "unknown"))   // not probed: let FFmpeg try
    }

    @Test func otherStreamsOpenTheSoftwareDecoder() {
        #expect(!FFmpegHardwareDecode.supports(codec: "h264", pixelFormat: "yuv422p10le"))   // XAVC S 4:2:2 10-bit
        #expect(!FFmpegHardwareDecode.supports(codec: "h264", pixelFormat: "yuv420p10le"))   // High 10
        #expect(!FFmpegHardwareDecode.supports(codec: "hevc", pixelFormat: "yuv422p10le"))
        #expect(!FFmpegHardwareDecode.supports(codec: "hevc", pixelFormat: "yuv444p"))
        #expect(!FFmpegHardwareDecode.supports(codec: "prores", pixelFormat: "yuv422p10le"))
        #expect(!FFmpegHardwareDecode.supports(codec: "qtrle", pixelFormat: "argb"))
        #expect(!FFmpegHardwareDecode.supports(codec: "mjpeg", pixelFormat: "yuvj420p"))
    }
}
