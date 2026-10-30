import AVFoundation
import CoreMedia
import Foundation
import SQCore

// Create Angles Clip (F7.16): what the sync choices need from the files. The matching itself is SQCore
// (`AnglesAudioSync`), which has no AVFoundation.

public enum AnglesSync {
    /// Steps per second of the envelopes: 10 ms, finer than a frame at any usual rate.
    public static let envelopeRate = WaveformData.envelopeRate

    /// The file's loudness envelope (through the waveform cache: a file whose waveform exists is not decoded again).
    public static func envelope(url: URL) async throws -> [Float] {
        try await WaveformBuilder.build(url: url).envelope(rate: envelopeRate)
    }

    /// Time of day of the file's first frame from its start timecode: MXF material package, or a QuickTime/MP4 timecode
    /// track. nil when the file carries none.
    /// `ntsc`: the picture runs at a 1000/1001 rate (23.976, 29.97, 59.94), which MXF does not say for non-drop timecode.
    public static func startTimecode(url: URL, ntsc: Bool = false) async -> Time? {
        if MXFFile.isMXF(url) {
            guard let tc = (try? MXFFile.open(url))?.timecode else { return nil }
            return time(frames: tc.startFrame, base: tc.base, slowed: tc.dropFrame || ntsc)
        }
        return await quickTimeStart(url)
    }

    /// `frames` timecode frames at `base` per second as time; `slowed` = the real rate is base x 1000/1001.
    public static func time(frames: Int64, base: Int, slowed: Bool) -> Time? {
        guard base > 0 else { return nil }
        return slowed ? Time(frames * 1001, Int64(base) * 1000) : Time(frames, Int64(base))
    }

    /// First sample of the timecode track: a big-endian 32-bit frame number counted in the track's frame duration.
    private static func quickTimeStart(_ url: URL) async -> Time? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let desc = try? await track.load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(desc) == kCMTimeCodeFormatType_TimeCode32 else { return nil }
        let fd = CMTimeCodeFormatDescriptionGetFrameDuration(desc)
        guard fd.isValid, fd.value > 0, fd.timescale > 0, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample),
              CMBlockBufferGetDataLength(block) >= 4 else { return nil }
        var raw: UInt32 = 0
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &raw) == kCMBlockBufferNoErr else { return nil }
        let frames = Int64(Int32(bitPattern: UInt32(bigEndian: raw)))
        return Time(frames * fd.value, Int64(fd.timescale))
    }
}
