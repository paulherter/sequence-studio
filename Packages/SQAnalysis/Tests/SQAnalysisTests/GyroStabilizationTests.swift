import CoreVideo
import SQCore
import Foundation
import Testing
@testable import SQAnalysis

@Suite struct GyroStabilizationTests {
    private func box(_ type: String, _ payload: Data) -> Data {
        var d = Data()
        let size = UInt32(8 + payload.count)
        d.append(contentsOf: [UInt8(size >> 24), UInt8(size >> 16 & 255), UInt8(size >> 8 & 255), UInt8(size & 255)])
        d.append(contentsOf: Array(type.utf8))
        d.append(payload)
        return d
    }

    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("gyro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// ftyp, mdat (with a decoy "gpmd" in the picture data), then moov naming `code` in a sample description.
    private func movie(at url: URL, moovCode: String?) throws {
        var f = box("ftyp", Data("isom".utf8))
        f.append(box("mdat", Data("....gpmd....".utf8) + Data(count: 4096)))
        let stsd = box("stsd", Data(count: 8) + box(moovCode ?? "avc1", Data(count: 16)))
        f.append(box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd))))))
        try f.write(to: url)
    }

    @Test func findsTheMetadataTrackInTheMoov() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (code, source) in [("gpmd", GyroDataSource.goPro), ("rtmd", .sony), ("djmd", .dji), ("camm", .camm)] {
            let u = dir.appendingPathComponent("\(code).mp4")
            try movie(at: u, moovCode: code)
            #expect(GyroDataProbe.probe(u) == source)
        }
    }

    @Test func gyroBytesOutsideTheMoovDoNotCount() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = dir.appendingPathComponent("plain.mov")
        try movie(at: u, moovCode: nil)
        #expect(GyroDataProbe.moovBytes(u) != nil)
        #expect(GyroDataProbe.probe(u) == nil)
    }

    @Test func aSidecarLogCountsForAnyFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = dir.appendingPathComponent("clip.mov")
        try movie(at: u, moovCode: nil)
        try Data("GYROFLOW IMU LOG\n".utf8).write(to: dir.appendingPathComponent("clip.gcsv"))
        #expect(GyroDataProbe.sidecar(for: u)?.lastPathComponent == "clip.gcsv")
        #expect(GyroDataProbe.probe(u) == .sidecarGCSV)
    }

    @Test func notABoxFileOrMissingHasNoData() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("junk.mp4")
        try Data([0, 0, 0, 3, 1, 2, 3]).write(to: junk)
        #expect(GyroDataProbe.probe(junk) == nil)
        #expect(GyroDataProbe.probe(dir.appendingPathComponent("missing.mp4")) == nil)
        // A box whose size runs past the end of the file stops the walk.
        let cut = dir.appendingPathComponent("cut.mp4")
        try (box("ftyp", Data("isom".utf8)) + Data([0, 0, 0x10, 0, 0x6d, 0x6f, 0x6f, 0x76])).write(to: cut)
        #expect(GyroDataProbe.moovBytes(cut) == nil)
    }

    @Test func blockSaysNoDataFirstThenTheEngine() {
        struct Ready: GyroStabilizationEngine { var availability: GyroEngineAvailability { .available } }
        let missing = GyroflowEngine(libraryURL: URL(fileURLWithPath: "/nonexistent/libsqgyro.dylib"))
        #expect(GyroStabilization.block(source: nil, engine: missing) == GyroStabilization.noGyroDataReason)
        #expect(GyroStabilization.block(source: .goPro, engine: missing) == GyroflowEngine.missingReason)
        #expect(GyroStabilization.block(source: .sony, engine: Ready()) == nil)
        #expect(GyroStabilization.block(source: nil, engine: Ready()) == GyroStabilization.noGyroDataReason)
    }
}

@Suite struct GyroflowOfferTests {
    @Test func offeredOnlyWhenEveryClipCanUseIt() {
        #expect(GyroStabilization.offersGyroflow(blocks: [nil, nil]))
        #expect(!GyroStabilization.offersGyroflow(blocks: [nil, GyroStabilization.noGyroDataReason]))
        #expect(!GyroStabilization.offersGyroflow(blocks: []))
    }
}

/// A clip whose gyro log starts late, or whose first frame is not at pts 0: the engine gets the frame's file time
/// unshifted (Gyroflow looks samples up by absolute file time and holds the first pose before the first sample; the
/// Rust side pins that in Vendor/sqgyro `late_first_gyro_sample_holds_then_lines_up_with_pts`).
@Suite struct GyroTimestampTests {
    private final class Recorder: GyroStabilizationEngine, @unchecked Sendable {
        var availability: GyroEngineAvailability { .available }
        private let lock = NSLock()
        private var seen: [Int64] = []
        var timestamps: [Int64] { lock.lock(); defer { lock.unlock() }; return seen }
        func warp(_ frame: CVPixelBuffer, path: String, options: GyroflowOptions, timestampUS: Int64, wait: Bool) -> CVPixelBuffer? {
            lock.lock(); seen.append(timestampUS); lock.unlock(); return nil
        }
    }

    @Test func warperPassesTheFilePTSUnshifted() throws {
        let rec = Recorder()
        let warper = GyroFrameWarper(engine: rec, path: { _ in "/clip.mp4" })
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        let frame = try #require(pb)
        let id = UUID()
        for t in [Time(1001, 2000), Time(0, 1), Time(1_500_500, 3_000_000), Time(-1, 30)] {
            _ = warper.warp(frame, media: id, options: GyroflowOptions(), pts: t, wait: true)
        }
        #expect(rec.timestamps == [500_500, 0, 500_167, -33_333])
    }
}
