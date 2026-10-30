/// Which video streams the D3D11VA path opens. Hardware video decoders on PCs take 4:2:0 only, and H.264 only at 8 bits:
/// a Sony XAVC S 4K 4:2:2 10-bit H.264 clip opened the D3D11VA decoder, failed on its first packet and fell back to
/// software, while `isHardware` (the proxy Auto rule's input) said hardware until then. Those streams now open the
/// software decoder at once.
public enum FFmpegHardwareDecode {
    /// `codec`: FFmpeg codec name; `pixelFormat`: the stream's AVPixelFormat name ("unknown" when not probed).
    public static func supports(codec: String, pixelFormat: String) -> Bool {
        let codecs: Set<String> = ["h264", "hevc", "av1", "vp9", "vp8", "mpeg2video", "vc1", "wmv3"]
        guard codecs.contains(codec) else { return false }
        if pixelFormat == "unknown" || pixelFormat.isEmpty { return true }
        let eightBit: Set<String> = ["yuv420p", "yuvj420p", "nv12"]
        let tenBit: Set<String> = ["yuv420p10le", "yuv420p10be", "p010le"]
        if codec == "h264" { return eightBit.contains(pixelFormat) }
        return eightBit.contains(pixelFormat) || tenBit.contains(pixelFormat)
    }
}
