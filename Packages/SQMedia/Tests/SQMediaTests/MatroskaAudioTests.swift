import AVFoundation
import CoreMedia
import Foundation
import SQCore
import Testing
@testable import SQMedia

// .mkv audio besides Opus / Vorbis: PCM and AAC-LC.

private func tmpURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString).mkv") }

private func read(_ src: WebMAudioSource, from: Int64, count: Int, channel: Int) throws -> [Float] {
    var buf = [Float](repeating: 0, count: count)
    let n = try buf.withUnsafeMutableBufferPointer { try src.read(from: from, count: count, into: $0.baseAddress!, channel: channel) }
    return Array(buf.prefix(n))
}

@Suite struct MatroskaAudioTests {
    @Test func pcm16StereoRoundTrips() throws {
        var w = WebMTestWriter()
        w.tracks = [.init(number: 1, isVideo: false, codecID: "A_PCM/INT/LIT", channels: 2, rate: 48_000, bitDepth: 16)]
        let value: (Int) -> Int16 = { Int16(truncatingIfNeeded: ($0 % 2000) * 10 - 10_000) }
        for p in 0..<100 {   // 10 ms packets of 480 frames, 1 s
            var d = Data()
            for i in 0..<480 {
                let v = value(p * 480 + i)
                for s in [v, -v] { d.append(UInt8(truncatingIfNeeded: s)); d.append(UInt8(truncatingIfNeeded: s >> 8)) }
            }
            w.frames.append(.init(track: 1, ms: p * 10, key: true, data: d))
        }
        let u = tmpURL(); try w.data().write(to: u); defer { try? FileManager.default.removeItem(at: u) }
        let src = try WebMAudioSource(file: try WebMFile.open(u), sampleRate: 48_000)
        #expect(src.totalFrames == 48_000 && !src.isMono)
        let l = try read(src, from: 960, count: 2000, channel: 0), r = try read(src, from: 960, count: 2000, channel: 1)
        #expect(l.count == 2000)
        for i in 0..<2000 {
            let e = Float(value(960 + i)) / 32768
            #expect(abs(l[i] - e) < 1e-6 && abs(r[i] + e) < 1e-6)
        }
    }

    @Test func pcm24MonoDecodes() throws {
        let dec = try PCMPacketDecoder(channels: 1, sampleRate: 48_000, bitDepth: 24, isFloat: false)
        // +0.5 (0x400000) and -0.5 (0xC00000), little endian.
        let out = dec.decode(Data([0x00, 0x00, 0x40, 0x00, 0x00, 0xC0]))
        #expect(out == [[0.5, -0.5]])
    }

    @Test func unsupportedPcmDepthIsReported() throws {
        #expect(throws: MediaError.self) { _ = try PCMPacketDecoder(channels: 2, sampleRate: 48_000, bitDepth: 8, isFloat: false) }
    }

    @Test func audioSpecificConfigParsing() {
        // AAC-LC, 48 kHz, stereo = 0x11 0x90; 44.1 kHz mono = 0x12 0x08.
        #expect(AACPacketDecoder.parse(config: Data([0x11, 0x90]))?.rate == 48_000)
        #expect(AACPacketDecoder.parse(config: Data([0x11, 0x90]))?.channels == 2)
        #expect(AACPacketDecoder.parse(config: Data([0x12, 0x08]))?.rate == 44_100)
        #expect(AACPacketDecoder.parse(config: Data([0x12, 0x08]))?.channels == 1)
        // HE-AAC (object type 5) and 5.1 are not handled.
        #expect(AACPacketDecoder.parse(config: Data([0x2B, 0x92])) == nil)
        #expect(AACPacketDecoder.parse(config: Data([0x11, 0xB0])) == nil)
        #expect(AACPacketDecoder.parse(config: Data([0x11])) == nil)
    }

    /// AudioSpecificConfig with channel configuration 0: AAC-LC, 48 kHz, a program config element, comment bytes.
    private func pceConfig(front: [Bool], comment: Int, core: Bool = false) -> Data {
        var bits: [Int] = []
        func put(_ v: Int, _ n: Int) { for k in (0..<n).reversed() { bits.append(v >> k & 1) } }
        put(2, 5); put(3, 4); put(0, 4); put(0, 1); put(core ? 1 : 0, 1)         // type, rate, channel config 0, frameLength, dependsOnCoreCoder
        if core { put(0x155, 14) }                          // coreCoderDelay
        put(0, 1)                                           // extensionFlag
        put(0, 4); put(1, 2); put(3, 4)                     // PCE tag, object type, rate index
        put(front.count, 4); put(0, 4); put(0, 4); put(0, 2); put(0, 3); put(0, 4)
        put(0, 1); put(0, 1); put(0, 1)                     // no mixdowns
        for cpe in front { put(cpe ? 1 : 0, 1); put(0, 4) }
        while bits.count % 8 != 0 { bits.append(0) }
        put(comment, 8)
        var out = Data(); for i in stride(from: 0, to: bits.count, by: 8) { out.append(UInt8(bits[i..<i + 8].reduce(0) { $0 << 1 | $1 })) }
        return out + Data(repeating: 0x41, count: comment)
    }

    @Test func longConfigWithProgramConfigElementParses() {
        let stereo = pceConfig(front: [true], comment: 200)
        #expect(stereo.count > 64)
        #expect(AACPacketDecoder.parse(config: stereo)?.channels == 2)
        #expect(AACPacketDecoder.parse(config: stereo)?.rate == 48_000)
        #expect(AACPacketDecoder.parse(config: pceConfig(front: [false], comment: 0))?.channels == 1)
        #expect(AACPacketDecoder.parse(config: pceConfig(front: [true, false, false], comment: 0)) == nil)   // 4 channels
    }

    @Test func configWithCoreCoderDelayParses() {
        let c = pceConfig(front: [true], comment: 0, core: true)
        #expect(AACPacketDecoder.parse(config: c)?.channels == 2)
        for n in 2..<5 { #expect(AACPacketDecoder.parse(config: c.prefix(n)) == nil) }   // ends inside the 14 delay bits
    }

    @Test func truncatedOrHostileConfigIsRejected() {
        let full = pceConfig(front: [true], comment: 0)
        for n in 2..<5 { #expect(AACPacketDecoder.parse(config: full.prefix(n)) == nil) }
        #expect(AACPacketDecoder.parse(config: Data(repeating: 0xFF, count: 100_000)) == nil)
        #expect(AACPacketDecoder.parse(config: Data([0x10, 0x00])) == nil)   // channel config 0 and nothing after it
    }

    @Test func aacLCEncodedHereDecodesBack() throws {
        // Encode a 440 Hz sine with the system AAC encoder, wrap the packets in Matroska, decode through WebMAudioSource.
        let rate = 48_000.0
        let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        var d = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 2, mBytesPerPacket: 0,
                                            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let aacFormat = AVAudioFormat(streamDescription: &d), let enc = AVAudioConverter(from: pcm, to: aacFormat) else {
            Issue.record("AAC encoder unavailable"); return
        }
        let packets = 40
        let total = packets * 1024
        let src = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(total))!
        src.frameLength = AVAudioFrameCount(total)
        for c in 0..<2 { for i in 0..<total { src.floatChannelData![c][i] = 0.5 * sinf(Float(i) * 2 * .pi * 440 / Float(rate)) } }
        var w = WebMTestWriter()
        var fed = false
        let asc = Data([0x11, 0x90])   // AAC-LC, 48 kHz, stereo
        for p in 0..<packets + 2 {
            let cb = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 1, maximumPacketSize: 4096)
            var err: NSError?
            _ = enc.convert(to: cb, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return src
            }
            if cb.packetCount == 0 { break }
            // `convert` returns as many packets as fit; keep one per call by splitting on the descriptions.
            let descs = cb.packetDescriptions!
            for k in 0..<Int(cb.packetCount) {
                let off = Int(descs[k].mStartOffset), len = Int(descs[k].mDataByteSize)
                let pkt = Data(bytes: cb.data.advanced(by: off), count: len)
                w.frames.append(.init(track: 1, ms: w.frames.count * 1024 * 1000 / 48_000, key: true, data: pkt))
            }
            _ = p
        }
        try #require(w.frames.count >= packets - 2)
        w.tracks = [.init(number: 1, isVideo: false, codecID: "A_AAC", codecPrivate: asc, channels: 2, rate: rate)]
        let u = tmpURL(); try w.data().write(to: u); defer { try? FileManager.default.removeItem(at: u) }
        let a = try WebMAudioSource(file: try WebMFile.open(u), sampleRate: 48_000)
        #expect(a.totalFrames == Int64(w.frames.count * 1024 - 1024))   // standard encoder delay trimmed
        let l = try read(a, from: 8192, count: 4096, channel: 0)
        #expect(l.count == 4096)
        let rms = sqrt(l.reduce(0) { $0 + $1 * $1 } / Float(l.count))
        #expect(abs(rms - Float(0.5) / Float(2).squareRoot()) < 0.05, "rms \(rms)")
    }

    @Test func descriptorLengthsAreVariableLength() {
        #expect(AACPacketDecoder.descriptorLength(5) == [5])
        #expect(AACPacketDecoder.descriptorLength(127) == [127])
        #expect(AACPacketDecoder.descriptorLength(128) == [0x81, 0x00])
        #expect(AACPacketDecoder.descriptorLength(300) == [0x82, 0x2C])
        // 2-byte config: ES descriptor body 3 + (2+13+2+2) + 3 = 25 bytes.
        let e = AACPacketDecoder.esds(config: Data([0x11, 0x90]))
        #expect(e.count == 4 + 2 + 25 && e[4] == 0x03 && e[5] == 25)
    }

    @Test func longConfigIsRejectedAndImportsWithoutAudio() async throws {
        var long = Data([0x12, 0x10]); long.append(Data(repeating: 7, count: AACPacketDecoder.maxConfigSize))   // over the bound
        #expect(throws: MediaError.self) { _ = try AACPacketDecoder(config: long) }
        var w = WebMTestWriter()
        w.tracks = [.init(number: 1, isVideo: false, codecID: "A_AAC", codecPrivate: long, channels: 2, rate: 44_100)]
        w.frames = [.init(track: 1, ms: 0, key: true, data: Data(repeating: 1, count: 20))]
        let u = tmpURL(); try w.data().write(to: u); defer { try? FileManager.default.removeItem(at: u) }
        #expect(throws: MediaError.self) { _ = try WebMAudioSource(file: try WebMFile.open(u), sampleRate: 48_000) }
        // As the only track the file is unreadable (an error, not a crash); with video it imports without audio.
        await #expect(throws: MediaError.self) { _ = try await MediaImporter.probeWebM(u) }
    }

    @Test func aacPrimingUsesCodecDelayOrStandard1024() throws {
        func total(delayNs: Int) throws -> Int64 {
            var w = WebMTestWriter()
            w.tracks = [.init(number: 1, isVideo: false, codecID: "A_AAC", codecPrivate: Data([0x11, 0x90]), channels: 2, rate: 48_000,
                              codecDelayNs: delayNs)]
            for i in 0..<10 { w.frames.append(.init(track: 1, ms: i * 21, key: true, data: Data(repeating: 1, count: 20))) }
            let u = tmpURL(); try w.data().write(to: u); defer { try? FileManager.default.removeItem(at: u) }
            return try WebMAudioSource(file: try WebMFile.open(u), sampleRate: 48_000).totalFrames
        }
        #expect(try total(delayNs: 0) == 10 * 1024 - 1024)
        #expect(try total(delayNs: 10_000_000) == 10 * 1024 - 480)
    }
}
