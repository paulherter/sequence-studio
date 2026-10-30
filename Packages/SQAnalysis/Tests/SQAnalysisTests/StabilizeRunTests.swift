import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import Synchronization
import Testing
@testable import SQAnalysis

/// A real file through the real analyzer: the run reports progress, reaches 100 % and plans a correction that cancels the
/// shake (the maintainer's 2026-10-17 report: the status stayed at "Starting… 0 %" and the picture stayed shaky).
extension VisionSuites {
@Suite struct StabilizeRunTests {
    static let width = 1280, height = 720, frames = 24, fps: Int32 = 24

    /// Camera shake of frame i (px, y down): a deterministic wobble of several pixels.
    static func shake(_ i: Int) -> (dx: Double, dy: Double) {
        (6 * sin(Double(i) * 1.7) + 3 * sin(Double(i) * 0.6), 4 * cos(Double(i) * 2.3))
    }

    static func frame(_ i: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let s = shake(i)
        ctx.translateBy(x: s.dx, y: -s.dy)
        var state: UInt64 = 7
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        for _ in 0..<600 {
            let x = (next() * 1.2 - 0.1) * Double(width), y = (next() * 1.2 - 0.1) * Double(height), d = 8 + next() * 60
            ctx.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
            if next() < 0.5 { ctx.fillEllipse(in: CGRect(x: x, y: y, width: d, height: d * 0.7)) }
            else { ctx.fill(CGRect(x: x, y: y, width: d, height: d * 0.8)) }
        }
        return b
    }

    static func movie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shaky-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(frame(i), withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    @Test func aShakyClipIsAnalyzedToOneHundredPercentAndPlannedStable() async throws {
        let url = try await Self.movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let seen = Mutex<[Double]>([])
        let started = ContinuousClock.now
        let range = TimeRange(start: .zero, duration: Time(Int64(Self.frames), Int64(Self.fps)))
        let analysis = try await VisionStabilizationAnalyzer(url: url, cache: nil)
            .analyze(sourceRange: range, pictureWidth: Self.width, pictureHeight: Self.height) { p in seen.withLock { $0.append(p) } }
        let took = ContinuousClock.now - started
        print("StabilizeRunTests: \(Self.frames) frames analyzed in \(took)")
        let reports = seen.withLock { $0 }
        #expect(analysis.frameTimes.count == Self.frames)
        #expect(reports.contains { $0 > 0 && $0 < 1 }, "progress is reported while it runs")
        #expect(reports.last == 1)
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })

        // The measured path must follow the shake, and the plan must cancel most of it.
        var options = StabilizerOptions()
        options.mode = .locked      // "No Motion": every frame is held at one pose, so the shake left is easy to measure
        let plan = try #require(Stabilizer.plan(analysis, options: options))
        #expect(plan.uncorrectedFrames < plan.corrections.count, "the shot is stabilized, not left as shot")
        // Shake left in the picture = spread of (true shake + correction) around its mean, against the spread of the shake.
        func spread(_ v: [(Double, Double)]) -> Double {
            let mx = v.map(\.0).reduce(0, +) / Double(v.count), my = v.map(\.1).reduce(0, +) / Double(v.count)
            return (v.map { ($0.0 - mx) * ($0.0 - mx) + ($0.1 - my) * ($0.1 - my) }.reduce(0, +) / Double(v.count)).squareRoot()
        }
        let shakes = plan.corrections.indices.map { (Self.shake($0).dx, Self.shake($0).dy) }
        let left = plan.corrections.indices.map { (Self.shake($0).dx + plan.corrections[$0].position.x,
                                                   Self.shake($0).dy + plan.corrections[$0].position.y) }
        #expect(spread(left) < spread(shakes) * 0.3, "shake left \(spread(left)) px of \(spread(shakes)) px")
    }
}
}
