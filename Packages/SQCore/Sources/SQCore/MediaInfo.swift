import Foundation

/// Probed properties of a media file. Stored on `MediaRef.info`; filled by SQMedia (no AVFoundation here).
public struct MediaInfo: Sendable, Hashable, Codable {
    public var duration: Time
    public var video: VideoTrackInfo?
    public var audio: AudioTrackInfo?
    /// Source colour space detected once at import (tags or camera metadata). nil = not detected (treated as Rec.709).
    public var detectedColorSpace: ColorSpaceID?
    /// Name of the camera look LUT embedded in the file, if any.
    public var embeddedLUTName: String?
    /// Still image (png, jpg, heic ...): `video` carries its size, there is no audio, and clips of it may be trimmed
    /// to any length (`duration` is only the default length when placed).
    public var isStill: Bool

    /// Default length of a placed still image (Premiere's still duration; a Settings value later).
    public static let defaultStillDuration = Time(5, 1)

    public init(duration: Time, video: VideoTrackInfo? = nil, audio: AudioTrackInfo? = nil,
                detectedColorSpace: ColorSpaceID? = nil, embeddedLUTName: String? = nil, isStill: Bool = false) {
        self.duration = duration; self.video = video; self.audio = audio
        self.detectedColorSpace = detectedColorSpace; self.embeddedLUTName = embeddedLUTName; self.isStill = isStill
    }

    private enum CodingKeys: String, CodingKey {
        case duration, video, audio, detectedColorSpace, embeddedLUTName, isStill
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(duration: try c.decode(Time.self, forKey: .duration),
                  video: try c.decodeIfPresent(VideoTrackInfo.self, forKey: .video),
                  audio: try c.decodeIfPresent(AudioTrackInfo.self, forKey: .audio),
                  detectedColorSpace: try c.decodeIfPresent(ColorSpaceID.self, forKey: .detectedColorSpace),
                  embeddedLUTName: try c.decodeIfPresent(String.self, forKey: .embeddedLUTName),
                  isStill: try c.decodeIfPresent(Bool.self, forKey: .isStill) ?? false)
    }

    /// True for media imported before colour detection existed (v6 files): the app should run
    /// `ColorDetection.detect(url:)` (SQMedia) on open/relink and store the result.
    public var needsColorDetection: Bool { detectedColorSpace == nil }

    /// Effective colour space of the media when a clip does not override it.
    public var colorSpace: ColorSpaceID { detectedColorSpace ?? .rec709 }
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
    /// Clockwise quarter turns (degrees 0, 90, 180, 270) from the track's preferred transform (phone clips):
    /// the decoded picture is `width` x `height` (native) and must be turned by this much to be shown upright.
    public var rotation: Int

    /// Size as shown (upright): native size, swapped for 90/270.
    public var displayWidth: Int { rotation == 90 || rotation == 270 ? height : width }
    public var displayHeight: Int { rotation == 90 || rotation == 270 ? width : height }

    public init(width: Int, height: Int, codec: String, bitDepth: Int, chroma: String,
                nominalFrameDuration: Time, isVariableFrameRate: Bool,
                colorPrimaries: String? = nil, transfer: String? = nil, matrix: String? = nil, rotation: Int = 0) {
        self.width = width; self.height = height; self.codec = codec; self.bitDepth = bitDepth; self.chroma = chroma
        self.nominalFrameDuration = nominalFrameDuration; self.isVariableFrameRate = isVariableFrameRate
        self.colorPrimaries = colorPrimaries; self.transfer = transfer; self.matrix = matrix
        self.rotation = ((rotation % 360) + 360) % 360
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, codec, bitDepth, chroma, nominalFrameDuration, isVariableFrameRate
        case colorPrimaries, transfer, matrix, rotation
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height),
                  codec: try c.decode(String.self, forKey: .codec), bitDepth: try c.decode(Int.self, forKey: .bitDepth),
                  chroma: try c.decode(String.self, forKey: .chroma),
                  nominalFrameDuration: try c.decode(Time.self, forKey: .nominalFrameDuration),
                  isVariableFrameRate: try c.decode(Bool.self, forKey: .isVariableFrameRate),
                  colorPrimaries: try c.decodeIfPresent(String.self, forKey: .colorPrimaries),
                  transfer: try c.decodeIfPresent(String.self, forKey: .transfer),
                  matrix: try c.decodeIfPresent(String.self, forKey: .matrix),
                  rotation: try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0)
    }
}

public struct AudioTrackInfo: Sendable, Hashable, Codable {
    public var sampleRate: Int, channels: Int, codec: String
    public init(sampleRate: Int, channels: Int, codec: String) {
        self.sampleRate = sampleRate; self.channels = channels; self.codec = codec
    }
}
