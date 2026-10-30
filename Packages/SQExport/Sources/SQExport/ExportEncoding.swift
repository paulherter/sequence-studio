import Foundation
import SQCore

public enum ExportError: Error, Sendable, Equatable, LocalizedError {
    case invalidSettings(Set<ExportSettingsIssue>)
    case cannotAddVideoInput
    case cannotAddAudioInput
    case writerFailed(String)
    case emptySource
    /// Loudness normalization is on but the audio source cannot be read twice.
    case loudnessNeedsRewindableSource
    /// An audio-only export of a sequence without audio.
    case noAudio
    /// Hardware encoding was asked for, this Mac has a hardware encoder for the codec, yet the session fell back to software.
    case hardwareEncoderUnavailable(String)

    /// English text (the display sink translates it with `SQL10n.localized`).
    public var errorDescription: String? {
        switch self {
        case .invalidSettings: "The export settings are not valid."
        case .cannotAddVideoInput: "The video encoder does not accept these settings."
        case .cannotAddAudioInput: "The audio encoder does not accept these settings."
        case .writerFailed(let why): "The file could not be written: \(why)"
        case .emptySource: "There is nothing to export."
        case .loudnessNeedsRewindableSource: "Loudness normalization needs an audio source that can be read twice."
        case .noAudio: "This sequence has no audio to export."
        case .hardwareEncoderUnavailable(let why): why
        }
    }
}

/// The encoder side of export (WINDOWS-PLAN seam 3): writes a file from rendered frames and timeline audio.
/// Mac: `AVExportEncoder` (AVAssetWriter + VideoToolbox). Windows: `FFmpegExportEncoder` in SQMediaFFmpeg (hardware
/// H.264/HEVC through AMF or Media Foundation; no ProRes). `progress` receives 0...1 and ends at 1. Canceling the
/// calling task removes the partial file and throws `CancellationError`.
public protocol ExportEncoding: Sendable {
    @discardableResult
    func export(video: any FrameSource, audio: (any AudioSource)?, settings: ExportSettings, to url: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport?
    /// One audio file (a stem, a language track) from `audio`: M4A, WAV or FLAC of `duration`, normalized when `settings`
    /// asks (Mac: `ExportWriter.exportAudioFile`).
    @discardableResult
    func exportAudioFile(_ audio: any AudioSource, format: AudioFileFormat, duration: Time, settings: AudioSettings, to url: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport?
}

extension ExportEncoding {
    /// Encoders without audio files (test fakes) say so.
    @discardableResult
    public func exportAudioFile(_ audio: any AudioSource, format: AudioFileFormat, duration: Time, settings: AudioSettings,
                                to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? {
        throw ExportError.writerFailed("this encoder writes no audio files")
    }
}

/// A source frame of a clip could not be decoded and "Continue on damaged frames" is off: the export stops here.
public struct ExportDecodeError: LocalizedError, CustomStringConvertible, Sendable, Equatable {
    public var clip: UUID
    public var clipName: String
    /// Sequence time of the output frame, and its timecode (HH:MM:SS:FF at the sequence frame rate).
    public var time: Time
    public var timecode: String
    public var reason: String
    public var errorDescription: String? {
        "Clip \u{201C}\(clipName)\u{201D} could not be decoded at \(timecode) (\(reason)). Replace or re-encode the media, "
            + "or turn on \u{201C}Continue on damaged frames\u{201D} to export with a placeholder for those frames."
    }

    /// The export queue shows `"\(error)"`: the same message.
    public var description: String { errorDescription ?? reason }

    /// Non-drop HH:MM:SS:FF of `t` at `frameDuration` (nominal integer rate).
    public static func timecode(_ t: Time, frameDuration fd: Time) -> String {
        let f = max(0, Int(t.frameIndex(frameDuration: fd)))
        let fps = max(1, Int((fd.timescale + fd.value / 2) / max(1, fd.value)))
        let s = f / fps
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60, f % fps)
    }
}
