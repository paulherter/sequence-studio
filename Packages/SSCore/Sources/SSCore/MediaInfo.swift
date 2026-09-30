import Foundation

/// Probed properties of a media file. Stored on `MediaRef.info`; filled by SSMedia (no AVFoundation here).
public struct MediaInfo: Sendable, Hashable, Codable {
    public var duration: Time
    public var video: VideoTrackInfo?
    public var audio: AudioTrackInfo?

    public init(duration: Time, video: VideoTrackInfo? = nil, audio: AudioTrackInfo? = nil) {
        self.duration = duration; self.video = video; self.audio = audio
    }
}

public struct VideoTrackInfo: Sendable, Hashable, Codable {
    public var width: Int, height: Int
    public var codec: String            // FourCC, e.g. "avc1", "hvc1", "apch"
    public var bitDepth: Int
    public var chroma: String           // "4:2:0", "4:2:2", "4:4:4"
    public var nominalFrameDuration: Time
    public var isVariableFrameRate: Bool
    /// nil = untagged in the file (Sony).
    public var colorPrimaries: String?, transfer: String?, matrix: String?

    public init(width: Int, height: Int, codec: String, bitDepth: Int, chroma: String,
                nominalFrameDuration: Time, isVariableFrameRate: Bool,
                colorPrimaries: String? = nil, transfer: String? = nil, matrix: String? = nil) {
        self.width = width; self.height = height; self.codec = codec; self.bitDepth = bitDepth; self.chroma = chroma
        self.nominalFrameDuration = nominalFrameDuration; self.isVariableFrameRate = isVariableFrameRate
        self.colorPrimaries = colorPrimaries; self.transfer = transfer; self.matrix = matrix
    }
}

public struct AudioTrackInfo: Sendable, Hashable, Codable {
    public var sampleRate: Int, channels: Int, codec: String
    public init(sampleRate: Int, channels: Int, codec: String) {
        self.sampleRate = sampleRate; self.channels = channels; self.codec = codec
    }
}
