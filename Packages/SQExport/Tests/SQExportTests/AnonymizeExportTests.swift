import CoreVideo
import Foundation
import Testing
import SQAnalysis
import SQCore
import SQMedia
@testable import SQExport

// F7.11 Anonymize in export: a mask that must cover is drawn on stills, inside nested sequences and under mixed frames
// (frame blending, temporal filters). Larger, never missing. The cover in these tests is an Invert limited to the mask:
// on a solid red frame the covered part turns cyan, so one pixel tells covered from not.

private let fd = Time(1, 30)
private let width = 128, height = 64

/// Solid red frames that know their source time (a video), or not (`timed` false: a still).
private struct RedProvider: FrameProvider {
    var timed = true

    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                      kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height { for x in 0..<width {
            let p = base + y * stride + x * 4
            p[0] = 0; p[1] = 0; p[2] = 255; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        let info = VideoTrackInfo(width: width, height: height, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: fd, isVariableFrameRate: false)
        guard timed else { return ProvidedFrame(buffer: buf, info: info, sampleIndex: 0) }
        let i = max(0, sourceTime.frameIndex(frameDuration: fd))
        return ProvidedFrame(buffer: buf, info: info, start: fd * Int64(i), duration: fd, sampleIndex: Int(i))
    }
}

/// A clip whose Anonymize mask limits an Invert, and the keys its mattes are stored under.
private struct Covered {
    var clip: Clip
    var keys: [String]
    var part: String

    init(still: Bool = false) throws {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero,
                     mediaDuration: still ? nil : Time(10, 1), isStill: still)
        let pick = MagicSelection(points: [MagicPoint(position: Vec2(0.1, 0.5), subtract: false, sourceTime: .zero)], part: .face)
        let masks = c.addAnonymize([pick], target: .face, cover: .mosaic, subjectWidth: 8, frameWidth: width, frameHeight: height)
        let mask = try #require(masks.first)
        let added = c.addEffect(kind: ClipEffect.invertKind)
        let invert = try #require(added)
        c.setMask(mask, input: true, ofEffect: invert)
        c.effects.removeAll { $0.kind == ClipEffect.mosaicKind }
        let sel = try #require(c.masks.first?.magic)
        clip = c
        part = try #require(sel.partKey(media: c.media))
        keys = sel.matteKeys(media: c.media)
    }

    /// Stores a matte covering the columns `x` of the frame at source frame `frame`.
    func put(_ x: Range<Int>, frame: Int) {
        var v = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for i in x { v[y * width + i] = 1 } }
        MagicMatteStore.shared.put(SubjectMatte(width: width, height: height, values: v), key: part, pts: Double(frame) / 30)
    }

    func forget() { keys.forEach(MagicMatteStore.shared.remove) }
}

private func isCovered(_ pb: CVPixelBuffer, _ x: Int) -> Bool {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let p = base + (height / 2) * CVPixelBufferGetBytesPerRow(pb) + x * 4
    return p[1] > 128                                              // green: red inverted is cyan
}

private func source(_ tl: Timeline, sequences: [Timeline.ID: Timeline] = [:], timed: Bool = true, frames: Int = 8) throws -> TimelineFrameSource {
    try TimelineFrameSource(timeline: tl, sequences: sequences, provider: RedProvider(timed: timed), width: width, height: height,
                            frameDuration: fd, frameCount: frames, renderAhead: false)
}

private func timeline(_ clips: [Clip]) -> Timeline {
    Timeline(name: "t", format: SequenceFormat(width: width, height: height, frameDuration: fd), tracks: [Track(kind: .video, clips: clips)])
}

private let left = 0..<16, middle = 56..<72, right = 112..<128

@Suite struct AnonymizeExportTests {
    @Test func aStillWithoutAMatteIsCoveredWhole() async throws {
        let c = try Covered(still: true)
        defer { c.forget() }
        let pb = try await source(timeline([c.clip]), timed: false).frame(at: 3)
        #expect(isCovered(pb, 6) && isCovered(pb, 64) && isCovered(pb, 120))
    }

    @Test func aStillTakesTheMatteTrackedOnIt() async throws {
        let c = try Covered(still: true)
        defer { c.forget() }
        c.put(left, frame: 0)
        let pb = try await source(timeline([c.clip]), timed: false).frame(at: 3)
        #expect(isCovered(pb, 6) && !isCovered(pb, 64) && !isCovered(pb, 120))
    }

    @Test func aCoveredClipInsideANestedSequenceIsCovered() async throws {
        let c = try Covered()
        defer { c.forget() }
        c.put(left, frame: 0)
        let inner = timeline([c.clip])
        let nest = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero,
                        sequence: inner.id)
        let src = try source(timeline([nest]), sequences: [inner.id: inner])
        let first = try await src.frame(at: 0)
        #expect(isCovered(first, 6) && !isCovered(first, 64) && !isCovered(first, 120))
        // Past the tracked frame: the estimate, never nothing.
        let later = try await src.frame(at: 6)
        #expect(isCovered(later, 6))
    }

    @Test func frameBlendingCoversTheSubjectOfBothFrames() async throws {
        var c = try Covered()
        defer { c.forget() }
        c.put(left, frame: 0)
        c.put(right, frame: 1)
        c.clip.speed = ClipSpeed(percent: 50)
        c.clip.timeInterpolation = .frameBlend
        let src = try source(timeline([c.clip]))
        let own = try await src.frame(at: 0)                      // on source frame 0
        #expect(isCovered(own, 6) && !isCovered(own, 64) && !isCovered(own, 120))
        let mix = try await src.frame(at: 1)                      // half way between source frames 0 and 1
        #expect(isCovered(mix, 6) && isCovered(mix, 120) && !isCovered(mix, 64))
    }

    @Test func opticalFlowCoversTheWholePathBetweenBothFrames() async throws {
        var c = try Covered()
        defer { c.forget() }
        c.put(left, frame: 0)
        c.put(right, frame: 1)
        c.clip.speed = ClipSpeed(percent: 50)
        c.clip.timeInterpolation = .opticalFlow
        let mix = try await source(timeline([c.clip])).frame(at: 1)
        #expect(isCovered(mix, 6) && isCovered(mix, 64) && isCovered(mix, 120))
    }

    @Test func aTemporalFilterCoversTheSubjectOfEveryFrameItMixes() async throws {
        var c = try Covered()
        defer { c.forget() }
        c.put(left, frame: 0)
        c.put(middle, frame: 1)
        c.put(right, frame: 2)
        var e = try #require(ClipEffect.make(kind: ClipEffect.deflickerKind))
        e.parameters[ClipEffect.framesEachSideKey] = AnimatedProperty(1)
        c.clip.effects.append(e)
        let pb = try await source(timeline([c.clip])).frame(at: 1)
        #expect(isCovered(pb, 6) && isCovered(pb, 64) && isCovered(pb, 120))
        #expect(!isCovered(pb, 36) && !isCovered(pb, 92))
    }
}
