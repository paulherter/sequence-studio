import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import Synchronization
import Testing
@testable import SQAnalysis

/// A woven interlaced picture, W x H: a bright box on a flat background that sits `shift` px further right in the odd
/// rows (the later field of top-field-first video), so its left and right edges comb.
private enum Woven {
    static let width = 320, height = 180, shift = 12
    static let rows = 40..<120

    static func boxX(row y: Int, at start: Int) -> Int { y & 1 == 0 ? start : start + shift }

    static func inBox(_ x: Int, _ y: Int, start: Int) -> Bool {
        rows.contains(y) && (boxX(row: y, at: start)..<boxX(row: y, at: start) + 80).contains(x)
    }

    /// 4:2:2 8-bit bi-planar, as the analysis readers ask the decoder for interlaced media.
    static func planar(start: Int = 60) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, AnalysisFields.format, attrs as CFDictionary, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(b, 0)!, ls = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        for y in 0..<height {
            let row = (luma + y * ls).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width { row[x] = inBox(x, y, start: start) ? 220 : 90 }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(b, 1)!, cs = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
        for y in 0..<CVPixelBufferGetHeightOfPlane(b, 1) {
            memset(chroma + y * cs, 128, CVPixelBufferGetWidthOfPlane(b, 1) * 2)
        }
        return b
    }

    static func bgra(start: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<height {
            let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let v: UInt8 = inBox(x, y, start: start) ? 220 : 90
                row[x * 4] = v; row[x * 4 + 1] = v; row[x * 4 + 2] = v; row[x * 4 + 3] = 255
            }
        }
        return b
    }

    /// Six woven frames at 25 fps as ProRes 422 (intra, keeps the lines apart); the box moves 16 px per frame.
    /// `squeeze`: the file tags its pixels as that many times wider than high.
    static func movie(squeeze: Int = 1) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-woven-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if squeeze != 1 {
            settings[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: squeeze,
                                                    AVVideoPixelAspectRatioVerticalSpacingKey: 1]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<6 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(bgra(start: 60 + 16 * i), withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 25))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }
}

/// Green samples of a BGRA frame, row-major.
private func green(_ pb: CVPixelBuffer) -> (w: Int, h: Int, v: [Int]) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
    var v = [Int](repeating: 0, count: w * h)
    for y in 0..<h {
        let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w { v[y * w + x] = Int(row[x * 4 + 1]) }
    }
    return (w, h, v)
}

/// Samples that stick out of both vertical neighbors in the same direction by more than 40: what a comb is made of.
/// The box's first and last row are left out (a still horizontal edge is no comb).
private func combSamples(_ pb: CVPixelBuffer) -> Int {
    let (w, _, v) = green(pb)
    var n = 0
    for y in (Woven.rows.lowerBound + 2)..<(Woven.rows.upperBound - 2) {
        for x in 0..<w {
            let c = v[y * w + x], a = v[(y - 1) * w + x], b = v[(y + 1) * w + x]
            if (c - a) * (c - b) > 0, min(abs(c - a), abs(c - b)) > 40 { n += 1 }
        }
    }
    return n
}

/// The woven picture combs on two 12 px strips over 76 rows; every other row of them sticks out.
private let wovenAtLeast = 1200

extension VisionSuites {
@Suite struct DeinterlacedAnalysisTests {
    @Test func withoutAFieldOrderTheReaderAsksForAndHandsOnWhatItAlwaysDid() throws {
        let plain = AnalysisFields.readerSettings(nil)
        #expect(plain.count == 1)
        #expect(plain[kCVPixelBufferPixelFormatTypeKey as String] as? OSType == kCVPixelFormatType_32BGRA)
        let sized = AnalysisFields.readerSettings(nil, size: (160, 90))
        #expect(sized.count == 3)
        #expect(sized[kCVPixelBufferWidthKey as String] as? Int == 160 && sized[kCVPixelBufferHeightKey as String] as? Int == 90)
        // Interlaced: planar, at the stored size (fields need their lines).
        let fields = AnalysisFields.readerSettings(.topFirst, size: (160, 90))
        #expect(fields[kCVPixelBufferPixelFormatTypeKey as String] as? OSType == AnalysisFields.format)
        #expect(fields[kCVPixelBufferWidthKey as String] == nil && fields[kCVPixelBufferHeightKey as String] == nil)
        // Progressive media and an item with Deinterlace off: the very same buffer, no copy.
        let woven = Woven.planar()
        #expect(AnalysisFields.progressive(woven, nil) === woven)
        let bgra = Woven.bgra(start: 60)
        #expect(AnalysisFields.progressive(bgra, nil) === bgra)
        #expect(AnalysisFields.progressive(woven, .topFirst) !== woven)
    }

    @Test func theStabilizerRegistersDeinterlacedFrames() throws {
        func registered(_ order: FieldOrder?) throws -> CVPixelBuffer {
            let pass = VisionStabilizationAnalyzer.Pass(maxDimension: Woven.width, pictureWidth: Woven.width, pictureHeight: Woven.height,
                                                        start: 0, total: 1, progress: nil)
            pass.deinterlace = order
            pass.add(Woven.planar(), pts: .zero, orientation: .up)
            return try #require(pass.previous)
        }
        let woven = try registered(nil)
        #expect(combSamples(woven) >= wovenAtLeast)
        for order in FieldOrder.allCases {
            let clean = try registered(order)
            #expect(CVPixelBufferGetWidth(clean) == Woven.width && CVPixelBufferGetHeight(clean) == Woven.height)
            #expect(combSamples(clean) == 0, "order \(order)")
            // Still the picture: the box is there, the background too.
            let (w, _, v) = green(clean)
            #expect(v[80 * w + 100] > 180 && v[80 * w + 20] < 130)
        }
    }

    @Test func theFrameReaderHandsOutCombFreeFramesOfInterlacedMedia() async throws {
        let url = try await Woven.movie()
        defer { try? FileManager.default.removeItem(at: url) }
        func frames(_ order: FieldOrder?) async throws -> [(CVPixelBuffer, Double)] {
            var out: [(CVPixelBuffer, Double)] = []
            try await FrameReader(url: url, maxDimension: Woven.width, deinterlace: order).forEach(from: 0, to: 1) { pb, pts in
                out.append((pb, pts)); return true
            }
            return out
        }
        // Deinterlace off (or progressive media): the frames as stored, comb and all.
        let stored = try await frames(nil)
        #expect(stored.count == 6)
        for (pb, _) in stored { #expect(combSamples(pb) >= wovenAtLeast) }
        let clean = try await frames(.topFirst)
        #expect(clean.map(\.1) == stored.map(\.1))
        for (i, (pb, _)) in clean.enumerated() {
            #expect(CVPixelBufferGetWidth(pb) == Woven.width && CVPixelBufferGetHeight(pb) == Woven.height)
            #expect(combSamples(pb) <= 8, "frame \(i): \(combSamples(pb)) comb samples")
            // The earlier field's box (even rows) survives where it was.
            let (w, _, v) = green(pb)
            let x = 60 + 16 * i
            #expect(v[80 * w + x + 40] > 180 && v[80 * w + x - 20] < 130)
        }
    }

    @Test func subjectDetectionLooksAtADeinterlacedFrame() async throws {
        let url = try await Woven.movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let detector = VisionSubjectDetector(url: url, maxDimension: Woven.width, deinterlace: .topFirst)
        let frame = try #require(try await detector.progressiveFrame(near: 0.08) { combSamples($0) })
        #expect(frame.width == Woven.width)
        #expect(frame.probe <= 8)
        _ = try await detector.subjects(atSourceTime: Time(2, 25))       // must not throw
        _ = try await VisionSubjectDetector(url: url, maxDimension: Woven.width).subjects(atSourceTime: Time(2, 25))
    }

    /// Frames at 0, 0.04, 0.08 ... s. The reader hands out the frame on screen at the start of its window first: the
    /// earliest frame of the window is up to two frames before the asked time.
    @Test func subjectDetectionLooksAtTheFrameNearestToTheAskedTime() async throws {
        let url = try await Woven.movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let detector = VisionSubjectDetector(url: url, maxDimension: Woven.width, deinterlace: .topFirst)
        for (asked, nearest) in [(0.08, 0.08), (0.13, 0.12), (0.10, 0.08), (0.11, 0.12), (0.0, 0.0), (0.21, 0.20)] {
            let frame = try #require(try await detector.progressiveFrame(near: asked) { _ in 0 })
            #expect(abs(frame.pts - nearest) < 1e-3, "asked \(asked): \(frame.pts)")
        }
        // No frame within the window: the caller falls back to the image generator.
        #expect(try await detector.progressiveFrame(near: 0.5) { _ in 0 } == nil)
        // The same detector again and again (a Reframe analysis): every call finds its frame.
        for _ in 0..<3 { #expect(try await detector.progressiveFrame(near: 0.16) { _ in 0 }?.pts == 0.16) }
    }

    @Test func subjectDetectionSeesInterlacedFramesInTheShapeTheyAreShownIn() async throws {
        let url = try await Woven.movie(squeeze: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        // The file's own tag: 320 x 180 stored pixels, each twice as wide as high, are shown 640 x 180.
        let tagged = try #require(try await VisionSubjectDetector(url: url, maxDimension: Woven.width, deinterlace: .topFirst)
            .progressiveFrame(near: 0.08) { _ in 0 })
        #expect(tagged.width == 320 && tagged.height == 90)
        // The item's source settings say otherwise: theirs is used.
        let square = try #require(try await VisionSubjectDetector(url: url, maxDimension: Woven.width, deinterlace: .topFirst,
                                                                  pixelAspect: .square).progressiveFrame(near: 0.08) { _ in 0 })
        #expect(square.width == 320 && square.height == 180)
        let wide = try #require(PixelAspect(4, 3))
        let chosen = try #require(try await VisionSubjectDetector(url: url, maxDimension: Woven.width, deinterlace: .topFirst,
                                                                  pixelAspect: wide).progressiveFrame(near: 0.08) { _ in 0 })
        #expect(chosen.width == 320 && chosen.height == 135)
        _ = try await VisionSubjectDetector(url: url, maxDimension: Woven.width, deinterlace: .topFirst)
            .subjects(atSourceTime: Time(2, 25))                       // must not throw
    }

    /// Comb samples of every frame a fake was handed; the bright box is its one object / person.
    final class CombCounter: InstanceSegmenting, PersonSegmenting, PersonDetecting, @unchecked Sendable {
        let combs = Mutex<[Int]>([])
        private func bright(_ pb: CVPixelBuffer) -> (w: Int, h: Int, on: [Bool]) {
            combs.withLock { $0.append(combSamples(pb)) }
            let (w, h, v) = green(pb)
            return (w, h, v.map { $0 > 180 })
        }
        func segment(_ pb: CVPixelBuffer) throws -> InstanceFrame? {
            let (w, h, on) = bright(pb)
            return InstanceFrame(labels: InstanceLabels(width: w, height: h, labels: on.map { $0 ? 1 : 0 }))
        }
        func segment(_ pb: CVPixelBuffer) throws -> SubjectMatte? {
            let (w, h, on) = bright(pb)
            return SubjectMatte(width: w, height: h, values: on.map { $0 ? 1 : 0 })
        }
        func detect(_ pb: CVPixelBuffer, bodies: Bool) throws -> (bodies: [AnonymizeBox], faces: [AnonymizeFace]) {
            _ = bright(pb)
            return ([], [])
        }
        var seen: [Int] { combs.withLock { $0 } }
    }

    @Test func theSubjectMaskToolPicksAndTracksOnDeinterlacedFrames() async throws {
        let url = try await Woven.movie()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MagicMaskTracker(url: url, segmenter: CombCounter()).deinterlace == nil)
        let click = [MagicPoint(position: Vec2(100.0 / 320, 0.5), subtract: false, sourceTime: .zero)]
        for order in [FieldOrder?.none, .topFirst] {
            let counter = CombCounter()
            let tracker = MagicMaskTracker(url: url, segmenter: counter, deinterlace: order)
            // Hover and pick: the frame the monitor shows.
            let picked = try #require(try await tracker.segment(at: 0.09))
            #expect(abs(picked.pts - 0.08) < 1e-3)
            #expect(counter.seen.count == 1)
            // Track, forward and backward.
            let store = MagicMatteStore(directory: nil)
            let forward = try await tracker.track(key: "f", points: click, from: 0, to: 0.2, store: store)
            #expect(forward.frames == 6)
            let back = [MagicPoint(position: Vec2(180.0 / 320, 0.5), subtract: false, sourceTime: Time(5, 25))]
            _ = try await tracker.track(key: "b", points: back, from: 0.2, to: 0, store: store)
            let seen = counter.seen
            #expect(seen.count >= 13)
            if order == nil {
                #expect(seen.allSatisfy { $0 >= wovenAtLeast }, "as stored: \(seen)")
            } else {
                #expect(seen.allSatisfy { $0 <= 8 }, "deinterlaced: \(seen)")
            }
        }
    }

    @Test func anonymizeFindsPeopleOnADeinterlacedFrame() async throws {
        let url = try await Woven.movie()
        defer { try? FileManager.default.removeItem(at: url) }
        for order in [FieldOrder?.none, .bottomFirst] {
            let counter = CombCounter()
            let found = try #require(try await Anonymizer(url: url, segmenter: counter, detector: counter, deinterlace: order)
                .findPeople(at: 0.09))
            #expect(abs(found.pts - 0.08) < 1e-3)
            let seen = counter.seen
            #expect(seen.count == 2)                 // the segmenter and the detector, on the same frame
            #expect(seen.allSatisfy { order == nil ? $0 >= wovenAtLeast : $0 <= 8 }, "\(String(describing: order)): \(seen)")
        }
    }

    @Test func precomputedSubjectMattesAreMadeOfDeinterlacedFramesUnderTheirOwnKey() async throws {
        let url = try await Woven.movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let media = UUID()
        let plain = SubjectMattePrecompute.cacheKey(media: media, path: url.path)
        #expect(SubjectMattePrecompute.cacheKey(media: media, path: url.path, deinterlace: nil) == plain)
        let top = SubjectMattePrecompute.cacheKey(media: media, path: url.path, deinterlace: .topFirst)
        #expect(top != plain && top != SubjectMattePrecompute.cacheKey(media: media, path: url.path, deinterlace: .bottomFirst))
        for (order, key) in [(FieldOrder?.none, plain), (.topFirst, top)] {
            let counter = CombCounter()
            let store = MagicMatteStore(directory: nil)
            let pre = SubjectMattePrecompute(store: store, segmenter: counter, maxDimension: Woven.width)
            #expect(pre.request(media: media, url: url, from: 0, to: 0.2, start: 0, deinterlace: order))
            await pre.waitUntilIdle()
            #expect(store.times(key: key).count == 6)
            let seen = counter.seen
            #expect(seen.count == 6)
            #expect(seen.allSatisfy { order == nil ? $0 >= wovenAtLeast : $0 <= 8 }, "\(String(describing: order)): \(seen)")
        }
    }

    /// The reader asks for 4:2:2 planar frames; one that does not take them gets the next format, and with none the
    /// frames as stored. Read on the frame lane's rules: this test only starts readers and takes their first frame.
    @Test func aReaderThatRefusesThePlanarFormatFallsBackInsteadOfFailing() async throws {
        let url = try await Woven.movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        func first(_ order: FieldOrder?, _ formats: [OSType]) throws -> CVPixelBuffer {
            let (reader, output) = try AnalysisFields.start(asset: asset, track: track, order: order, formats: formats)
            defer { reader.cancelReading() }
            let sample = try #require(output.copyNextSampleBuffer())
            return try #require(CMSampleBufferGetImageBuffer(sample))
        }
        #expect(AnalysisFields.fieldFormats.first == AnalysisFields.format && AnalysisFields.fieldFormats.count == 2)
        // Every format asked for is one the deinterlace pass reads: the picture comes out comb free.
        for format in AnalysisFields.fieldFormats {
            let pb = try first(.topFirst, [format])
            #expect(CVPixelBufferGetPixelFormatType(pb) == format)
            let clean = AnalysisFields.progressive(pb, .topFirst)
            #expect(clean !== pb, "format \(format)")
        }
        // None taken: the frames as stored, which the pass hands on as they are.
        let stored = try first(.topFirst, [])
        #expect(CVPixelBufferGetPixelFormatType(stored) == kCVPixelFormatType_32BGRA)
        #expect(AnalysisFields.progressive(stored, .topFirst) === stored)
        #expect(combSamples(stored) >= wovenAtLeast)
        // Progressive media: BGRA, as always.
        #expect(CVPixelBufferGetPixelFormatType(try first(nil, AnalysisFields.fieldFormats)) == kCVPixelFormatType_32BGRA)
        // A track of another asset is refused by `canAdd` for every format: an error, not an exception.
        let other = try await Woven.movie()
        defer { try? FileManager.default.removeItem(at: other) }
        let foreign = try #require(try await AVURLAsset(url: other).loadTracks(withMediaType: .video).first)
        #expect(throws: StabilizationError.self) {
            _ = try AnalysisFields.start(asset: asset, track: foreign, order: .topFirst)
        }
    }

    @Test func theTrackerPassesItsFieldOrderOnAndTheStabilizerCacheKeysIt() async throws {
        let url = try await Woven.movie()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(VisionMaskTracker(url: url).deinterlace == nil)
        #expect(VisionMaskTracker(url: url, deinterlace: .bottomFirst).deinterlace == .bottomFirst)
        #expect(VisionStabilizationAnalyzer(url: url, cache: nil).deinterlace == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-fields-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = StabilizationCache(cachesDirectory: dir)
        let range = TimeRange(start: .zero, duration: Time(6, 25))
        let plain = try #require(cache.key(url: url, range: range, maxDimension: 512))
        #expect(cache.key(url: url, range: range, maxDimension: 512, deinterlace: nil) == plain)
        let top = try #require(cache.key(url: url, range: range, maxDimension: 512, deinterlace: .topFirst))
        #expect(top != plain)
        #expect(cache.key(url: url, range: range, maxDimension: 512, deinterlace: .bottomFirst) != top)
        // An analysis of the whole clip runs on deinterlaced frames without complaint.
        let a = try await VisionStabilizationAnalyzer(url: url, maxDimension: Woven.width, cache: nil, minFrameInterval: 0,
                                                      deinterlace: .topFirst)
            .analyze(sourceRange: range, pictureWidth: Woven.width, pictureHeight: Woven.height, progress: nil)
        #expect(a.frameTimes.count == 6)
    }
}
}
