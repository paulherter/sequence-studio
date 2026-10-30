import CoreVideo
import Foundation
import SQCore
import Testing
@testable import SQAnalysis

/// The Quality edge step of a tracked subject matte (`SubjectMatteRefiner`): synthetic pictures only, no model and
/// no network.
@Suite(.serialized) struct SubjectMatteRefinerTests {
    struct Scene {
        let frame: CVPixelBuffer
        /// The subject's true alpha at the frame's size.
        let truth: [Float]
        /// What the tracking model gives: a hard mask at 256 x 256, scaled to the frame.
        let coarse: SubjectMatte
    }

    /// A disc with an edge `soft` px wide (alpha falls linearly across it) on a background of another color.
    static func scene(_ w: Int, _ h: Int, soft: Double, format: OSType = kCVPixelFormatType_32BGRA) throws -> Scene {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, format, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &made)
        let pb = try #require(made)
        var truth = [Float](repeating: 0, count: w * h)
        let cx = Double(w) * 0.5, cy = Double(h) * 0.5, radius = Double(h) * 0.3
        for y in 0..<h {
            for x in 0..<w {
                let d = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot() - radius
                truth[y * w + x] = Float(min(max(0.5 - d / soft, 0), 1))
            }
        }
        if format == kCVPixelFormatType_32BGRA {
            CVPixelBufferLockBaseAddress(pb, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pb)
            let subject: [Float] = [120, 170, 220], back: [Float] = [110, 60, 30]   // B, G, R
            for y in 0..<h {
                for x in 0..<w {
                    let a = truth[y * w + x], p = base + y * row + x * 4
                    // A slow ramp across the background, so it is not one flat color.
                    let ramp = Float(x) / Float(w) * 20
                    for c in 0..<3 { p[c] = UInt8(min(max(a * subject[c] + (1 - a) * (back[c] + ramp), 0), 255)) }
                    p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
        }
        let size = SubjectTrackRules.logitSize
        var logits = [Float](repeating: -8, count: size * size)
        for y in 0..<size {
            for x in 0..<size where truth[min(y * h / size, h - 1) * w + min(x * w / size, w - 1)] > 0.5 { logits[y * size + x] = 8 }
        }
        return Scene(frame: pb, truth: truth, coarse: SubjectTrackRules.matte(logits: logits, size: size, width: w, height: h))
    }

    static func sum(_ v: [Float]) -> Double { v.reduce(0.0) { $0 + Double($1) } }

    /// Mean absolute error against the truth over the pixels of the soft edge (truth 0.2 ... 0.8), and the share of
    /// those pixels the matte gives a fractional alpha (0.1 ... 0.9).
    static func edge(_ values: [Float], _ truth: [Float]) -> (error: Double, fractional: Double) {
        var error = 0.0, fractional = 0, n = 0
        for i in 0..<truth.count where truth[i] > 0.2 && truth[i] < 0.8 {
            error += Double(abs(values[i] - truth[i])); n += 1
            if values[i] > 0.1, values[i] < 0.9 { fractional += 1 }
        }
        return (error / Double(max(n, 1)), Double(fractional) / Double(max(n, 1)))
    }

    @Test func theSubjectKeepsItsCoverage() throws {
        let s = try Self.scene(960, 540, soft: 8)
        let out = try #require(SubjectMatteRefiner.refine(s.coarse, guide: s.frame))
        #expect(out.width == 960 && out.height == 540)
        let truth = Self.sum(s.truth), before = Self.sum(s.coarse.values), after = Self.sum(out.values)
        // As much of the picture as the subject takes (3 %), and no further from it than the model's mask was.
        #expect(abs(after / truth - 1) < 0.03, "coverage \(after / truth), the model's mask \(before / truth)")
        #expect(abs(after / truth - 1) <= abs(before / truth - 1) + 0.01)
        // Inside and outside stay as they were: full and empty.
        #expect(out.values[270 * 960 + 480] > 0.99)
        #expect(out.values[20 * 960 + 20] < 0.01)
        #expect(out.values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func aSoftEdgeGetsFractionalAlphaCloserToTheTruthThanTheModelsMask() throws {
        let s = try Self.scene(960, 540, soft: 12)
        let out = try #require(SubjectMatteRefiner.refine(s.coarse, guide: s.frame))
        let before = Self.edge(s.coarse.values, s.truth), after = Self.edge(out.values, s.truth)
        let quick = Self.edge(SubjectMatteEdges.refine(s.coarse, guide: s.frame).values, s.truth)
        print("PERF subject matte soft edge 960x540: error model \(before.error), quick step \(quick.error), quality \(after.error); fractional model \(before.fractional), quick step \(quick.fractional), quality \(after.fractional)")
        #expect(after.error < before.error * 0.6)
        #expect(after.error < quick.error)
        #expect(after.error < 0.15)
        #expect(after.fractional > 0.9)
    }

    /// The disc with thin strands (2 px, in the subject's color) reaching 24 px out of its edge: what hair is to the
    /// tracking model's 256 x 256 mask.
    static func strands(_ w: Int, _ h: Int) throws -> Scene {
        let disc = try scene(w, h, soft: 2)
        var truth = disc.truth
        let cx = Double(w) * 0.5, cy = Double(h) * 0.5, radius = Double(h) * 0.3
        for k in 0..<24 {
            let angle = Double(k) / 24 * 2 * .pi, dx = cos(angle), dy = sin(angle)
            for step in 0..<48 {
                let r = radius + Double(step) * 0.5
                let x = Int((cx + dx * r).rounded()), y = Int((cy + dy * r).rounded())
                for oy in 0..<2 { for ox in 0..<2 where x + ox < w && y + oy < h { truth[(y + oy) * w + x + ox] = 1 } }
            }
        }
        CVPixelBufferLockBaseAddress(disc.frame, [])
        let base = try #require(CVPixelBufferGetBaseAddress(disc.frame)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(disc.frame)
        let subject: [UInt8] = [120, 170, 220]
        for y in 0..<h { for x in 0..<w where truth[y * w + x] == 1 { for c in 0..<3 { base[y * row + x * 4 + c] = subject[c] } } }
        CVPixelBufferUnlockBaseAddress(disc.frame, [])
        return Scene(frame: disc.frame, truth: truth, coarse: disc.coarse)
    }

    /// Mean alpha the matte gives the strand pixels outside the disc's own edge band, and the mean alpha it gives the
    /// background pixels in the same ring.
    static func strandAlpha(_ values: [Float], _ s: Scene, _ w: Int, _ h: Int) -> (strands: Double, background: Double) {
        let cx = Double(w) * 0.5, cy = Double(h) * 0.5, radius = Double(h) * 0.3
        var on = 0.0, nOn = 0, off = 0.0, nOff = 0
        for y in 0..<h {
            for x in 0..<w {
                let d = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot() - radius
                guard d > 4, d < 20 else { continue }
                if s.truth[y * w + x] == 1 { on += Double(values[y * w + x]); nOn += 1 } else { off += Double(values[y * w + x]); nOff += 1 }
            }
        }
        return (on / Double(max(nOn, 1)), off / Double(max(nOff, 1)))
    }

    @Test func theColorStepTakesInThinStrandsTheCoefficientSizeMisses() throws {
        let w = 1920, h = 1080
        let s = try Self.strands(w, h)
        let picture = SubjectMatteRefiner.Picture()
        #expect(picture.load(s.frame, longEdge: 1920))
        let plain = try SubjectMatteRefiner.refine(s.coarse, picture: picture, settings: .init(colorRadius: 0))
        let detailed = try SubjectMatteRefiner.refine(s.coarse, picture: picture, settings: .strands)
        let before = Self.strandAlpha(plain.values, s, w, h), after = Self.strandAlpha(detailed.values, s, w, h)
        print("PERF subject matte strands 1920x1080: strand alpha plain \(before.strands) color \(after.strands); background plain \(before.background) color \(after.background)")
        #expect(after.strands > before.strands + 0.1)
        #expect(after.background <= before.background + 0.02)
        // Inside and outside stay as they were.
        #expect(detailed.values[540 * w + 960] > 0.99)
        #expect(detailed.values[20 * w + 20] < 0.01)
        #expect(detailed.values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func aFrameThatCannotGuideIsNoAnswerAndTheLegKeepsTheQuickStep() async throws {
        let small = try Self.scene(32, 32, soft: 2)
        #expect(SubjectMatteRefiner.refine(small.coarse, guide: small.frame) == nil)
        let planar = try Self.scene(320, 180, soft: 4, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(SubjectMatteRefiner.refine(planar.coarse, guide: planar.frame) == nil)

        let engine = SubjectMaskEngineTests.engine(FakeSubjectLoader { FakeSubjectModel() })
        try await SubjectMaskEngineTests.ready(engine)
        let lease = try #require(engine.lease())
        let leg = try #require(SubjectTrackLeg(lease: lease, segmenter: MagicMaskTests.PatchSegmenter()))
        leg.quality = .quality
        // No guide: the matte comes back as the quick step leaves it (unchanged for a frame it cannot read either), solid inside.
        #expect(leg.edged(planar.coarse, planar.frame) == SubjectMatteCore.solid(planar.coarse))
        let s = try Self.scene(320, 180, soft: 4)
        let fine = leg.edged(s.coarse, s.frame), quick = SubjectMatteCore.solid(SubjectMatteEdges.refine(s.coarse, guide: s.frame), mask: s.coarse)
        #expect(fine == SubjectMatteRefiner.refine(s.coarse, guide: s.frame).map { SubjectMatteCore.solid($0, mask: s.coarse) })
        #expect(fine != quick)
        // Speed never takes the Quality step.
        leg.quality = .speed
        #expect(leg.edged(s.coarse, s.frame) == quick)
        // The leg's reused planes give what fresh ones give, frame after frame and across sizes.
        leg.quality = .quality
        let other = try Self.scene(480, 270, soft: 6)
        #expect(leg.edged(other.coarse, other.frame) == SubjectMatteRefiner.refine(other.coarse, guide: other.frame).map { SubjectMatteCore.solid($0, mask: other.coarse) })
        #expect(leg.edged(s.coarse, s.frame) == fine)
    }

    @Test func anImageOperationThatFailsIsNoMatte() throws {
        var out = [Float](repeating: 0, count: 4)
        #expect(throws: SubjectMatteRefiner.Failed.self) { try SubjectMatteRefiner.scale([1, 2], 2, 2, into: &out, 2, 1) }
        #expect(throws: SubjectMatteRefiner.Failed.self) { try SubjectMatteRefiner.scale([1, 2, 3, 4], 2, 2, into: &out, 4, 4) }
        #expect(throws: SubjectMatteRefiner.Failed.self) { _ = try SubjectMatteRefiner.box([1, 2], 2, 2, 1) }
        // `refine(_:guide:)` turns such a throw into nil, which `SubjectTrackLeg.edged` answers with the quick step.
    }

    static func tracker(_ url: URL, _ engine: SubjectMaskEngine, dimension: Int? = nil) -> MagicMaskTracker {
        var limits = WorkLimits.current
        if let dimension { limits.subjectMaskDimension = dimension }
        limits.maskTrackChunkSeconds = 1
        return MagicMaskTracker(url: url, limits: limits, segmenter: MagicMaskTests.PatchSegmenter(), engine: engine)
    }

    static func readyEngine() async throws -> SubjectMaskEngine {
        let engine = SubjectMaskEngineTests.engine(FakeSubjectLoader { FakeSubjectModel() })
        try await SubjectMaskEngineTests.ready(engine)
        return engine
    }

    /// The mattes stored for the test movie's 24 frames.
    static func mattes(_ store: MagicMatteStore) -> [SubjectMatte] {
        (0..<24).compactMap { store.matte(key: "k", pts: Double($0) / 24) }
    }

    @Test func theEdgeIsSettledOnceForAPickAndAMemoryWarningInsideTheRunDoesNotChangeIt() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        // Memory short before the pick: Speed for all of it, also when memory is fine again while it runs.
        let short = try await Self.readyEngine()
        short.memoryPressure(.warning)
        #expect(!short.hasRoomForQuality)
        var speed = Self.tracker(url, short, dimension: 160)
        speed.decide(.quality)
        #expect(speed.quality == .speed)
        short.memoryPressure(.normal)
        #expect(short.hasRoomForQuality)
        #expect(speed.quality == .speed)

        // Memory runs short inside the run: every frame keeps the Quality size and edge.
        let engine = try await Self.readyEngine()
        var made = Self.tracker(url, engine, dimension: 160)
        made.decide(.quality)
        let tracker = made
        let store = MagicMatteStore(directory: nil)
        let warn: @Sendable (Double) -> Void = { p in if p > 0.3 { engine.memoryPressure(.warning) } }
        let result = try await tracker.track(key: "k", points: SubjectMaskEngineTests.click, from: 0, to: SubjectMaskEngineTests.end, store: store, progress: warn)
        #expect(!engine.hasRoomForQuality)
        let all = Self.mattes(store)
        #expect(result.frames > 12)
        #expect(all.count == result.frames)
        #expect(all.allSatisfy { $0.width == 320 && $0.height == 180 })
        // The reference: the same run with memory fine throughout.
        let calm = try await Self.readyEngine()
        var plain = Self.tracker(url, calm, dimension: 160)
        plain.decide(.quality)
        let calmStore = MagicMatteStore(directory: nil)
        _ = try await plain.track(key: "k", points: SubjectMaskEngineTests.click, from: 0, to: SubjectMaskEngineTests.end, store: calmStore)
        #expect(Self.mattes(calmStore) == all)
    }

    @Test func aBackwardQualityRunReadsShorterChunksAndLosesNoFrame() async throws {
        // Twice the edge is four times the bytes per frame: a quarter of the seconds.
        #expect(MagicMaskTracker.backwardChunkSeconds(1, analysis: 960, frame: 1920) == 0.25)
        #expect(MagicMaskTracker.backwardChunkSeconds(1, analysis: 960, frame: 960) == 1)
        #expect(abs(MagicMaskTracker.backwardChunkSeconds(1, analysis: 960, frame: 1440) - 4.0 / 9) < 1e-9)
        // Never under a quarter second (every chunk is a read of its own, from the key frame before it), never over
        // what the limits give.
        #expect(MagicMaskTracker.backwardChunkSeconds(0.5, analysis: 540, frame: 1080) == 0.25)
        #expect(MagicMaskTracker.backwardChunkSeconds(0.2, analysis: 540, frame: 1080) == 0.2)
        // Bytes held at 60 fps, Quality chunk against tracking-size chunk: the same on the standard profile (960 px,
        // a second), twice as many on the small one (540 px, half a second), where the quarter second is the floor.
        for (seconds, analysis, most) in [(1.0, 960, 1.0), (0.5, 540, 2.0)] {
            let frame = SubjectMaskQuality.quality.frameDimension(analysis: analysis)
            let chunk = MagicMaskTracker.backwardChunkSeconds(seconds, analysis: analysis, frame: frame)
            let fine = Double(frame * frame) * 9 / 16 * 4 * 60 * chunk
            #expect(fine <= Double(analysis * analysis) * 9 / 16 * 4 * 60 * seconds * most + 1)
        }

        // The shorter chunks (four for this one second movie) lose no frame and give the forward run's count.
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        var counts: [Int] = []
        for (from, to) in [(0.0, SubjectMaskEngineTests.end), (SubjectMaskEngineTests.end, 0.0)] {
            let engine = try await Self.readyEngine()
            var tracker = Self.tracker(url, engine, dimension: 160)
            tracker.decide(.quality)
            let store = MagicMatteStore(directory: nil)
            // The patch moves 96 px over the second: the click sits on it at the frame the run starts from.
            let points = [MagicPoint(position: Vec2((80 + 96 * from) / 320, 0.5), subtract: false, sourceTime: Time(Int64((from * 24).rounded()), 24))]
            let result = try await tracker.track(key: "k", points: points, from: from, to: to, store: store)
            let all = Self.mattes(store)
            #expect(all.count == result.frames)
            #expect(all.allSatisfy { $0.width == 320 })
            counts.append(result.frames)
        }
        #expect(counts[0] == counts[1])
        #expect(counts[0] > 12)
    }

    @Test func aQualityTrackMakesItsMattesAtTheLargerFrameSizeWithTheQualityEdge() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        // The tracking size is half the 320 x 180 movie: Quality reads its frames at twice that, not at 160. (The
        // test segmenter's patch is laid out for 320 x 180, so there is no Speed run at 160 to compare with.)
        do {
            let engine = try await Self.readyEngine()
            var tracker = Self.tracker(url, engine, dimension: 160)
            tracker.decide(.quality)
            #expect(tracker.quality == .quality)
            let store = MagicMatteStore(directory: nil)
            let result = try await tracker.track(key: "k", points: SubjectMaskEngineTests.click, from: 0, to: SubjectMaskEngineTests.end, store: store)
            #expect(result.frames > 12)
            #expect(Array(Set(Self.mattes(store).map(\.width))) == [SubjectMaskQuality.quality.frameDimension(analysis: 160)])
            #expect(engine.failures == 0)
        }

        // The movie no larger than the tracking size: both read the same frames, the edge is what differs.
        var same: [SubjectMaskQuality: SubjectMatte] = [:]
        for quality in SubjectMaskQuality.allCases {
            let engine = try await Self.readyEngine()
            var tracker = Self.tracker(url, engine, dimension: 960)
            tracker.decide(quality)
            let store = MagicMatteStore(directory: nil)
            _ = try await tracker.track(key: "k", points: SubjectMaskEngineTests.click, from: 0, to: SubjectMaskEngineTests.end, store: store)
            same[quality] = try #require(store.matte(key: "k", pts: 12.0 / 24))
        }
        let q = try #require(same[.quality]), sp = try #require(same[.speed])
        #expect(q.width == 320 && sp.width == 320)
        #expect(q.values != sp.values)
    }

    /// A file whose frames lie further apart than a backward chunk is long (a low frame rate, a screen recording
    /// with a variable rate, dropped frames): the chunk with no frame in it does not end the run.
    @Test(arguments: [0.3, 1.2]) func aBackwardRunGoesOnAcrossAGapLongerThanItsChunk(gap: Double) async throws {
        let url = try await MaskTrackerTests().writeMovie(hold: (frame: 11, seconds: gap))
        defer { try? FileManager.default.removeItem(at: url) }
        let last = 23.0 / 24 + gap
        // Quality at half the movie's size (chunk 0.25 s), Speed at the movie's size (chunk 1 s).
        for (quality, dimension) in [(SubjectMaskQuality.quality, 160), (.speed, 960)] {
            var times: [[Double]] = []
            for (from, to) in [(0.0, last), (last, 0.0)] {
                let engine = try await Self.readyEngine()
                var tracker = Self.tracker(url, engine, dimension: dimension)
                tracker.decide(quality)
                let store = MagicMatteStore(directory: nil)
                let frame = from > to ? 23.0 : 0
                let points = [MagicPoint(position: Vec2((80 + 4 * frame) / 320, 0.5), subtract: false, sourceTime: Time(Int64((from * 600).rounded()), 600))]
                let result = try await tracker.track(key: "k", points: points, from: from, to: to, store: store)
                #expect(result.frames == 24, "\(quality) \(from > to ? "backward" : "forward") over a \(gap) s gap")
                #expect(result.lostTimes.isEmpty)
                times.append(store.times(key: "k").map { ($0 * 600).rounded() / 600 })
            }
            #expect(times[0].count == 24)
            #expect(times[0] == times[1])
        }
    }

    /// One key may hold mattes of more than one size: the pick's matte and a Speed run are at the tracking size, a
    /// Quality run at up to twice that, and the setting can change between two runs on one mask.
    @Test func oneKeyHoldsMattesOfTwoSizesAndEveryReaderTakesThem() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-matte-sizes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The start frame's matte at half size (the patch of frame 0: x 60 ..< 100, y 70 ..< 110 of 320 x 180).
        var half = [Float](repeating: 0, count: 160 * 90)
        for y in 35..<55 { for x in 30..<50 { half[y * 160 + x] = 1 } }
        let small = SubjectMatte(width: 160, height: 90, values: half)
        let store = MagicMatteStore(directory: dir)
        store.put(small, key: "k", pts: 0)
        // A Quality run goes on from it (the model is conditioned on the stored matte, whatever its size).
        let engine = try await Self.readyEngine()
        var tracker = Self.tracker(url, engine, dimension: 160)
        tracker.decide(.quality)
        let result = try await tracker.track(key: "k", points: SubjectMaskEngineTests.click, from: 0, to: SubjectMaskEngineTests.end, store: store)
        #expect(result.frames == 24)
        #expect(result.lostTimes.isEmpty)
        #expect(engine.failures == 0)
        let later = try #require(store.matte(key: "k", pts: 12.0 / 24))
        #expect(later.width == 320 && later.height == 180)
        // A frame put back at the other size afterwards (a correction made at the tracking size).
        store.put(small, key: "k", pts: 0)
        // The file keeps each matte at its own size.
        store.save(key: "k")
        let fresh = MagicMatteStore(directory: dir)
        #expect(fresh.times(key: "k").count == 24)
        let first = try #require(fresh.matte(key: "k", pts: 0)), next = try #require(fresh.matte(key: "k", pts: 1.0 / 24))
        #expect(first.width == 160 && first.height == 90)
        #expect(next.width == 320 && next.height == 180)
        // What the picture gets when frames are mixed (frame blending, a retimed clip): one matte, at the larger size,
        // covering what both cover.
        let both = MagicMatteStore.union([first, next], spanning: false)
        #expect(both.width == 320 && both.height == 180)
        #expect(both[70, 90] > 0.9)       // inside the patch on both frames
        #expect(both[10, 10] < 0.1)
        // And a Speed run goes on from a Quality matte the same way.
        let again = try await Self.readyEngine()
        var speed = Self.tracker(url, again, dimension: 960)
        speed.decide(.speed)
        let mid = [MagicPoint(position: Vec2((80 + 4 * 12.0) / 320, 0.5), subtract: false, sourceTime: Time(12, 24))]
        let on = try await speed.track(key: "k", points: mid, from: 12.0 / 24, to: SubjectMaskEngineTests.end, store: fresh)
        #expect(on.frames == 12)
        #expect(on.lostTimes.isEmpty)
    }

    /// Cost per frame at 1080p and 4K (a 4K frame is worked at long edge 1920), and what a Quality matte costs in
    /// the store.
    @Test func costPerFrame() throws {
        func ms(_ d: Duration) -> String { String(format: "%.1f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        let clock = ContinuousClock()
        // The filter is plain Swift loops: an unoptimized test build runs it about ten times slower than the app.
        #if DEBUG
        let build = "debug build"
        #else
        let build = "release build"
        #endif
        var matte1080: SubjectMatte?
        for (w, h) in [(1920, 1080), (3840, 2160)] {
            let s = try Self.scene(w, h, soft: Double(w) / 160)
            var times: [Duration] = []
            var out: SubjectMatte?
            // As a leg does it: one picture's planes for every frame.
            let scratch = SubjectMatteRefiner.Picture()
            for _ in 0..<5 { times.append(clock.measure { out = SubjectMatteRefiner.refine(s.coarse, guide: s.frame, scratch: scratch) }) }
            let made = try #require(out)
            #expect(max(made.width, made.height) == 1920)
            times.sort()
            print("PERF subject matte quality step \(w)x\(h) -> \(made.width)x\(made.height): median \(ms(times[2])) ms per frame (picture and filter, \(build))")
            if w == 1920 { matte1080 = made }
        }
        let matte = try #require(matte1080)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-matte-quality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MagicMatteStore(directory: dir)
        var puts: [Duration] = []
        for i in 0..<8 { puts.append(clock.measure { store.put(matte, key: "q", pts: Double(i) / 24) }) }
        store.save(key: "q")
        let file = dir.appendingPathComponent("q.sqmatte")
        let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let fresh = MagicMatteStore(directory: dir)
        var back: SubjectMatte?
        let first = clock.measure { back = fresh.matte(key: "q", pts: 0) }
        var reads: [Duration] = []
        for i in 1..<8 { reads.append(clock.measure { _ = fresh.matte(key: "q", pts: Double(i) / 24) }) }
        puts.sort(); reads.sort()
        let read = try #require(back)
        #expect(read.width == 1920 && read.height == 1080)
        // 8 bit keeps the soft alpha: no value further than half a step from what was stored.
        var worst: Float = 0
        for i in stride(from: 0, to: matte.values.count, by: 7) { worst = max(worst, abs(read.values[i] - matte.values[i])) }
        #expect(worst <= 0.5 / 255 + 1e-4)
        print("PERF subject matte store 1920x1080: \(bytes / 8) bytes per frame on disk (raw 8 bit: \(1920 * 1080)), put median \(ms(puts[4])) ms, first read with the file \(ms(first)) ms, decode median \(ms(reads[3])) ms")
    }

    /// The full-size step only works inside the bounding box of the uncertain band: same matte as the whole-frame
    /// step (outside the box it is the model's mask in both), and cheaper at 1080p.
    @Test func restrictingTheFullSizeStepToTheBandBoxKeepsTheMatteAndCostsLess() throws {
        let s = try Self.scene(1920, 1080, soft: 12)
        let whole = SubjectMatteRefiner.Settings(restrictToBand: false), boxed = SubjectMatteRefiner.Settings()
        let picture = SubjectMatteRefiner.Picture()
        #expect(picture.load(s.frame, longEdge: 1920))
        let a = try SubjectMatteRefiner.refine(s.coarse, picture: picture, settings: whole)
        let b = try SubjectMatteRefiner.refine(s.coarse, picture: picture, settings: boxed)
        #expect(a.width == b.width && a.height == b.height)
        var worst: Float = 0, sumDiff = 0.0
        for i in 0..<a.values.count { let d = abs(a.values[i] - b.values[i]); worst = max(worst, d); sumDiff += Double(d) }
        #expect(worst < 0.1)
        #expect(sumDiff / Double(a.values.count) < 1e-3)
        let e = Self.edge(b.values, s.truth), ea = Self.edge(a.values, s.truth)
        #expect(e.error <= ea.error + 0.01)
        let clock = ContinuousClock()
        func median(_ settings: SubjectMatteRefiner.Settings) throws -> Double {
            var t: [Double] = []
            for _ in 0..<5 {
                let d = try clock.measure { _ = try SubjectMatteRefiner.refine(s.coarse, picture: picture, settings: settings) }
                t.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
            }
            return t.sorted()[2]
        }
        let wholeMs = try median(whole), boxedMs = try median(boxed)
        print("PERF subject matte refine 1920x1080 disc: whole frame \(String(format: "%.1f", wholeMs)) ms, band box \(String(format: "%.1f", boxedMs)) ms, worst diff \(worst)")
        #expect(boxedMs < wholeMs)
    }
}
