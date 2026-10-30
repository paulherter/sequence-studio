import Foundation
import SQCore

/// Decodes a clip's media to one mono Float channel (left and right averaged), for analysis such as the beat tracker.
public enum MonoAudioDecoder {
    /// Analysis rate: beat tracking needs no more, and it keeps a 10 minute song near 50 MB.
    public static let analysisSampleRate = 22_050

    /// Reads `source` from frame 0 to its end (or `maxFrames`) and mixes it down to mono.
    public static func mono(from source: any AudioSource, maxFrames: Int = Int.max, block: Int = 65_536) throws -> [Float] {
        var out: [Float] = []
        var left = [Float](repeating: 0, count: block), right = left
        var at = 0
        while at < maxFrames {
            let n = min(block, maxFrames - at)
            let l = try left.withUnsafeMutableBufferPointer { try source.read(from: Int64(at), count: n, into: $0.baseAddress!, channel: 0) }
            if l <= 0 { break }
            if source.isMono {
                out.append(contentsOf: left[0..<l])
            } else {
                let r = try right.withUnsafeMutableBufferPointer { try source.read(from: Int64(at), count: l, into: $0.baseAddress!, channel: 1) }
                for i in 0..<l { out.append(i < r ? (left[i] + right[i]) * 0.5 : left[i]) }
            }
            at += l
            if l < n { break }
        }
        return out
    }

    /// Decodes the audio track of the file at `url` at `sampleRate`. Throws `MediaError.unreadable` without audio.
    public static func decode(url: URL, sampleRate: Int = analysisSampleRate) async throws -> [Float] {
        let source = try await AssetAudioSource.open(url: url, sampleRate: sampleRate)
        return try await Task.detached(priority: .utility) { try mono(from: source) }.value
    }
}
