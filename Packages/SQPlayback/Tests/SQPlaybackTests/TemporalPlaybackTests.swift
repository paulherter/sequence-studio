import CoreVideo
import Foundation
import SQCore
import SQFrame
import SQFrameCoreVideo
import SQMedia
import SQRender
import Testing
@testable import SQPlayback

// Video Denoise / Deflicker neighbors and Motion Blur thinning in the render loop.

private func buffer() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pb)
    return pb!
}

private let filter = TemporalFilter(denoise: .init(framesEachSide: 4, best: true, motionSearch: 2))

@Suite struct TemporalPlaybackTests {
    private func neighbours(exact: Bool, cached: Set<Int>, damaged: Set<Int> = [], bounds: ClosedRange<Int> = 0...99,
                            filter: TemporalFilter = filter) -> (TemporalFrames, [Int], Bool) {
        let frames = Dictionary(uniqueKeysWithValues: (0..<100).map { ($0, buffer()) })
        var requested: [Int] = [], waited = false
        let tf = RenderLoop.temporalNeighbours(of: 50, filter: filter, exact: exact, bounds: bounds,
                                               cached: { cached.contains($0) ? frames[$0].map { SQFrame(pixelBuffer: $0) } : nil }, damaged: { damaged.contains($0) },
                                               request: { requested.append($0) }, wait: { waited = true })
        return (tf, requested, waited)
    }

    @Test func pausedFrameUsesTheFullWindowAndWaitsForIt() {
        let (tf, req, waited) = neighbours(exact: true, cached: [49, 48, 51])
        #expect(tf.filter == filter)
        #expect(tf.before.count == 2 && tf.after.count == 1)
        #expect(req == [47, 52] && waited)
        let (full, none, w2) = neighbours(exact: true, cached: Set(46...54))
        #expect(full.before.count == 4 && full.after.count == 4 && none.isEmpty && !w2)
    }

    @Test func playingUsesTheFastWindowWithWhatIsCached() {
        let (tf, req, waited) = neighbours(exact: false, cached: [49])
        #expect(tf.filter == filter.degraded(.fast) && tf.filter.radius == 1)
        #expect(tf.before.count == 1 && tf.after.isEmpty)
        #expect(req == [51] && !waited)
    }

    @Test func aDamagedNeighbourIsNotWaitedFor() {
        let (tf, req, waited) = neighbours(exact: true, cached: Set(46...49).union(Set(52...54)), damaged: [51])
        #expect(tf.before.count == 4 && tf.after.isEmpty && req.isEmpty && !waited)
    }

    /// Neighbors stay inside the clip's source range: frames cut away (maybe another shot) are never read or requested.
    @Test func neighboursStayInsideTheSourceRange() {
        let (tf, req, _) = neighbours(exact: true, cached: Set(0...99), bounds: 48...51)
        #expect(tf.before.count == 2 && tf.after.count == 1 && req.isEmpty)
        var tr = TemporalFilter.Trails(count: 4, spacing: 1, decay: 0.4, blend: .screen)
        tr.backward = true   // a reversed clip trails from the frames ahead
        let (back, _, _) = neighbours(exact: true, cached: Set(0...99), bounds: 0...52, filter: TemporalFilter(trails: tr))
        #expect(back.before.isEmpty && back.after.count == 2)
    }

    @Test func boundsComeFromTheLayersSourceRange() {
        let fd = Time(1, 30)
        let index = SampleIndex(entries: (0..<100).map {
            SampleIndex.Entry(pts: fd * Int64($0), dts: fd * Int64($0), duration: fd, isSync: $0 % 15 == 0, decodeOrdinal: $0)
        })
        var r = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: fd * 50)
        #expect(RenderLoop.temporalBounds(r, around: 50, in: index) == 0...99)
        r.sourceStart = fd * 40; r.sourceEnd = fd * 60
        #expect(RenderLoop.temporalBounds(r, around: 50, in: index) == 40...59)
        // A transition showing a handle frame outside the range keeps that frame in reach.
        #expect(RenderLoop.temporalBounds(r, around: 35, in: index) == 35...59)
    }

    @Test func playbackThinsMotionBlurSamples() {
        let f = SequenceFormat(width: 64, height: 64, frameDuration: Time(1, 25))
        var r = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero, transform: .identity)
        r.motionBlur = MotionBlurSamples(format: f, transforms: Array(repeating: .identity, count: 32))
        var small = r
        small.motionBlur = MotionBlurSamples(format: f, transforms: Array(repeating: .identity, count: 4))
        let out = RenderLoop.thinnedForPlayback([r, small])
        #expect(out[0].motionBlur?.transforms.count == MotionBlurSamples.playbackMaxSamples)
        #expect(out[1].motionBlur?.transforms.count == 4)
    }
}
