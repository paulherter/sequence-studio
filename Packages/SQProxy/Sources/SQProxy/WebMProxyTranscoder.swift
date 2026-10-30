@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import SQMedia

/// Proxy for WebM / Matroska and MXF sources: AVAssetReader cannot open these, so frames come from the container's demuxer +
/// `VTVideoDecoder` and audio from its audio source (`WebMReadback`), and go to the same ProRes / PCM writer setup as `ProxyTranscoder`.
enum WebMProxyTranscoder {
    static let audioRate = 48_000
    static let audioChunk = 4_800

    static func transcode(source: URL, kind: ProxyKind, destination: URL, timeRange: TimeRange?,
                          progress: @Sendable @escaping (Double) -> Void) async throws -> TranscodeOutput {
        try Task.checkCancellation()
        let (demux, deinterlace) = try await WebMReadback.openDemuxer(source)
        let dims = CMVideoFormatDescriptionGetDimensions(demux.formatDescription)
        let srcDims = ProxyDimensions(width: Int(dims.width), height: Int(dims.height))
        let outDims = srcDims.scaled(divisor: kind.scaleDivisor)
        let full = demux.index.duration
        let range = timeRange ?? TimeRange(start: .zero, duration: full)
        guard range.duration > .zero else { throw ProxyTranscodeError.invalidTime("empty range") }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: kind == .optimized ? AVVideoCodecType.proRes422 : AVVideoCodecType.proRes422Proxy,
            AVVideoWidthKey: outDims.width, AVVideoHeightKey: outDims.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        ])
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        var audio: (any AudioSource)?
        var audioTotal: Int64 = 0
        var aIn: AVAssetWriterInput?
        if let (a, total) = try? await WebMReadback.openAudio(source, sampleRate: audioRate) {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audioRate, AVNumberOfChannelsKey: a.isMono ? 1 : 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); aIn = input; audio = a; audioTotal = total }
        }

        guard writer.startWriting() else { throw ProxyTranscodeError.writerFailed(writer.error?.localizedDescription ?? "?") }
        let start = CMTime(value: range.start.value, timescale: CMTimeScale(clamping: range.start.timescale))
        writer.startSession(atSourceTime: start)

        var audioFinished = false
        var audioPos = Int64(Double(range.start.value) / Double(range.start.timescale) * Double(audioRate))
        let audioEnd = audio.map { _ in min(audioTotal, Int64((Double(range.end.value) / Double(range.end.timescale) * Double(audioRate)).rounded(.up))) } ?? 0
        let total = max(Double(range.duration.value) / Double(range.duration.timescale), 1e-6)
        let t0 = Double(range.start.value) / Double(range.start.timescale)

        /// Audio up to `seconds` (kept only just ahead of the video: the writer holds back audio until video reaches it,
        /// and its video queue is short, so audio far ahead stalls both). While video is still being fed the audio input may be full (the writer waits for the
        /// other track to catch up): then stop instead of waiting, or neither side would ever move.
        func pumpAudio(upTo seconds: Double, wait: Bool) async throws {
            guard let audio, let aIn, !audioFinished else { return }
            defer {   // a finished track must be marked, or the writer waits for it to interleave with the video
                if audioPos >= audioEnd { aIn.markAsFinished(); audioFinished = true }
            }
            while audioPos < audioEnd, Double(audioPos) / Double(audioRate) < seconds {
                if !wait && !aIn.isReadyForMoreMediaData { break }
                try await waitReady(aIn, writer)
                let n = Int(min(Int64(audioChunk), audioEnd - audioPos))
                guard let sb = try pcmBuffer(audio, from: audioPos, count: n) else { audioPos = audioEnd; break }
                guard aIn.append(sb) else { break }
                audioPos += Int64(n)
            }
        }

        do {
            var count = 0
            try await WebMReadback.forEachFrame(demuxer: demux, range: range, deinterlace: deinterlace) { frame in
                try Task.checkCancellation()
                let t = Double(frame.pts.value) / Double(frame.pts.timescale)
                try await pumpAudio(upTo: t + 0.1, wait: false)
                // Whichever input is ready gets data: while video is full the writer may be waiting for more audio.
                while !vIn.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    if writer.status == .failed { throw ProxyTranscodeError.writerFailed(writer.error?.localizedDescription ?? "?") }
                    try await pumpAudio(upTo: t + 10, wait: false)
                    try await Task.sleep(for: .milliseconds(4))
                }
                let sb = try sampleBuffer(frame)
                guard vIn.append(sb) else { throw ProxyTranscodeError.writerFailed(writer.error?.localizedDescription ?? "append failed") }
                count += 1
                progress(min(0.999, max(0, (t - t0) / total)))
            }
            guard count > 0 else { throw ProxyTranscodeError.readerFailed("no frames") }
            vIn.markAsFinished()   // the writer then stops waiting for video and takes the rest of the audio
            try await pumpAudio(upTo: .infinity, wait: true)
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        if !audioFinished { aIn?.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw ProxyTranscodeError.writerFailed(writer.error?.localizedDescription ?? "?")
        }
        progress(1)
        return TranscodeOutput(dimensions: outDims, sourceDuration: range.duration)
    }

    private static func waitReady(_ input: AVAssetWriterInput, _ writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed { throw ProxyTranscodeError.writerFailed(writer.error?.localizedDescription ?? "?") }
            try await Task.sleep(for: .milliseconds(4))
        }
    }

    static func sampleBuffer(_ frame: DecodedFrame) throws -> CMSampleBuffer {
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame.pixelBuffer, formatDescriptionOut: &fd) == noErr,
              let fd else { throw ProxyTranscodeError.readerFailed("format") }
        let scale = CMTimeScale(clamping: frame.pts.timescale)
        var timing = CMSampleTimingInfo(duration: CMTime(value: frame.duration.value, timescale: CMTimeScale(clamping: frame.duration.timescale)),
                                        presentationTimeStamp: CMTime(value: frame.pts.value, timescale: scale), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame.pixelBuffer, formatDescription: fd,
                                                       sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb
        else { throw ProxyTranscodeError.readerFailed("sample buffer") }
        return sb
    }

    /// `count` frames of 16-bit interleaved PCM starting at `from`; nil at the end of the media.
    static func pcmBuffer(_ src: any AudioSource, from: Int64, count: Int) throws -> CMSampleBuffer? {
        let channels = src.isMono ? 1 : 2
        var l = [Float](repeating: 0, count: count), r = [Float](repeating: 0, count: count)
        let got = try l.withUnsafeMutableBufferPointer { try src.read(from: from, count: count, into: $0.baseAddress!, channel: 0) }
        if channels == 2 { _ = try r.withUnsafeMutableBufferPointer { try src.read(from: from, count: count, into: $0.baseAddress!, channel: 1) } }
        guard got > 0 else { return nil }
        // The caller zero-fills past the end; keep the chunk length so the writer sees a continuous timeline.
        var pcm = [Int16](repeating: 0, count: count * channels)
        func q(_ x: Float) -> Int16 { Int16(max(-1, min(1, x)) * 32767) }
        for i in 0..<got {
            pcm[i * channels] = q(l[i])
            if channels == 2 { pcm[i * channels + 1] = q(r[i]) }
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(audioRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var fd: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &fd) == noErr, let fd
        else { return nil }
        let bytes = pcm.count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block
        else { return nil }
        guard pcm.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }) == noErr
        else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: count,
            presentationTimeStamp: CMTime(value: from, timescale: CMTimeScale(audioRate)), packetDescriptions: nil,
            sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
