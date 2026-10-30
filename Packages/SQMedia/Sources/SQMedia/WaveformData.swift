import Foundation
import SQCore

public struct WaveformPeak: Sendable, Hashable, Codable {
    public var min: Float
    public var max: Float
    public init(min: Float, max: Float) { self.min = min; self.max = max }
}

public enum WaveformError: Error, Sendable, LocalizedError {
    case noAudioTrack, readFailed(String)

    /// English text (the display sink translates it with `SQL10n.localized`).
    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: "The file has no audio track."
        case .readFailed(let why): "The audio could not be read: \(why)"
        }
    }
}

/// Multi-resolution min/max peak summary of an audio file.
/// Level 0 has one bucket per `baseBucketSize` sample frames, level k per `baseBucketSize << k`.
/// Each level stores (min, max) per channel per bucket, interleaved: `[b0c0min, b0c0max, b0c1min, ...]`.
public struct WaveformData: Sendable, Hashable, Codable {
    public static let formatVersion: UInt32 = 1
    public static let defaultBaseBucketSize = 256
    static let magic: [UInt8] = Array("SQWF".utf8)

    public var sampleRate: Int
    public var channelCount: Int
    /// Sample frames per channel in the source.
    public var totalFrames: Int
    public var baseBucketSize: Int
    public var levels: [[Float]]

    public init(sampleRate: Int, channelCount: Int, totalFrames: Int, baseBucketSize: Int, levels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.totalFrames = totalFrames
        self.baseBucketSize = baseBucketSize
        self.levels = levels
    }

    public var levelCount: Int { levels.count }
    public func bucketSize(level: Int) -> Int { baseBucketSize << level }
    public func bucketCount(level: Int) -> Int { levels[level].count / (2 * channelCount) }

    public func bucket(level: Int, index: Int, channel: Int) -> WaveformPeak {
        guard level >= 0, level < levels.count, index >= 0, index < bucketCount(level: level), channel >= 0, channel < channelCount
        else { return WaveformPeak(min: 0, max: 0) }
        let o = (index * channelCount + channel) * 2
        return WaveformPeak(min: levels[level][o], max: levels[level][o + 1])
    }

    /// Peaks for `buckets` equal slices of `range`, per channel (`result[channel][bucket]`).
    /// Picks the coarsest mip level whose buckets are at most a quarter of an output bucket (limits edge bleed). Time outside the audio is silent.
    public func peaks(in range: TimeRange, buckets: Int) -> [[WaveformPeak]] {
        let silent = WaveformPeak(min: 0, max: 0)
        guard buckets > 0, channelCount > 0, sampleRate > 0, !levels.isEmpty else {
            return Array(repeating: [], count: Swift.max(channelCount, 0))
        }
        var out = Array(repeating: Array(repeating: silent, count: buckets), count: channelCount)
        // Frame positions are exact rationals: frame = seconds * sampleRate, floored, scaled to `buckets` slices.
        let rate = Int64(sampleRate)
        func frame(_ t: Time) -> Int64 { Self.floorDiv(t.value * rate, t.timescale) }
        let startFrame = frame(range.start)
        let endFrame = frame(range.end)
        let span = Swift.max(endFrame - startFrame, 1)
        let perBucket = Double(span) / Double(buckets)
        var level = 0
        while level + 1 < levels.count, Double(bucketSize(level: level + 1)) * 4 <= perBucket { level += 1 }
        let size = Int64(bucketSize(level: level))
        let count = bucketCount(level: level)
        for i in 0..<buckets {
            let a = startFrame + span * Int64(i) / Int64(buckets)
            var b = startFrame + span * Int64(i + 1) / Int64(buckets)
            if b <= a { b = a + 1 }
            let first = Swift.max(Self.floorDiv(a, size), 0)
            let last = Swift.min(Self.floorDiv(b - 1, size), Int64(count) - 1)
            guard first <= last else { continue }
            for ch in 0..<channelCount {
                var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                for k in Int(first)...Int(last) {
                    let o = (k * channelCount + ch) * 2
                    lo = Swift.min(lo, levels[level][o]); hi = Swift.max(hi, levels[level][o + 1])
                }
                out[ch][i] = WaveformPeak(min: lo, max: hi)
            }
        }
        return out
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    // MARK: Binary format (little endian)
    // "SQWF" | version u32 | sampleRate u32 | channels u32 | totalFrames u64 | baseBucket u32 | levelCount u32
    // then per level: bucketCount u32, then bucketCount*channels*2 Float32.

    public enum FormatError: Error, Sendable, Equatable { case badMagic, unsupportedVersion(UInt32), truncated, invalid }

    public func serialized() -> Data {
        var d = Data(Self.magic)
        d.reserveCapacity(36 + levels.reduce(0) { $0 + 4 + $1.count * 4 })
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(Self.formatVersion); put(UInt32(sampleRate)); put(UInt32(channelCount))
        put(UInt64(totalFrames)); put(UInt32(baseBucketSize)); put(UInt32(levels.count))
        for (i, l) in levels.enumerated() {
            put(UInt32(bucketCount(level: i)))
            #if _endian(little)
            l.withUnsafeBytes { d.append(contentsOf: $0) }      // Float32 little endian already (bulk, the disk cache reads MBs)
            #else
            for f in l { put(f.bitPattern) }
            #endif
        }
        return d
    }

    public init(serialized data: Data) throws {
        let bytes = [UInt8](data)
        var pos = 0
        func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, pos + n <= bytes.count else { throw FormatError.truncated }
            defer { pos += n }
            return bytes[pos..<pos + n]
        }
        func get<T: FixedWidthInteger>(_: T.Type) throws -> T {
            try take(MemoryLayout<T>.size).enumerated().reduce(T(0)) { $0 | (T($1.element) << (8 * $1.offset)) }
        }
        guard try Array(take(4)) == Self.magic else { throw FormatError.badMagic }
        let version = try get(UInt32.self)
        guard version == Self.formatVersion else { throw FormatError.unsupportedVersion(version) }
        let rate = Int(try get(UInt32.self)), channels = Int(try get(UInt32.self))
        let frames = Int(try get(UInt64.self)), base = Int(try get(UInt32.self)), levelCount = Int(try get(UInt32.self))
        guard channels > 0, channels <= 64, base > 0, levelCount <= 64 else { throw FormatError.invalid }
        var levels: [[Float]] = []
        for _ in 0..<levelCount {
            let n = Int(try get(UInt32.self)) * channels * 2
            guard n * 4 <= bytes.count - pos else { throw FormatError.truncated }
            let start = pos
            let l = [Float](unsafeUninitializedCapacity: n) { buf, count in
                bytes.withUnsafeBytes { src in
                    for i in 0..<n { buf[i] = Float(bitPattern: UInt32(littleEndian: src.loadUnaligned(fromByteOffset: start + 4 * i, as: UInt32.self))) }
                }
                count = n
            }
            pos += n * 4
            levels.append(l)
        }
        self.init(sampleRate: rate, channelCount: channels, totalFrames: frames, baseBucketSize: base, levels: levels)
    }
}
