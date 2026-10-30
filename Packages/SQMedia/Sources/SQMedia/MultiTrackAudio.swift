import AVFoundation
import CoreMedia
import Foundation
import SQCore
import Synchronization

/// Files from cameras and recorders often carry several audio tracks (a mono lavalier next to the stereo mix). The
/// channels of a file are counted across all its audio tracks, in track order and then channel order, so "Audio
/// Channels" can name any of them. Tracks no map channel falls in are never opened, so they cost no decoding.
enum MultiTrackAudio {
    /// The audio tracks whose channels count: enabled (a disabled track is an alternate the player skips) and with a
    /// format that decodes to PCM channels. The probe, playback and the proxy path all use this one list, so a channel
    /// index means the same track everywhere.
    static func usableTracks(_ tracks: [AVAssetTrack]) async -> [(track: AVAssetTrack, channels: Int)] {
        var out: [(track: AVAssetTrack, channels: Int)] = []
        for t in tracks {
            // One await per statement: two `try? await` inside one guard condition miscompile in a loop and abort the
            // process ("freed pointer was not the last allocation", see ProjectMediaResolver.init).
            let enabled = (try? await t.load(.isEnabled)) ?? true
            guard enabled else { continue }
            let formats = (try? await t.load(.formatDescriptions)) ?? []
            guard let d = formats.first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee,
                  asbd.mChannelsPerFrame > 0 else { continue }
            out.append((t, Int(asbd.mChannelsPerFrame)))
        }
        return out
    }

    /// Channels of a track's own format (2 when it has none, as the plain reader assumes).
    static func channels(of track: AVAssetTrack) async -> Int {
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        if let d = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee, asbd.mChannelsPerFrame > 0 {
            return Int(asbd.mChannelsPerFrame)
        }
        return 2
    }

    /// Channels a file counts now: all usable tracks together, or the first track's own count when none is usable.
    static func totalChannels(_ tracks: [AVAssetTrack]) async -> Int? {
        let usable = await usableTracks(tracks)
        if !usable.isEmpty { return usable.map(\.channels).reduce(0, +) }
        guard let first = tracks.first else { return nil }
        return await channels(of: first)
    }

    /// Channels of each usable track.
    static func channelCounts(_ tracks: [AVAssetTrack]) async -> [Int] { await usableTracks(tracks).map(\.channels) }

    /// The part of `map` that falls on the track holding file channels `offset..<offset + count`, numbered from the
    /// track's first channel; nil when the map uses none of them.
    static func part(of map: AudioChannelMap, offset: Int, count: Int) -> AudioChannelMap? {
        func local(_ side: [Int]) -> [Int] { side.filter { $0 >= offset && $0 < offset + count }.map { $0 - offset } }
        return AudioChannelMap(left: local(map.left), right: local(map.right))
    }

    /// The tracks `map` uses with the part of the map each one plays (counts in track order).
    static func plan(map: AudioChannelMap, counts: [Int]) -> [(track: Int, part: AudioChannelMap)] {
        var offset = 0
        var out: [(track: Int, part: AudioChannelMap)] = []
        for (i, c) in counts.enumerated() {
            if let p = part(of: map, offset: offset, count: c) { out.append((i, p)) }
            offset += c
        }
        return out
    }

    /// The source for `map` over a file with the given audio tracks (two or more). nil map, or one the file's channels
    /// cannot satisfy, plays the first track as the file layout.
    static func open(asset: AVURLAsset, tracks: [AVAssetTrack], counts: [Int], sampleRate: Int,
                     channelMap: AudioChannelMap?) async -> any AudioSource {
        let total = counts.reduce(0, +)
        guard let map = channelMap?.fitting(channels: total) else {
            let end = await AssetAudioSource.endFrame(of: tracks[0], sampleRate: sampleRate)
            return AssetAudioSource.make(asset: asset, track: tracks[0], channels: counts[0], sampleRate: sampleRate,
                                         channelMap: nil, end: end)
        }
        let used = plan(map: map, counts: counts)
        var parts: [AssetAudioSource] = []
        for u in used {
            let end = await AssetAudioSource.endFrame(of: tracks[u.track], sampleRate: sampleRate)
            parts.append(AssetAudioSource.make(asset: asset, track: tracks[u.track], channels: counts[u.track],
                                               sampleRate: sampleRate, channelMap: u.part, gain: map.gain,
                                               keepRoute: used.count > 1, end: end))
        }
        if parts.count == 1 { return parts[0] }
        return SummedTracksSource(parts: parts, isMono: map.isCentered)
    }
}

/// The sides of several track sources added up (each already carries the map's level).
final class SummedTracksSource: AudioSource {
    private let parts: [any AudioSource]
    let isMono: Bool
    private let scratch = Mutex([Float]())

    init(parts: [any AudioSource], isMono: Bool) { self.parts = parts; self.isMono = isMono }

    func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int {
        var total = try parts[0].read(from: sourceFrame, count: count, into: buffer, channel: channel)
        return try scratch.withLock { s in
            if s.count < count { s = [Float](repeating: 0, count: count) }
            for p in parts.dropFirst() {
                let m = try s.withUnsafeMutableBufferPointer { try p.read(from: sourceFrame, count: count, into: $0.baseAddress!, channel: channel) }
                if m > total { (buffer + total).update(repeating: 0, count: m - total); total = m }
                for i in 0..<m { buffer[i] += s[i] }
            }
            return total
        }
    }
}

/// The one list of audio tracks that carry channels (see `MultiTrackAudio.usableTracks`), for callers outside SQMedia.
public enum UsableAudioTracks {
    public static func tracks(_ all: [AVAssetTrack]) async -> [AVAssetTrack] { await MultiTrackAudio.usableTracks(all).map(\.track) }
}
