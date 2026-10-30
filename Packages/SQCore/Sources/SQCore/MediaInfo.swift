import Foundation

/// Probed properties of a media file. Stored on `MediaRef.info`; filled by SQMedia (no AVFoundation here).
public struct MediaInfo: Sendable, Hashable, Codable {
    public var duration: Time
    public var video: VideoTrackInfo?
    public var audio: AudioTrackInfo?
    /// Source color space detected once at import (tags or camera metadata). nil = not detected (treated as Rec.709).
    public var detectedColorSpace: ColorSpaceID?
    /// Name of the camera look LUT embedded in the file, if any.
    public var embeddedLUTName: String?
    /// Still image (png, jpg, heic ...): `video` carries its size, there is no audio, and clips of it may be trimmed
    /// to any length (`duration` is only the default length when placed).
    public var isStill: Bool
    /// True once the file's sound was probed with the multi-track channel count (or probed and found silent), so the
    /// open-time re-probe skips it. nil = not yet (media from before). Written only when set; no file version change.
    public var soundProbed: Bool?
    /// When the file was shot (container creation date), read at import. nil = the file has none or it was not read yet.
    /// Optional additive key: older readers ignore it, older files lack it (filled in lazily on open, `shootProbed`).
    public var created: Date?
    /// Camera model from the file's metadata (e.g. "ILME-FX3", "iPhone 15 Pro"); nil = none found.
    public var cameraModel: String?
    /// True once date and camera were looked up (found or not), so the open-time backfill skips the file.
    public var shootProbed: Bool?

    /// Default length of a placed still image (Premiere's still duration; a Settings value later).
    public static let defaultStillDuration = Time(5, 1)

    public init(duration: Time, video: VideoTrackInfo? = nil, audio: AudioTrackInfo? = nil,
                detectedColorSpace: ColorSpaceID? = nil, embeddedLUTName: String? = nil, isStill: Bool = false) {
        self.duration = duration; self.video = video; self.audio = audio
        self.detectedColorSpace = detectedColorSpace; self.embeddedLUTName = embeddedLUTName; self.isStill = isStill
    }

    private enum CodingKeys: String, CodingKey {
        case duration, video, audio, detectedColorSpace, embeddedLUTName, isStill, soundProbed, created, cameraModel, shootProbed
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(duration: try c.decode(Time.self, forKey: .duration),
                  video: try c.decodeIfPresent(VideoTrackInfo.self, forKey: .video),
                  audio: try c.decodeIfPresent(AudioTrackInfo.self, forKey: .audio),
                  detectedColorSpace: try c.decodeIfPresent(ColorSpaceID.self, forKey: .detectedColorSpace),
                  embeddedLUTName: try c.decodeIfPresent(String.self, forKey: .embeddedLUTName),
                  isStill: try c.decodeIfPresent(Bool.self, forKey: .isStill) ?? false)
        soundProbed = (try? c.decodeIfPresent(Bool.self, forKey: .soundProbed)) ?? nil
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? nil
        cameraModel = (try? c.decodeIfPresent(String.self, forKey: .cameraModel)) ?? nil
        shootProbed = (try? c.decodeIfPresent(Bool.self, forKey: .shootProbed)) ?? nil
    }

    /// True for media imported before color detection existed (v6 files): the app should run
    /// `ColorDetection.detect(url:)` (SQMedia) on open/relink and store the result.
    public var needsColorDetection: Bool { detectedColorSpace == nil }

    /// Effective color space of the media when a clip does not override it.
    public var colorSpace: ColorSpaceID { detectedColorSpace ?? .rec709 }
}

/// Which field of an interlaced picture comes first in time. Progressive video has no field order (`nil` on
/// `VideoTrackInfo.fieldOrder`); a segmented frame (PsF) is progressive content and has none either.
public enum FieldOrder: String, Sendable, Hashable, Codable, CaseIterable {
    case topFirst, bottomFirst
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
    /// F7.3: shape of a stored pixel as the file tags it (square when untagged); see PixelAspect.swift.
    public var pixelAspect: PixelAspect
    /// F7.3: the pixel aspect chosen for the media item (`Project.setPixelAspect`); nil = the file's.
    public var pixelAspectOverride: PixelAspect?
    /// Interlaced material: both fields are woven into each decoded picture, this one is the earlier in time.
    /// nil = progressive (also every file stored before the field existed). Written only when set.
    public var fieldOrder: FieldOrder?
    public var isInterlaced: Bool { fieldOrder != nil }
    /// Deinterlace switched off for the media item (`Project.setDeinterlace`): the woven fields are shown as stored.
    /// Written only when true; means nothing for progressive media.
    public var deinterlaceOff = false
    /// The field order the decoder deinterlaces with: nil for progressive media and when the item's switch is off.
    public var deinterlaceFieldOrder: FieldOrder? { deinterlaceOff ? nil : fieldOrder }

    /// Size as shown (upright): stored size with the width desqueezed by the pixel aspect, swapped for 90/270.
    public var displayWidth: Int { rotation == 90 || rotation == 270 ? height : desqueezedWidth }
    public var displayHeight: Int { rotation == 90 || rotation == 270 ? desqueezedWidth : height }

    public init(width: Int, height: Int, codec: String, bitDepth: Int, chroma: String,
                nominalFrameDuration: Time, isVariableFrameRate: Bool,
                colorPrimaries: String? = nil, transfer: String? = nil, matrix: String? = nil, rotation: Int = 0,
                pixelAspect: PixelAspect = .square, pixelAspectOverride: PixelAspect? = nil, fieldOrder: FieldOrder? = nil,
                deinterlaceOff: Bool = false) {
        self.pixelAspect = pixelAspect; self.pixelAspectOverride = pixelAspectOverride; self.fieldOrder = fieldOrder
        self.deinterlaceOff = deinterlaceOff
        self.width = width; self.height = height; self.codec = codec; self.bitDepth = bitDepth; self.chroma = chroma
        self.nominalFrameDuration = nominalFrameDuration; self.isVariableFrameRate = isVariableFrameRate
        self.colorPrimaries = colorPrimaries; self.transfer = transfer; self.matrix = matrix
        self.rotation = ((rotation % 360) + 360) % 360
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, codec, bitDepth, chroma, nominalFrameDuration, isVariableFrameRate
        case colorPrimaries, transfer, matrix, rotation, pixelAspect, pixelAspectOverride, fieldOrder, deinterlaceOff
    }

    /// The pixel aspect keys are written only when they say something (square and no override: the bytes of every file
    /// before v69).
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
        try c.encode(codec, forKey: .codec); try c.encode(bitDepth, forKey: .bitDepth); try c.encode(chroma, forKey: .chroma)
        try c.encode(nominalFrameDuration, forKey: .nominalFrameDuration)
        try c.encode(isVariableFrameRate, forKey: .isVariableFrameRate)
        try c.encodeIfPresent(colorPrimaries, forKey: .colorPrimaries)
        try c.encodeIfPresent(transfer, forKey: .transfer)
        try c.encodeIfPresent(matrix, forKey: .matrix)
        try c.encode(rotation, forKey: .rotation)
        if !pixelAspect.isSquare { try c.encode(pixelAspect, forKey: .pixelAspect) }
        try c.encodeIfPresent(pixelAspectOverride, forKey: .pixelAspectOverride)
        try c.encodeIfPresent(fieldOrder, forKey: .fieldOrder)
        if deinterlaceOff { try c.encode(true, forKey: .deinterlaceOff) }
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let fd = try c.decode(Time.self, forKey: .nominalFrameDuration)
        guard fd > .zero else {
            throw DecodingError.dataCorruptedError(forKey: .nominalFrameDuration, in: c,
                debugDescription: "frame duration must be positive, got \(fd.value)/\(fd.timescale)")
        }
        self.init(width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height),
                  codec: try c.decode(String.self, forKey: .codec), bitDepth: try c.decode(Int.self, forKey: .bitDepth),
                  chroma: try c.decode(String.self, forKey: .chroma),
                  nominalFrameDuration: fd,
                  isVariableFrameRate: try c.decode(Bool.self, forKey: .isVariableFrameRate),
                  colorPrimaries: try c.decodeIfPresent(String.self, forKey: .colorPrimaries),
                  transfer: try c.decodeIfPresent(String.self, forKey: .transfer),
                  matrix: try c.decodeIfPresent(String.self, forKey: .matrix),
                  rotation: try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0,
                  // A malformed ratio is dropped (square), the project opens.
                  pixelAspect: (try? c.decodeIfPresent(PixelAspect.self, forKey: .pixelAspect)) ?? .square,
                  pixelAspectOverride: (try? c.decodeIfPresent(PixelAspect.self, forKey: .pixelAspectOverride)) ?? nil,
                  // An unknown value (a later version's) reads as progressive, the project opens.
                  fieldOrder: (try? c.decodeIfPresent(FieldOrder.self, forKey: .fieldOrder)) ?? nil,
                  deinterlaceOff: (try? c.decodeIfPresent(Bool.self, forKey: .deinterlaceOff)) ?? false)
    }
}

public struct AudioTrackInfo: Sendable, Hashable, Codable {
    public var sampleRate: Int, channels: Int, codec: String
    /// F7.10: the channels chosen for the media item (`Project.setAudioChannelMap`); nil = the file's own layout.
    public var channelMap: AudioChannelMap?
    /// Channels of the first audio track when the file has several (`channels` then counts all of them); nil = one
    /// track, or a file probed before channels were counted across tracks. Decides the file's own layout, which is
    /// the first track.
    public var firstTrackChannels: Int?
    public init(sampleRate: Int, channels: Int, codec: String, channelMap: AudioChannelMap? = nil, firstTrackChannels: Int? = nil) {
        self.sampleRate = sampleRate; self.channels = channels; self.codec = codec; self.channelMap = channelMap
        self.firstTrackChannels = firstTrackChannels
    }

    private enum CodingKeys: String, CodingKey { case sampleRate, channels, codec, channelMap, firstTrackChannels }

    /// `channelMap` is written only when set (nil: the bytes of every file before v70).
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(sampleRate, forKey: .sampleRate); try c.encode(channels, forKey: .channels)
        try c.encode(codec, forKey: .codec)
        try c.encodeIfPresent(channelMap, forKey: .channelMap)
        try c.encodeIfPresent(firstTrackChannels, forKey: .firstTrackChannels)
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let channels = try c.decode(Int.self, forKey: .channels)
        // A malformed map, or one for channels the file does not have, is dropped (file layout); the project opens.
        let map = ((try? c.decodeIfPresent(AudioChannelMap.self, forKey: .channelMap)) ?? nil)?.fitting(channels: channels)
        self.init(sampleRate: try c.decode(Int.self, forKey: .sampleRate), channels: channels,
                  codec: try c.decode(String.self, forKey: .codec), channelMap: map,
                  firstTrackChannels: (try? c.decodeIfPresent(Int.self, forKey: .firstTrackChannels)) ?? nil)
    }
}
