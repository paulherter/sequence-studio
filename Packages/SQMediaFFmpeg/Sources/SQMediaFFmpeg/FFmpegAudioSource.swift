import CSQFFmpeg
import Foundation
import SQMedia

/// `AudioSource` over FFmpeg: the file's best audio stream, decoded once at open and resampled to `sampleRate`
/// (48 kHz, the mixer rate) stereo float. A mono file is delivered as identical left and right (`isMono`).
/// shortcut: the whole stream is decoded into memory at open (about 23 MB per minute); upgrade to a seekable chunk
/// cache like the Mac's AssetAudioSource when long recordings are imported.
public final class FFmpegAudioSource: AudioSource, @unchecked Sendable {
    public let sampleRate: Int
    public let frameCount: Int64
    public let isMono: Bool
    private let left: [Float], right: [Float]

    public init(url: URL, sampleRate: Int = 48_000) throws {
        var a = SQFFAudio()
        var err = [CChar](repeating: 0, count: 256)
        let r = url.withUnsafeFileSystemRepresentation { sq_audio_decode($0, Int32(sampleRate), 2, &a, &err, Int32(err.count)) }
        guard r == 0 else { throw FFmpegError.from("audio \(url.lastPathComponent)", r, err) }
        defer { sq_audio_free(&a) }
        let n = Int(a.frames)
        var l = [Float](repeating: 0, count: n), rr = [Float](repeating: 0, count: n)
        if let s = a.samples {
            for i in 0..<n { l[i] = s[2 * i]; rr[i] = s[2 * i + 1] }
        }
        left = l; right = rr
        frameCount = a.frames
        isMono = a.sourceChannels == 1
        self.sampleRate = sampleRate
    }

    public func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int {
        guard sourceFrame >= 0, sourceFrame < frameCount, count > 0 else { return 0 }
        let n = Int(min(Int64(count), frameCount - sourceFrame))
        let src = channel == 0 ? left : right
        src.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress! + Int(sourceFrame), count: n) }
        return n
    }

    /// The best audio stream of `url` as mono floats at `sampleRate` (speech recognition wants 16 kHz). Empty when the file has none.
    public static func monoSamples(url: URL, sampleRate: Int = 16_000) throws -> [Float] {
        var a = SQFFAudio()
        var err = [CChar](repeating: 0, count: 256)
        let r = url.withUnsafeFileSystemRepresentation { sq_audio_decode($0, Int32(sampleRate), 1, &a, &err, Int32(err.count)) }
        guard r == 0 else { throw FFmpegError.from("audio \(url.lastPathComponent)", r, err) }
        defer { sq_audio_free(&a) }
        guard let s = a.samples, a.frames > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: s, count: Int(a.frames)))
    }
}
