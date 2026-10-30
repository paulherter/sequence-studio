import AVFoundation
import Foundation
import Synchronization
import SQCore

/// F7.10: opens the audio of a media file with the channels chosen for the media item (`AudioChannelMap`). One entry
/// for playback, scrubbing, export and waveforms, so all of them hear the same channels.
public enum AudioSources {
    /// Writes what a clip of `url` plays through `channelMap` as a float CAF (one channel when the map is centered,
    /// else two), for readers that open `AVAudioFile`s only (speech transcription hears the mapped channels).
    public static func writeFile(from url: URL, channelMap: AudioChannelMap?, to dest: URL, sampleRate: Int = 48_000,
                                 expectedChannels: Int? = nil) async throws {
        let src = try await open(url: url, sampleRate: sampleRate, channelMap: channelMap, expectedChannels: expectedChannels)
        let channels: AVAudioChannelCount = src.isMono ? 1 : 2
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: channels, interleaved: false)
        else { throw MediaError.unreadable }
        try? FileManager.default.removeItem(at: dest)
        let file = try AVAudioFile(forWriting: dest, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16_384
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { throw MediaError.unreadable }
        var pos: Int64 = 0
        while true {
            try Task.checkCancellation()
            var n = 0
            for c in 0..<Int(channels) { n = try src.read(from: pos, count: chunk, into: buf.floatChannelData![c], channel: c) }
            if n <= 0 { break }
            buf.frameLength = AVAudioFrameCount(n)
            try file.write(from: buf)
            pos += Int64(n)
        }
        guard pos > 0 else { throw MediaError.unreadable }
    }

    /// nil map = the file's own layout: the same source, sample for sample, as before channel routing existed.
    /// `expectedChannels` is the channel count the map was chosen against (the item's stored count). When the file now
    /// counts another number (another track layout since the probe), the map is stale and the file layout plays instead.
    public static func open(url: URL, sampleRate: Int, channelMap: AudioChannelMap? = nil,
                            expectedChannels: Int? = nil) async throws -> any AudioSource {
        if WebMFile.isWebM(url) {
            return ChannelMappedSource.wrap(try await WebMAudioSource.open(url: url, sampleRate: sampleRate), map: channelMap)
        }
        if MXFFile.isMXF(url) {
            return try await MXFAudioSource.open(url: url, sampleRate: sampleRate, left: channelMap?.left, right: channelMap?.right)
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let first = tracks.first else { throw MediaError.unreadable }
        let usable = await MultiTrackAudio.usableTracks(tracks)
        var channelMap = channelMap
        if let expectedChannels {
            let now = await MultiTrackAudio.totalChannels(tracks)
            if now != expectedChannels { channelMap = nil }
        }
        if usable.count > 1 {           // channels count across all usable audio tracks; only the tracks the map uses are decoded
            return await MultiTrackAudio.open(asset: asset, tracks: usable.map(\.track), counts: usable.map(\.channels),
                                              sampleRate: sampleRate, channelMap: channelMap)
        }
        // One track (none usable: the first, with its own channel count): reuse the track already loaded.
        let singleChannels: Int
        if let c = usable.first?.channels { singleChannels = c } else { singleChannels = await MultiTrackAudio.channels(of: first) }
        let track = usable.first?.track ?? first
        let end = await AssetAudioSource.endFrame(of: track, sampleRate: sampleRate)
        return AssetAudioSource.make(asset: asset, track: track, channels: singleChannels,
                                     sampleRate: sampleRate, channelMap: channelMap, end: end)
    }
}

/// A channel map over a source that already delivers two sides (WebM's stereo decode, a test source): the map picks from
/// those two. A side that takes one channel reads it straight from the base (no copy, no extra work); a sum uses one
/// scratch buffer that is kept between reads.
public final class ChannelMappedSource: AudioSource {
    private let base: any AudioSource
    private let left: [Int], right: [Int]
    private let gain: Float
    public let isMono: Bool
    private let scratch = Mutex([Float]())

    /// `base` itself when there is nothing to map (no map, no channel of it among the two, or the plain stereo order).
    public static func wrap(_ base: any AudioSource, map: AudioChannelMap?) -> any AudioSource {
        // The reader delivers two sides: a map naming a channel beyond them is not a map for this file (it plays the
        // file layout, not a partial sum that silently drops the other channels).
        guard let m = map?.fitting(channels: 2), m == map else { return base }
        if m == .stereo(0, 1), !base.isMono { return base }
        return ChannelMappedSource(base: base, map: m)
    }

    private init(base: any AudioSource, map: AudioChannelMap) {
        self.base = base; left = map.left; right = map.right; gain = map.gain; isMono = map.isCentered
    }

    public func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int {
        guard channel == 0 || channel == 1 else { return 0 }
        let list = channel == 0 ? left : right
        if list.count == 1 { return try base.read(from: sourceFrame, count: count, into: buffer, channel: list[0]) }
        let n = try base.read(from: sourceFrame, count: count, into: buffer, channel: 0)
        guard n > 0 else { return n }
        if list.isEmpty { buffer.update(repeating: 0, count: n); return n }
        return try scratch.withLock { s in
            if s.count < n { s = [Float](repeating: 0, count: n) }
            let m = try s.withUnsafeMutableBufferPointer { try base.read(from: sourceFrame, count: n, into: $0.baseAddress!, channel: 1) }
            for i in 0..<n { buffer[i] = (buffer[i] + (i < m ? s[i] : 0)) * gain }
            return n
        }
    }
}
