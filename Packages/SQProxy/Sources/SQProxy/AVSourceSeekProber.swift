@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import SQMedia

/// Cheap probe: codec from the format description, sync-sample spacing from an `AVSampleCursor` walk over the
/// first samples (sample table only, no media data is read).
public struct AVSourceSeekProber: SourceSeekProbing {
    public var maxSamples: Int
    public init(maxSamples: Int = 600) { self.maxSamples = maxSamples }

    public func probe(_ url: URL) async throws -> SourceSeekInfo {
        if WebMReadback.handles(url) { return try await probeWebM(url) }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else {
            throw ProxyTranscodeError.noVideoTrack
        }
        let fourCC = Self.string(CMFormatDescriptionGetMediaSubType(format))
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: .zero) else {
            return SourceSeekInfo(codecFourCC: fourCC, maxSyncDistance: nil)
        }
        var index = 0, lastSync: Int?, maxGap = 0
        while index < maxSamples {
            if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                if let l = lastSync { maxGap = max(maxGap, index - l) }
                lastSync = index
            }
            if cursor.stepInDecodeOrder(byCount: 1) != 1 { break }
            index += 1
        }
        // No second sync sample inside the window: the gap is at least the window size.
        if maxGap == 0, index > 1 { maxGap = lastSync == nil ? index : index - (lastSync ?? 0) }
        return SourceSeekInfo(codecFourCC: fourCC, maxSyncDistance: index > 1 ? maxGap : nil, scannedFrames: index)
    }

    /// WebM and MXF: the demuxer's sample index already knows the key frames.
    func probeWebM(_ url: URL) async throws -> SourceSeekInfo {
        let (demux, _) = try await WebMReadback.openDemuxer(url)
        return SourceSeekInfo(codecFourCC: Self.string(CMFormatDescriptionGetMediaSubType(demux.formatDescription)),
                              syncFlags: demux.index.entries.lazy.map(\.isSync), maxSamples: maxSamples)
    }

    static func string(_ c: FourCharCode) -> String {
        String(bytes: [UInt8(c >> 24), UInt8(c >> 16 & 255), UInt8(c >> 8 & 255), UInt8(c & 255)], encoding: .ascii) ?? "?"
    }
}
