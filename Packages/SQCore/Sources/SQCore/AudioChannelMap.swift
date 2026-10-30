import Foundation

/// F7.10: which channels of a media file feed a clip's two sides (source settings > Audio Channels). A setting of the
/// media item: every clip of it, playback, scrubbing, export and the waveform read the file through it. Channels are
/// numbered from 0 in file order (an MXF's mono tracks one after the other).
///
/// Levels: channels that go to both sides alike are summed at -3 dB each (equal power, so two microphones in the
/// center do not come out 6 dB hot); a single channel, and channels routed to one side only, stay at unity.
public struct AudioChannelMap: Sendable, Hashable, Codable {
    /// Source channels heard on the left / right side, in ascending order, no duplicates.
    public private(set) var left: [Int]
    public private(set) var right: [Int]

    /// Most channels one side takes (a 16-track camera file summed to the center).
    public static let maxChannelsPerSide = 16

    /// nil when a channel is negative, both sides are empty or a side lists more than `maxChannelsPerSide` channels.
    public init?(left: [Int], right: [Int]) {
        let l = Array(Set(left)).sorted(), r = Array(Set(right)).sorted()
        guard !(l.isEmpty && r.isEmpty), l.count <= Self.maxChannelsPerSide, r.count <= Self.maxChannelsPerSide,
              (l + r).allSatisfy({ $0 >= 0 }) else { return nil }
        self.left = l; self.right = r
    }

    /// One channel on both sides.
    public static func mono(_ channel: Int) -> AudioChannelMap? { AudioChannelMap(left: [channel], right: [channel]) }
    /// One channel per side.
    public static func stereo(_ l: Int, _ r: Int) -> AudioChannelMap? { l == r ? nil : AudioChannelMap(left: [l], right: [r]) }
    /// Two channels, both in the center (two microphones on one clip).
    public static func dualMono(_ a: Int, _ b: Int) -> AudioChannelMap? { a == b ? nil : AudioChannelMap(left: [a, b], right: [a, b]) }

    public enum Layout: Sendable, Hashable { case mono, stereo, dualMono, custom }

    public var layout: Layout {
        if left == right { return left.count == 1 ? .mono : (left.count == 2 ? .dualMono : .custom) }
        return left.count == 1 && right.count == 1 ? .stereo : .custom
    }

    /// Both sides get the same signal: the clip is a mono source (pan law, one waveform lane).
    public var isCentered: Bool { left == right }

    /// Gain of each summed channel (see the type's note on levels).
    public var gain: Float { isCentered && left.count > 1 ? Float(0.5).squareRoot() : 1 }

    /// Highest channel the map reads.
    public var highestChannel: Int { max(left.last ?? 0, right.last ?? 0) }

    /// The map for a file with `channels` channels: channels the file lacks are dropped. nil when a side that was in
    /// use loses all its channels (the map no longer says what was chosen: the file's layout applies instead of a
    /// dead side).
    public func fitting(channels: Int) -> AudioChannelMap? {
        let l = left.filter { $0 < channels }, r = right.filter { $0 < channels }
        guard l.isEmpty == left.isEmpty, r.isEmpty == right.isEmpty else { return nil }
        return AudioChannelMap(left: l, right: r)
    }

    /// What the file's own layout plays, as a map; nil when that is not known from the probe info. An MXF's channels
    /// 1 + 2 sit in the center (its mono tracks are microphones); any other file with one or two channels plays them
    /// as they are. More channels are the reader's own mix, which no map names.
    public static func fileLayout(audio: AudioTrackInfo, path: String) -> AudioChannelMap? {
        let ext = (path as NSString).pathExtension.lowercased()
        var audio = audio
        audio.channels = audio.firstTrackChannels ?? audio.channels     // the file's own layout is its first track
        audio.channels = audio.mappableChannels(path: path)
        if ext == "mxf" {
            guard audio.codec == "PCM" else { return nil }        // probed by another reader: layout unknown
            return audio.channels > 1 ? .dualMono(0, 1) : (audio.channels == 1 ? .mono(0) : nil)
        }
        // "PCM" is how the MXF and the WebM reader name their sound: outside a WebM it may be an MXF under another name.
        guard audio.codec != "PCM" || ["webm", "mkv", "mka"].contains(ext) else { return nil }
        return audio.channels == 2 ? .stereo(0, 1) : (audio.channels == 1 ? .mono(0) : nil)
    }

    /// What is stored when `self` is chosen for a file: the fitted map, or nil when it does not fit (see `fitting`) or
    /// names exactly what the file's layout plays anyway (a choice that changes nothing is no choice: the label says
    /// File Layout and the project needs no newer file version).
    public func stored(audio: AudioTrackInfo, path: String) -> AudioChannelMap? {
        guard let fitted = fitting(channels: audio.mappableChannels(path: path)) else { return nil }
        return fitted == Self.fileLayout(audio: audio, path: path) ? nil : fitted
    }

    /// "Mono: 3", "Stereo: 1 + 2", "Dual Mono: 1 + 2" (channels counted from 1, as cameras label them).
    public var label: String {
        func list(_ c: [Int]) -> String { c.isEmpty ? "none" : c.map { String($0 + 1) }.joined(separator: " + ") }
        switch layout {
        case .mono: return "Mono: \(list(left))"
        case .stereo: return "Stereo: \(list(left + right))"
        case .dualMono: return "Dual Mono: \(list(left))"
        case .custom: return isCentered ? "Center: \(list(left))" : "Left: \(list(left)), Right: \(list(right))"
        }
    }

    private enum CodingKeys: String, CodingKey { case left, right }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        guard let m = AudioChannelMap(left: try c.decode([Int].self, forKey: .left), right: try c.decode([Int].self, forKey: .right)) else {
            throw DecodingError.dataCorruptedError(forKey: .left, in: c, debugDescription: "invalid audio channel map")
        }
        self = m
    }
}

extension AudioTrackInfo {
    /// Channels a map may address: the file's, but a WebM / Matroska file is read by our own decoder that delivers two
    /// (a 5.1 mix is not offered, so no map names a channel the reader cannot deliver).
    public func mappableChannels(path: String) -> Int {
        ["webm", "mkv", "mka"].contains((path as NSString).pathExtension.lowercased()) ? min(channels, 2) : channels
    }
}

extension Project {
    /// The channel map chosen for `id`; nil = the file's own layout (also for unknown media).
    public func audioChannelMap(of id: MediaRef.ID) -> AudioChannelMap? { media(id)?.info?.audio?.channelMap }

    /// Source settings > Audio Channels: which file channels `id` plays from now on, for every clip of it (a setting of
    /// the media item; subclips share their file's setting). nil = the file's layout, which is also what a map that
    /// names that layout is stored as. Channels the file lacks are dropped. Returns whether anything changed; false
    /// for unknown media, media without (probed) audio and a map that does not fit the file (`fitting`).
    @discardableResult
    public mutating func setAudioChannelMap(_ map: AudioChannelMap?, for id: MediaRef.ID) -> Bool {
        guard let item = media(id) else { return false }
        let file = item.subclip?.parent ?? id
        var changed = false
        for i in media.indices where media[i].id == file || media[i].subclip?.parent == file {
            guard let a = media[i].info?.audio else { continue }
            var value: AudioChannelMap?
            if let map {
                guard map.fitting(channels: a.mappableChannels(path: media[i].path)) != nil else { continue }
                value = map.stored(audio: a, path: media[i].path)
            }
            guard value != a.channelMap else { continue }
            media[i].info?.audio?.channelMap = value
            changed = true
        }
        return changed
    }

    /// After media was pointed at other files (relink): a chosen map is fitted to the probed sound of the new file,
    /// and cleared when it does not fit, so the label and the file version say what is heard. The item's sound info
    /// becomes the new file's. Media without a chosen map takes the new file's sound info too (channel counts and the
    /// first track's count follow the file); the rest of its info is left alone. Returns whether anything changed.
    @discardableResult
    public mutating func fitAudioChannelMaps(to probed: [MediaRef.ID: MediaInfo]) -> Bool {
        var changed = false
        for i in media.indices {
            guard media[i].info != nil, let info = probed[media[i].id] else { continue }
            let before = media[i].info?.audio
            guard let map = before?.channelMap else {
                if before != info.audio { media[i].info?.audio = info.audio; changed = true }
                continue
            }
            if var a = info.audio {
                a.channelMap = map.stored(audio: a, path: media[i].path)
                media[i].info?.audio = a
            } else {
                media[i].info?.audio?.channelMap = nil
            }
            if media[i].info?.audio != before { changed = true }
        }
        return changed
    }
}
