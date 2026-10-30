import CoreVideo
import Foundation
import SQCore
import SQMedia
import Synchronization
import Testing
@testable import SQAnalysis

/// A tracking model that sees the test movie's checker patch (as `MagicMaskTests.PatchSegmenter` does) and can fail,
/// go blind or call out on chosen `track` calls (counted over all its sessions).
final class FakeSubjectModel: SubjectTrackModel, @unchecked Sendable {
    struct Counts { var sessions = 0, clicks = 0, boxes = 0, conditions = 0, tracks = 0, commits = 0, corrections = 0, adopts = 0
        /// `lookAhead` calls, and `track` calls on the frame looked ahead last.
        var aheads = 0, tracksAhead = 0 }
    let counts = Mutex(Counts())
    /// `corrections` answers with the last tracked mask plus a square around the clicks (a refinement); false: no candidates.
    var offersCorrections = false
    let failAt: Int?
    let blind: Set<Int>
    /// `track` calls that find the subject with a weak score (0.5, as a look-alike gets).
    var weak: Set<Int> = []
    let onTrack: (@Sendable (Int) -> Void)?
    /// The `track` call that never returns (until `unblock`), and the deadline its predictions run under (as the real
    /// model's do); nil: on the caller's thread, without a deadline.
    let hangAt: Int?
    let runner: SubjectDeadlineRunner?
    private let gate = DispatchSemaphore(value: 0)

    init(failAt: Int? = nil, blind: Set<Int> = [], hangAt: Int? = nil, runner: SubjectDeadlineRunner? = nil,
         onTrack: (@Sendable (Int) -> Void)? = nil) {
        self.failAt = failAt; self.blind = blind; self.hangAt = hangAt; self.runner = runner; self.onTrack = onTrack
    }

    /// Lets a hung `track` call end (so its thread does not outlive the test).
    func unblock() { gate.signal() }
    fileprivate func hang() { gate.wait() }

    var seen: Counts { counts.withLock { $0 } }

    func makeSession() -> any SubjectTrackSession {
        counts.withLock { $0.sessions += 1 }
        return Session(self)
    }

    static func logits(_ pb: CVPixelBuffer) throws -> [Float] {
        let size = SubjectTrackRules.logitSize
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw SubjectTrackError.badFrame("no pixels") }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var out = [Float](repeating: -8, count: size * size)
        for y in 0..<size {
            let row = base.advanced(by: min(y * h / size, h - 1) * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<size {
                let g = Int(row[min(x * w / size, w - 1) * 4 + 1])
                if g < 40 || g > 215 { out[y * size + x] = 8 }
            }
        }
        return out
    }

    final class Session: SubjectTrackSession {
        let model: FakeSubjectModel
        var conditioned = false
        init(_ model: FakeSubjectModel) { self.model = model }

        func click(_ frame: CVPixelBuffer, point: Vec2, box: SubjectTrackBox?) throws -> SubjectTrackOutput {
            model.counts.withLock { $0.clicks += 1; if box != nil { $0.boxes += 1 } }
            conditioned = true
            return SubjectTrackOutput(logits: try FakeSubjectModel.logits(frame), score: 5)
        }

        func condition(_ frame: CVPixelBuffer, matte: SubjectMatte) throws {
            model.counts.withLock { $0.conditions += 1 }
            conditioned = true
        }

        /// The frames looked ahead last (the lane looks at the next frame before it asks the current one).
        private var ahead: [CVPixelBuffer] = []
        func lookAhead(_ frame: CVPixelBuffer) {
            model.counts.withLock { $0.aheads += 1 }
            ahead = Array((ahead + [frame]).suffix(2))
        }

        func track(_ frame: CVPixelBuffer) throws -> SubjectTrackOutput {
            guard conditioned else { throw SubjectTrackError.notConditioned }
            if ahead.contains(where: { $0 === frame }) { model.counts.withLock { $0.tracksAhead += 1 } }
            guard let runner = model.runner else { return try predict(frame) }
            return try runner.run { try self.predict(frame) }
        }

        private func predict(_ frame: CVPixelBuffer) throws -> SubjectTrackOutput {
            let n = model.counts.withLock { $0.tracks += 1; return $0.tracks }
            model.onTrack?(n)
            if n == model.hangAt { model.hang() }
            if n == model.failAt { throw SubjectTrackError.prediction("fake failure") }
            if model.blind.contains(n) {
                return SubjectTrackOutput(logits: [Float](repeating: -8, count: SubjectTrackRules.logitSize * SubjectTrackRules.logitSize), score: -3)
            }
            last = try FakeSubjectModel.logits(frame)
            return SubjectTrackOutput(logits: last, score: model.weak.contains(n) ? 0.5 : 5)
        }

        func commit() throws { model.counts.withLock { $0.commits += 1 } }

        private var last: [Float] = []

        func corrections(_ points: [MagicPoint]) throws -> [[Float]] {
            model.counts.withLock { $0.corrections += 1 }
            guard model.offersCorrections, !last.isEmpty else { return [] }
            let size = SubjectTrackRules.logitSize
            var grown = last
            for p in points where !p.subtract {
                let cx = Int(p.position.x * Double(size)), cy = Int(p.position.y * Double(size))
                for y in max(cy - 4, 0)...min(cy + 4, size - 1) { for x in max(cx - 4, 0)...min(cx + 4, size - 1) { grown[y * size + x] = 8 } }
            }
            return [grown]
        }

        func adoptCorrection(_ index: Int, reseed: Bool) throws { model.counts.withLock { $0.adopts += 1 } }
    }
}

final class FakeSubjectLoader: SubjectMaskLoading, Sendable {
    struct Failure: Error {}
    private struct State { var calls = 0, failures: Int, hangs: Int }
    private let state: Mutex<State>
    let make: @Sendable () -> FakeSubjectModel

    /// Seconds every load takes.
    let delay: Double

    /// `failures`: the first loads that throw. `hangs`: the first loads that never end (until canceled).
    init(failures: Int = 0, hangs: Int = 0, delay: Double = 0, make: @escaping @Sendable () -> FakeSubjectModel) {
        state = Mutex(State(failures: failures, hangs: hangs)); self.delay = delay; self.make = make
    }

    var calls: Int { state.withLock { $0.calls } }

    func load(_ parts: SubjectMaskParts, compute: SubjectTrackCompute) async throws -> any SubjectTrackModel {
        let (hang, fail) = state.withLock { s -> (Bool, Bool) in
            s.calls += 1
            if s.hangs > 0 { s.hangs -= 1; return (true, false) }
            if s.failures > 0 { s.failures -= 1; return (false, true) }
            return (false, false)
        }
        if hang { try await Task.sleep(for: .seconds(600)) }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if fail { throw Failure() }
        return make()
    }
}

/// One after the other: every run here waits for a slot of the frame lane, and thirty of them queued at once keep the
/// tests of hung reads (`MagicTrackStopTests`) waiting past their deadline on a busy Mac.
@Suite(.serialized) struct SubjectMaskEngineTests {
    static let parts = SubjectMaskParts(urls: [:], source: "test")
    static let click = [MagicPoint(position: Vec2(80.0 / 320, 90.0 / 180), subtract: false, sourceTime: .zero)]
    static let end = 23.0 / 24

    static func engine(_ loader: FakeSubjectLoader, found: SubjectMaskLocator.Found = .parts(parts), compute: SubjectTrackCompute? = .gpu,
                       pressure: MemoryPressureRegistry? = nil,
                       personBox: @escaping @Sendable (CVPixelBuffer, Vec2) -> SubjectTrackBox? = { _, _ in nil }) -> SubjectMaskEngine {
        SubjectMaskEngine(locate: { found }, compute: compute, loader: loader, pressure: pressure, personBox: personBox)
    }

    /// Waits until a load that is running ended (either way).
    static func settle(_ engine: SubjectMaskEngine) async throws {
        for _ in 0..<4000 {
            if engine.status != .warming { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the engine is still warming")
    }

    static func ready(_ engine: SubjectMaskEngine) async throws {
        engine.prewarm()
        try await settle(engine)
        #expect(engine.status == .ready)
    }

    static func tracker(_ url: URL, _ engine: SubjectMaskEngine, segmenter: any InstanceSegmenting = MagicMaskTests.PatchSegmenter()) -> MagicMaskTracker {
        MagicMaskTracker(url: url, limits: .current, segmenter: segmenter, engine: engine)
    }

    /// The patch center moves 4 px of 320 per frame from x = 80.
    static func expectPatch(_ store: MagicMatteStore, _ key: String, frames: [Int]) throws {
        for i in frames {
            let m = try #require(store.matte(key: key, pts: Double(i) / 24))
            let c = try #require(m.centroid)
            let x = c.x / Double(m.width) * 320
            #expect(abs(x - Double(80 + 4 * i)) < 6, "frame \(i) at \(x)")
        }
    }

    // MARK: Locator

    static func folder(_ parts: [String], compiled: Bool = false, package: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sq-subjectmask-\(UUID().uuidString)", isDirectory: true)
        for name in parts {
            let file = (compiled ? "compiled/" : "") + name + (package ? ".mlpackage" : ".mlmodelc")
            try FileManager.default.createDirectory(at: root.appendingPathComponent(file, isDirectory: true), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func theLocatorNamesWhatIsMissing() throws {
        let none = SubjectMaskLocator.locate(environment: [:], bundle: nil, support: nil)
        #expect(none == .missing("no tracking model (nowhere to look)"))
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("sq-nothing-\(UUID().uuidString)")
        guard case .missing(let why) = SubjectMaskLocator.locate(environment: [:], bundle: gone, support: gone) else {
            Issue.record("found models in a folder that does not exist"); return
        }
        #expect(why.contains("app bundle: no folder") && why.contains("Application Support: no folder"))
        // One part short: the folder does not count, and the log says which part.
        let short = try Self.folder(Array(SubjectMaskParts.names.dropLast()))
        defer { try? FileManager.default.removeItem(at: short) }
        guard case .missing(let gap) = SubjectMaskLocator.locate(environment: [:], bundle: nil, support: short) else {
            Issue.record("four parts counted as a model"); return
        }
        #expect(gap.contains("missing \(SubjectMaskParts.memoryAttention)"))
    }

    @Test func theLocatorLooksAtTheEnvironmentThenTheBundleThenApplicationSupport() throws {
        let env = try Self.folder(SubjectMaskParts.names, compiled: true)
        let app = try Self.folder(SubjectMaskParts.names)
        let support = try Self.folder(SubjectMaskParts.names, package: true)
        defer { for f in [env, app, support] { try? FileManager.default.removeItem(at: f) } }
        // The bundle's models lie in `Resources/SubjectMask`.
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("sq-resources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        try FileManager.default.moveItem(at: app, to: resources.appendingPathComponent(SubjectMaskLocator.folderName))
        func source(_ environment: [String: String], _ bundle: URL?, _ support: URL?) -> SubjectMaskParts? {
            if case .parts(let p) = SubjectMaskLocator.locate(environment: environment, bundle: bundle, support: support) { return p }
            return nil
        }
        let all = try #require(source([SubjectMaskLocator.environmentKey: env.path], resources, support))
        #expect(all.source == SubjectMaskLocator.environmentKey && all.urls.count == 5)
        #expect(all.urls[SubjectMaskParts.encoder]?.path.hasSuffix("compiled/\(SubjectMaskParts.encoder).mlmodelc") == true)
        #expect(source([:], resources, support)?.source == "app bundle")
        let last = try #require(source([:], nil, support))
        #expect(last.source == "Application Support" && last.urls[SubjectMaskParts.decoder]?.pathExtension == "mlpackage")
        // An environment folder without the parts does not hide the bundle's.
        #expect(source([SubjectMaskLocator.environmentKey: "/nowhere"], resources, nil)?.source == "app bundle")
    }

    @Test func aDevelopmentAppFindsTheModelsOfItsSourceCheckout() throws {
        // The Debug app lies in `<checkout>/build/DerivedData/Build/Products/Debug/Sequence Studio.app`, a worktree's
        // in `<checkout>/.claude/worktrees/<name>/build/...` (the models are not in git, only in the main checkout).
        let checkout = FileManager.default.temporaryDirectory.appendingPathComponent("sq-checkout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: checkout) }
        let models = checkout.appendingPathComponent(SubjectMaskLocator.checkoutModels, isDirectory: true)
        for name in SubjectMaskParts.names {
            try FileManager.default.createDirectory(at: models.appendingPathComponent("\(name).mlmodelc"), withIntermediateDirectories: true)
        }
        let app = checkout.appendingPathComponent(".claude/worktrees/w/build/DerivedData/Build/Products/Debug/Sequence Studio.app")
        #expect(SubjectMaskLocator.checkoutFolder(from: app)?.standardizedFileURL == models.standardizedFileURL)
        // Only an app looks there (a test bundle in a checkout keeps "no model"), and never past the search depth.
        #expect(SubjectMaskLocator.checkoutFolder(from: checkout.appendingPathComponent("build/x/SQAnalysisPackageTests.xctest")) == nil)
        #expect(SubjectMaskLocator.checkoutFolder(from: nil) == nil)
        let deep = checkout.appendingPathComponent("a/b/c/d/e/f/g/h/i/j/k/l/Sequence Studio.app")
        #expect(SubjectMaskLocator.checkoutFolder(from: deep) == nil)
        // It is the last place looked at.
        guard case .parts(let found) = SubjectMaskLocator.locate(environment: [:], bundle: nil, support: nil, checkout: models) else {
            Issue.record("the checkout's models were not found"); return
        }
        #expect(found.source == "source checkout")
        let support = try Self.folder(SubjectMaskParts.names)
        defer { try? FileManager.default.removeItem(at: support) }
        guard case .parts(let first) = SubjectMaskLocator.locate(environment: [:], bundle: nil, support: support, checkout: models) else {
            Issue.record("nothing found"); return
        }
        #expect(first.source == "Application Support")
    }

    // MARK: Engine

    @Test func withoutModelsTheMaskTracksWithTheSystemsSegmentation() async throws {
        let loader = FakeSubjectLoader { FakeSubjectModel() }
        let engine = Self.engine(loader, found: .missing("no tracking model (test)"))
        engine.prewarm()
        try await Self.settle(engine)
        #expect(engine.status == .unavailable("no tracking model (test)"))
        #expect(engine.lease() == nil && loader.calls == 0)
        // Asked again: still nothing loaded, no new attempt.
        engine.prewarm()
        #expect(engine.status == .unavailable("no tracking model (test)"))
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        // No model to wait for: the run says nothing about preparing, it just tracks.
        let told = Mutex<[Bool]>([])
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store,
                                                          preparing: { w in told.withLock { $0.append(w) } })
        #expect(r.frames == 24 && !r.lost && told.withLock { $0 }.isEmpty)
        try Self.expectPatch(store, "p", frames: [0, 12, 23])
    }

    @Test func aMacOutsideTheModelsRangeNeverLoads() async throws {
        let loader = FakeSubjectLoader { FakeSubjectModel() }
        let engine = Self.engine(loader, compute: nil)
        engine.prewarm()
        try await Self.settle(engine)
        guard case .unavailable = engine.status else { Issue.record("status \(engine.status)"); return }
        #expect(loader.calls == 0 && engine.lease() == nil)
    }

    @Test func aLoadThatThrowsLeavesTheToolWorkingAndIsTriedAgainThenGivenUp() async throws {
        let loader = FakeSubjectLoader(failures: 2) { FakeSubjectModel() }
        let engine = Self.engine(loader)
        engine.prewarm()
        try await Self.settle(engine)
        #expect(engine.status == .idle && engine.failures == 1 && engine.lease() == nil)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        // The run starts the second load itself (it fails too) and tracks with the system's segmentation.
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 24 && !r.lost)
        try await Self.settle(engine)
        #expect(engine.status == .unavailable("the tracking model failed to load") && loader.calls == 2)
        engine.prewarm()
        try await Self.settle(engine)
        #expect(loader.calls == 2)
        let again = try await Self.tracker(url, engine).track(key: "q", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(again.frames == 24)
    }

    @Test func aLoadThatFailedOnceServesTheNextRun() async throws {
        let model = FakeSubjectModel()
        let loader = FakeSubjectLoader(failures: 1) { model }
        let engine = Self.engine(loader)
        engine.prewarm()
        try await Self.settle(engine)
        #expect(engine.status == .idle)
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 24 && model.seen.tracks == 23)
    }

    // MARK: Runs on the model

    @Test func aReadyModelCarriesTheTrackForwardAndBackward() async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let tracker = Self.tracker(url, engine)
        let r = try await tracker.track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 24 && !r.lost && r.lastTime.map { abs($0 - Self.end) < 1e-3 } == true)
        // One click answered by the model (the system's pick gave the box), 23 frames tracked and remembered.
        var seen = model.seen
        #expect(seen.clicks == 1 && seen.boxes == 1 && seen.conditions == 0 && seen.tracks == 23 && seen.commits == 23)
        #expect(store.times(key: "p").count == 24)
        try Self.expectPatch(store, "p", frames: [0, 12, 23])
        // Backward from the pick on frame 12, one tracker for both legs as the app runs them.
        let mid = [MagicPoint(position: Vec2(128.0 / 320, 90.0 / 180), subtract: false, sourceTime: Time(12, 24))]
        let both = Self.tracker(url, engine)
        let forward = try await both.track(key: "q", points: mid, from: 0.5, to: Self.end, store: store)
        let back = try await both.track(key: "q", points: mid, from: 0.5, to: 0, store: store)
        #expect(forward.frames == 12 && back.frames == 13 && !back.lost)
        #expect(store.times(key: "q").count == 24)
        try Self.expectPatch(store, "q", frames: [0, 12, 23])
        seen = model.seen
        #expect(seen.tracks == 23 + 11 + 12 && seen.sessions == 3)
    }

    @Test func aPersonsBoxUnderTheClickIsThePromptOfChoice() async throws {
        let model = FakeSubjectModel()
        let asked = Mutex(0)
        let engine = Self.engine(FakeSubjectLoader { model }, personBox: { _, p in
            asked.withLock { $0 += 1 }
            return SubjectTrackBox(x0: p.x - 0.1, y0: p.y - 0.2, x1: p.x + 0.1, y1: p.y + 0.2)
        })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: 5.0 / 24, store: store)
        #expect(r.frames == 6 && asked.withLock { $0 } == 1)
        // Two model calls, both with a box and none point-only: the split probe (click-sized box, `separatedPerson`,
        // 2a39aab1/85f4afb9, finds no second person here since the fake answers the same patch) and the person box.
        #expect(model.seen.clicks == 2 && model.seen.boxes == 2)
    }

    /// Labels the dark patch and a gray block beside it (x 110-130, y 80-100 of 320x180) as one instance: the block is
    /// what the segmentation joins to the subject and the fake model leaves out.
    struct PatchAndBlockSegmenter: InstanceSegmenting {
        func segment(_ pb: CVPixelBuffer) throws -> InstanceFrame? {
            let frame = try MagicMaskTests.PatchSegmenter().segment(pb)
            var l = try #require(frame?.labels.labels)
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            for y in 80..<100 { for x in 110..<130 { l[y * w + x] = 1 } }
            return InstanceFrame(labels: InstanceLabels(width: w, height: h, labels: l))
        }
    }

    /// 320x180 gray, a black patch at x 50-110, y 60-120.
    static func patchFrame() throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &made)
        let pb = try #require(made)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<180 {
            for x in 0..<320 {
                let v: UInt8 = (50..<110).contains(x) && (60..<120).contains(y) ? 0 : 128
                let p = base + y * row + x * 4
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            }
        }
        return pb
    }

    /// The pick asks the model about the piece of the segmentation beside the answer (a held object) only when it
    /// picked a person: beside a dog or a car that piece is a bag or a chair.
    @Test(arguments: [true, false]) func onlyAPersonPickAsksForWhatItHolds(person: Bool) async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader { model }, personBox: { _, p in
            person ? SubjectTrackBox(x0: p.x - 0.1, y0: p.y - 0.2, x1: p.x + 0.1, y1: p.y + 0.2) : nil
        })
        try await Self.ready(engine)
        let lease = try #require(engine.lease())
        let leg = try #require(SubjectTrackLeg(lease: lease, segmenter: PatchAndBlockSegmenter()))
        let pb = try Self.patchFrame()
        guard case .found(let matte) = try leg.step(pb, pts: 0, gap: 1.0 / 24, points: Self.click, stored: { nil }) else {
            Issue.record("nothing found"); return
        }
        // The held piece's model call moves the memory off the answer, so the pick conditions it on the joined matte.
        #expect(model.seen.conditions == (person ? 1 : 0))
        if !person { #expect(matte.values[90 * matte.width + 120] < 0.5) }
    }

    @Test func aClickJustOffThePersonMaskPicksTheNearestPerson() {
        // 8x4: person 1 at x 0-2, person 2 at x 6-7; the click at x 4 is nearer person 1.
        var mask = [UInt8](repeating: 0, count: 32)
        for y in 0..<4 { for x in 0..<3 { mask[y * 8 + x] = 1 }; for x in 6..<8 { mask[y * 8 + x] = 2 } }
        mask.withUnsafeBufferPointer { b in
            let base = b.baseAddress!
            #expect(SubjectOtherPeople.nearestLabel(base, row: 8, width: 8, height: 4, x: 4, y: 1) == 1)
            #expect(SubjectOtherPeople.nearestLabel(base, row: 8, width: 8, height: 4, x: 5, y: 1) == 2)
            #expect(SubjectOtherPeople.nearestLabel(base, row: 8, width: 8, height: 4, x: 7, y: 0) == 2)
        }
        let empty = [UInt8](repeating: 0, count: 4)
        empty.withUnsafeBufferPointer { #expect(SubjectOtherPeople.nearestLabel($0.baseAddress!, row: 2, width: 2, height: 2, x: 0, y: 0) == 0) }
    }

    // MARK: A run and a model that is still loading

    @Test func aRunWaitsForAModelThatIsLoadingSaysSoAndTracksWithIt() async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader(delay: 0.6) { model })
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        // Nothing loaded when the tracker is made and when the run begins: the run starts the load and waits for it.
        let told = Mutex<[Bool]>([])
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store,
                                                          preparing: { w in told.withLock { $0.append(w) } })
        #expect(r.frames == 24 && !r.lost && model.seen.tracks == 23)
        #expect(told.withLock { $0 } == [true, false])
        // Ready now: the next run waits for nothing and says nothing.
        told.withLock { $0 = [] }
        let next = try await Self.tracker(url, engine).track(key: "q", points: Self.click, from: 0, to: Self.end, store: store,
                                                             preparing: { w in told.withLock { $0.append(w) } })
        #expect(next.frames == 24 && model.seen.tracks == 46 && told.withLock { $0 }.isEmpty)
    }

    @Test func thePickAfterAFailedPredictionWaitsForTheFreshModelAndTracksWithIt() async throws {
        let models = Mutex(0)
        let first = FakeSubjectModel(failAt: 3), second = FakeSubjectModel()
        let loader = FakeSubjectLoader(delay: 0.3) { models.withLock { $0 += 1; return $0 } == 1 ? first : second }
        let engine = Self.engine(loader)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 24 && engine.status == .idle && engine.failures == 1)
        // Nobody loads the model in between: the pick itself does, and is not left on the system's segmentation.
        let again = try await Self.tracker(url, engine).track(key: "q", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(again.frames == 24 && second.seen.tracks == 23 && engine.failures == 0 && loader.calls == 2)
    }

    @Test func aStopWhileTheRunWaitsForTheModelEndsTheWait() async throws {
        let loader = FakeSubjectLoader(hangs: 1) { FakeSubjectModel() }
        let engine = Self.engine(loader)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let told = Mutex<[Bool]>([])
        let tracker = Self.tracker(url, engine)
        let task = Task {
            try await tracker.track(key: "p", points: Self.click, from: 0, to: Self.end, store: store,
                                    preparing: { w in told.withLock { $0.append(w) } })
        }
        for _ in 0..<4000 where told.withLock({ $0 }).isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(told.withLock { $0 } == [true] && engine.status == .warming)
        // The load is the waiting run's: leaving the tool does not cancel it.
        engine.cancelPrewarm()
        #expect(engine.status == .warming)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(store.times(key: "p").isEmpty)
        // Nobody waits any more: now it can be canceled.
        engine.cancelPrewarm()
        #expect(engine.status == .idle)
    }

    @Test func aLoadThatTakesTooLongLeavesTheRunOnTheSystemsSegmentation() async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader(hangs: 1) { model })
        defer { engine.release() }
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        var tracker = Self.tracker(url, engine)
        tracker.loadWait = 0.4
        let told = Mutex<[Bool]>([])
        let r = try await tracker.track(key: "p", points: Self.click, from: 0, to: Self.end, store: store,
                                        preparing: { w in told.withLock { $0.append(w) } })
        #expect(r.frames == 24 && !r.lost && model.seen.sessions == 0)
        #expect(told.withLock { $0 } == [true, false])
        try Self.expectPatch(store, "p", frames: [0, 12, 23])
        // The load goes on for the next run; nothing counts against the model.
        #expect(engine.status == .warming && engine.failures == 0)
    }

    /// A load that never ends: the first run waits its time, the runs after it do not wait for that load again
    /// (before: every pick waited the full 60 s). A new load is waited for again.
    @Test func aLoadARunWaitedForInVainIsNotWaitedForAgain() async throws {
        let loader = FakeSubjectLoader(hangs: 1) { FakeSubjectModel() }
        let engine = Self.engine(loader)
        defer { engine.release() }
        let clock = ContinuousClock()
        let told = Mutex<[Bool]>([])
        var start = clock.now
        let first = try await engine.leaseForRun(wait: 0.4) { w in told.withLock { $0.append(w) } }
        #expect(first == nil && clock.now - start >= .milliseconds(400) && told.withLock { $0 } == [true, false])
        start = clock.now
        let second = try await engine.leaseForRun(wait: 30) { w in told.withLock { $0.append(w) } }
        #expect(second == nil && clock.now - start < .seconds(5) && told.withLock { $0 }.count == 2)
        #expect(engine.status == .warming && loader.calls == 1)
        // The tool is left: nobody waits, the hung load is stopped. The next run starts a new one and waits for it.
        engine.cancelPrewarm()
        #expect(engine.status == .idle)
        let third = try await engine.leaseForRun(wait: 30)
        #expect(third != nil && loader.calls == 2)
        engine.end()
    }

    /// The load a run gave up waiting for finishes later: the next run tracks with the model.
    @Test func aLoadThatWasWaitedOutServesTheRunsAfterItIsDone() async throws {
        let engine = Self.engine(FakeSubjectLoader(delay: 0.6) { FakeSubjectModel() })
        defer { engine.release() }
        #expect(try await engine.leaseForRun(wait: 0.1) == nil)
        #expect(try await engine.leaseForRun(wait: 30) == nil && engine.status == .warming)
        for _ in 0..<2000 where engine.status == .warming { try await Task.sleep(for: .milliseconds(5)) }
        #expect(engine.status == .ready)
        #expect(try await engine.leaseForRun(wait: 30) != nil)
        engine.end()
    }

    @Test func aRunWithNothingToFollowDoesNotClearEarlierFailures() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        // Frame 8 stored empty (by a run on another engine).
        let other = Self.engine(FakeSubjectLoader { FakeSubjectModel(blind: [8]) })
        try await Self.ready(other)
        _ = try await Self.tracker(url, other).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(store.matte(key: "p", pts: 8.0 / 24)?.isBlank == true)
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader(failures: 1) { model })
        engine.prewarm()
        try await Self.settle(engine)
        try await Self.ready(engine)
        #expect(engine.failures == 1)
        // From the empty frame: the model is asked, answers no frame, and has proved nothing.
        let nothing = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 8.0 / 24, to: Self.end, store: store)
        #expect(nothing.frames == 0 && model.seen.tracks == 0 && engine.failures == 1)
        // A run it carries does clear them.
        let r = try await Self.tracker(url, engine).track(key: "q", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 24 && model.seen.tracks == 23 && engine.failures == 0)
    }

    /// Notes whether the leg's mark was set when the system's segmentation, the person's box and the model were asked.
    final class MarkLog: Sendable {
        let mark = Mutex<SubjectModelMark?>(nil)
        let seen = Mutex<[String: [Bool]]>([:])
        func note(_ who: String) {
            let on = mark.withLock { $0?.isSet }
            seen.withLock { $0[who, default: []].append(on ?? false) }
        }
    }

    struct NotingSegmenter: InstanceSegmenting {
        let log: MarkLog
        func segment(_ pb: CVPixelBuffer) throws -> InstanceFrame? {
            log.note("segmenter")
            return try MagicMaskTests.PatchSegmenter().segment(pb)
        }
    }

    @Test func theFrameCountsAsWithTheModelOnlyDuringItsPredictions() async throws {
        let log = MarkLog()
        let model = FakeSubjectModel(onTrack: { _ in log.note("model") })
        let engine = Self.engine(FakeSubjectLoader { model }, personBox: { _, _ in log.note("box"); return nil })
        try await Self.ready(engine)
        let lease = try #require(engine.lease())
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let leg = try #require(SubjectTrackLeg(lease: lease, segmenter: NotingSegmenter(log: log)))
        log.mark.withLock { $0 = leg.inModel }
        let reader = FrameReader(url: url, maxDimension: 320)
        try await reader.forEach(from: 0, to: 3.0 / 24) { pb, pts in
            _ = try leg.step(pb, pts: pts, gap: 1.0 / 24, points: Self.click) { nil }
            return true
        }
        let seen = log.seen.withLock { $0 }
        // The system's segmentation and the search for a person (Vision) are not the model: a hang there is not its.
        #expect(seen["segmenter"] == [false] && seen["box"] == [false])
        #expect(seen["model"]?.isEmpty == false && seen["model"]?.allSatisfy { $0 } == true)
        #expect(!leg.inModel.isSet)
        // Set for good when the model never answers.
        let mark = SubjectModelMark()
        #expect(throws: SubjectTrackError.stalled) { try mark.during { throw SubjectTrackError.stalled } }
        #expect(!mark.isSet)
    }

    @Test func aPredictionThatThrowsMidRunEndsOnTheSystemsSegmentationAndTheNextRunWorks() async throws {
        let models = Mutex(0)
        let first = FakeSubjectModel(failAt: 10), second = FakeSubjectModel()
        let loader = FakeSubjectLoader { models.withLock { $0 += 1; return $0 } == 1 ? first : second }
        let engine = Self.engine(loader)
        try await Self.ready(engine)
        let lease = try #require(engine.lease())
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        // Every frame has its matte: the frame the model failed on and the rest came from the system's segmentation.
        #expect(r.frames == 24 && !r.lost && store.times(key: "p").count == 24)
        try Self.expectPatch(store, "p", frames: [0, 9, 10, 11, 23])
        #expect(first.seen.tracks == 10)
        // The model was let go and is loaded again on the next use.
        #expect(lease.model == nil && engine.lease() == nil && engine.status == .idle && engine.failures == 1)
        try await Self.ready(engine)
        let again = try await Self.tracker(url, engine).track(key: "q", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(again.frames == 24 && second.seen.tracks == 23)
        try Self.expectPatch(store, "q", frames: [0, 12, 23])
        // A run the model carried to its end: the earlier failure no longer counts against it.
        #expect(engine.failures == 0 && engine.status == .ready)
    }

    // MARK: A prediction that never returns

    @Test func theDeadlineRunnerGivesUpOnWorkThatHangsAndNobodyWaitsBehindIt() throws {
        let runner = SubjectDeadlineRunner(deadline: 0.2)
        #expect(try runner.run { 7 } == 7)
        #expect(throws: SubjectTrackError.prediction("x")) { let _: Int = try runner.run { throw SubjectTrackError.prediction("x") } }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let clock = ContinuousClock()
        var started = clock.now
        #expect(throws: SubjectTrackError.stalled) { try runner.run { gate.wait() } }
        #expect(clock.now - started < .seconds(5) && runner.isAbandoned)
        // Abandoned: later calls throw at once and their work never starts.
        let ran = Mutex(false)
        started = clock.now
        #expect(throws: SubjectTrackError.stalled) { try runner.run { ran.withLock { $0 = true } } }
        let didRun = ran.withLock { $0 }
        #expect(clock.now - started < .seconds(2) && !didRun)
    }

    @Test func aCallWaitingBehindHungWorkIsLetGoAtOnceWhenTheRunnerIsAbandoned() async throws {
        let runner = SubjectDeadlineRunner(deadline: 1.5)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let begun = Mutex(false)
        let hung = Thread { _ = try? runner.run { begun.withLock { $0 = true }; gate.wait() } }
        hung.start()
        for _ in 0..<4000 where !begun.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
        try await Task.sleep(for: .seconds(1.2))
        // Queued 1.2 s into the hung work's 1.5 s: let go when that deadline passes, not 1.5 s after its own start.
        let ran = Mutex(false)
        let clock = ContinuousClock()
        let started = clock.now
        #expect(throws: SubjectTrackError.stalled) { try runner.run { ran.withLock { $0 = true } } }
        let didRun = ran.withLock { $0 }
        #expect(clock.now - started < .seconds(1.1) && !didRun && runner.isAbandoned)
    }

    @Test func theFirstPredictionsGetALongDeadlineAndSlowIsNotHung() throws {
        #expect(SubjectDeadlineRunner.selfTestSeconds >= 120 && SubjectDeadlineRunner.selfTestSeconds > SubjectDeadlineRunner.predictionSeconds)
        let runner = SubjectDeadlineRunner(deadline: 0.1)
        // Far over the prediction deadline, inside the self test's: finished, so no failure and nothing abandoned.
        let slow = try runner.withDeadline(20) { try runner.run { Thread.sleep(forTimeInterval: 0.5); return 3 } }
        #expect(slow == 3 && !runner.isAbandoned)
        // Afterwards the prediction deadline holds again.
        #expect(try runner.run { 4 } == 4)
        #expect(throws: SubjectTrackError.stalled) { try runner.run { Thread.sleep(forTimeInterval: 1.5) } }
        #expect(runner.isAbandoned)
    }

    @Test func aPredictionThatNeverReturnsEndsTheRunOnTheSystemsSegmentationAndTheNextPickDoesNotWait() async throws {
        let models = Mutex(0)
        let first = FakeSubjectModel(hangAt: 5, runner: SubjectDeadlineRunner(deadline: 0.3)), second = FakeSubjectModel()
        defer { first.unblock() }
        let loader = FakeSubjectLoader { models.withLock { $0 += 1; return $0 } == 1 ? first : second }
        let engine = Self.engine(loader)
        try await Self.ready(engine)
        let lease = try #require(engine.lease())
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        // The run ends by the prediction's own deadline, well before the frame lane would call the read hung (no wall
        // clock here: a run also waits for a slot of the lane, which other tests fill for a long time).
        var tracker = Self.tracker(url, engine)
        tracker.stallAfter = 20
        let r = try await tracker.track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        // The hung frame and the rest came from the system's segmentation; that model is abandoned.
        #expect(r.frames == 24 && !r.lost && store.times(key: "p").count == 24)
        try Self.expectPatch(store, "p", frames: [0, 4, 5, 6, 23])
        #expect(first.runner?.isAbandoned == true)
        #expect(lease.model == nil && engine.lease() == nil && engine.status == .idle && engine.failures == 1)
        // The next pick loads a fresh model and runs on it while the first prediction still hangs.
        try await Self.ready(engine)
        let again = try await Self.tracker(url, engine).track(key: "q", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(again.frames == 24 && second.seen.tracks == 23)
        try Self.expectPatch(store, "q", frames: [0, 12, 23])
    }

    @Test func aRunTheLaneCallsHungInsideTheModelAbandonsThatModelAndTheNextPickWorks() async throws {
        // No deadline of its own here: the frame lane's watchdog ends the run (it throws, as any hung read does).
        let models = Mutex(0)
        let first = FakeSubjectModel(hangAt: 5), second = FakeSubjectModel()
        defer { first.unblock() }
        let loader = FakeSubjectLoader { models.withLock { $0 += 1; return $0 } == 1 ? first : second }
        let engine = Self.engine(loader)
        try await Self.ready(engine)
        let lease = try #require(engine.lease())
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        var hung = Self.tracker(url, engine)
        hung.stallAfter = 0.5
        await #expect(throws: BlockingLane.Stalled.self) {
            _ = try await hung.track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        }
        #expect(lease.model == nil && engine.lease() == nil && engine.status == .idle && engine.failures == 1)
        // The next pick runs on a fresh model while the first one still hangs.
        try await Self.ready(engine)
        let again = try await Self.tracker(url, engine).track(key: "q", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(again.frames == 24 && second.seen.tracks == 23)
    }

    // MARK: What does not count against the model

    @Test func onlyTheModelsOwnFailuresCount() {
        #expect(SubjectTrackError.prediction("x").isModelFailure && SubjectTrackError.stalled.isModelFailure)
        #expect(!SubjectTrackError.emptyMatte.isModelFailure && !SubjectTrackError.released.isModelFailure)
    }

    @Test func aFaintStoredMatteIsNoStartForTheModelAndNoFailure() async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        // Not blank, but nowhere clearly the subject: the model cannot be conditioned on it.
        let faint = SubjectMatte(width: 32, height: 18, values: [Float](repeating: 0.3, count: 32 * 18))
        #expect(!faint.isBlank && SubjectTrackLeg.solid(faint) == nil)
        store.put(faint, key: "p", pts: 0)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 24 && !r.lost)
        try Self.expectPatch(store, "p", frames: [0, 12, 23])
        // The pick was answered by the model from the click, and the model carried the run.
        #expect(model.seen.conditions == 0 && model.seen.clicks >= 1 && model.seen.tracks == 23)
        #expect(engine.failures == 0 && engine.status == .ready)
    }

    /// Track from a frame whose stored matte is faint and that has no click of its own (the pick was made on another
    /// frame). The model cannot be conditioned on it, and the pick's click says nothing about this frame: the
    /// system's segmentation goes on from the stored matte (before: the run ended with 0 frames).
    @Test func aFaintStoredMatteWithoutAClickIsFollowedByTheSystemsSegmentation() async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        _ = try await Self.tracker(url, engine).track(key: "full", points: Self.click, from: 0, to: Self.end, store: store)
        let tracks = model.seen.tracks
        let start = 18.0 / 24
        let whole = try #require(store.matte(key: "full", pts: start))
        let faint = SubjectMatte(width: whole.width, height: whole.height, values: whole.values.map { $0 * 0.45 })
        #expect(!faint.isBlank && SubjectTrackLeg.solid(faint) == nil)
        store.put(faint, key: "p", pts: start)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: start, to: Self.end, store: store)
        #expect(r.frames == 6 && !r.lost)
        try Self.expectPatch(store, "p", frames: [19, 23])
        // Not the model's run and not its failure.
        #expect(model.seen.tracks == tracks && model.seen.conditions == 0 && engine.failures == 0 && engine.status == .ready)
    }

    /// Throws on its first frame, then sees the patch.
    final class StumblingSegmenter: InstanceSegmenting, Sendable {
        struct Stumble: Error {}
        let calls = Mutex(0)
        func segment(_ pb: CVPixelBuffer) throws -> InstanceFrame? {
            if calls.withLock({ $0 += 1; return $0 }) == 1 { throw Stumble() }
            return try MagicMaskTests.PatchSegmenter().segment(pb)
        }
    }

    @Test func anErrorOfTheSystemsSegmentationOnTheFirstFrameIsNotTheModelsFailure() async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let lease = try #require(engine.lease())
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let r = try await Self.tracker(url, engine, segmenter: StumblingSegmenter())
            .track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        // This run went on without the model; the model stays loaded and nothing counts against it.
        #expect(r.frames == 24 && !r.lost && model.seen.tracks == 0)
        #expect(engine.failures == 0 && engine.status == .ready && lease.model != nil)
    }

    @Test func theStoredMatteIsLookedUpOnlyOnTheFirstFrameAndOnFramesWithPoints() async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let lease = try #require(engine.lease())
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let leg = try #require(SubjectTrackLeg(lease: lease, segmenter: MagicMaskTests.PatchSegmenter()))
        // Off the tracked patch: a click on it is already answered by the tracked mask and needs no stored matte.
        let points = Self.click + [MagicPoint(position: Vec2(150.0 / 320, 0.5), subtract: false, sourceTime: Time(12, 24))]
        let lookups = Mutex<[Int]>([])
        let reader = FrameReader(url: url, maxDimension: 320)
        var index = 0
        try await reader.forEach(from: 0, to: Self.end) { pb, pts in
            let i = index
            index += 1
            _ = try leg.step(pb, pts: pts, gap: 1.0 / 24, points: points) { lookups.withLock { $0.append(i) }; return nil }
            return true
        }
        #expect(lookups.withLock { $0 } == [0, 12])
    }

    @Test func aModelThatKeepsFailingIsGivenUpAndTheToolStillTracks() async throws {
        let loader = FakeSubjectLoader { FakeSubjectModel(failAt: 1) }
        let engine = Self.engine(loader)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        for run in 0..<3 {
            engine.prewarm()
            try await Self.settle(engine)
            let r = try await Self.tracker(url, engine).track(key: "p\(run)", points: Self.click, from: 0, to: Self.end, store: store)
            #expect(r.frames == 24 && !r.lost, "run \(run)")
        }
        #expect(engine.status == .unavailable("the tracking model failed") && loader.calls == 2)
    }

    @Test func aRunCanceledOnTheModelStopsAndTheNextRunWorks() async throws {
        let running = Mutex<Task<MagicMaskTracker.Result, any Error>?>(nil)
        let model = FakeSubjectModel(onTrack: { n in
            guard n == 5 else { return }
            for _ in 0..<2000 {
                if let t = running.withLock({ $0 }) { t.cancel(); return }
                Thread.sleep(forTimeInterval: 0.001)
            }
        })
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let tracker = Self.tracker(url, engine)
        let task = Task { try await tracker.track(key: "p", points: Self.click, from: 0, to: Self.end, store: store) }
        running.withLock { $0 = task }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        // The frame that was in work when it stopped is not written; the model stays loaded.
        #expect(store.times(key: "p").count == 5 && engine.status == .ready && engine.failures == 0)
        running.withLock { $0 = nil }
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 24 && !r.lost && store.times(key: "p").count == 24)
    }

    @Test func everyTrackedFrameIsLookedAheadWhileTheFrameBeforeIsWithTheModel() async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 24)
        // Frames 2 to 24 are tracked, each was looked ahead while the frame before it was answered.
        #expect(model.seen.tracks == 23 && model.seen.tracksAhead == 23 && model.seen.aheads == 23)
        // Backward from the last frame (conditioned on its stored matte): the same in the leg's order; only a frame
        // that opens a read chunk is not known ahead.
        let back = FakeSubjectModel()
        let engine2 = Self.engine(FakeSubjectLoader { back })
        try await Self.ready(engine2)
        let b = try await Self.tracker(url, engine2).track(key: "p", points: Self.click, from: Self.end, to: 0, store: store)
        #expect(b.frames == 24 && back.seen.tracks == 23)
        #expect(back.seen.tracksAhead >= back.seen.tracks - 2)
    }

    @Test func framesTheModelDoesNotFindTheSubjectOnAreStoredEmptyAndTheRunGoesOn() async throws {
        let model = FakeSubjectModel(blind: [8, 9])   // frames 8 and 9
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 22 && r.lost && r.lostTimes.count == 2)
        #expect(r.lostTimes.first.map { abs($0 - 8.0 / 24) < 1e-3 } == true)
        #expect(store.times(key: "p").count == 24)
        #expect(store.matte(key: "p", pts: 8.0 / 24)?.isBlank == true && store.matte(key: "p", pts: 9.0 / 24)?.isBlank == true)
        try Self.expectPatch(store, "p", frames: [7, 10, 23])
        #expect(model.seen.tracks == 23 && engine.status == .ready)
    }

    @Test func onlyTheFirstEmptyFramesOfALongGapEnterTheModelsMemory() async throws {
        let model = FakeSubjectModel(blind: Set(8...15))   // eight tracked frames in a row without the subject
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 16 && r.lostTimes.count == 8)
        // 23 tracked frames: the 15 with the subject and the first `limit` empty ones are remembered.
        let limit = SubjectAbsenceMemory.tracker.limit
        #expect(model.seen.tracks == 23 && model.seen.commits == 15 + limit)
        try Self.expectPatch(store, "p", frames: [7, 16, 23])
    }

    @Test func aWeakMaskRightAfterAGapIsNotTheSubjectBack() async throws {
        let model = FakeSubjectModel(blind: Set(8...12))
        model.weak = [4, 13, 14]   // weak inside the track (kept) and right after the gap (a look-alike)
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(SubjectReacquireRule.tracker.afterLost <= 5 && SubjectReacquireRule.tracker.minScore > 0.5)
        // Frames 8 to 14 are lost (five empty, two weak after them); the weak frame 4 inside the track is kept.
        #expect(r.frames == 17 && r.lostTimes.count == 7)
        // The weak masks after the gap stay out of the memory: 16 found frames and the first `limit` empty ones.
        #expect(model.seen.tracks == 23 && model.seen.commits == 16 + SubjectAbsenceMemory.tracker.limit)
    }

    @Test func aCorrectedFrameConditionsTheModelAnew() async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        _ = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        // A correction made on frame 12 (its corrected matte is stored there by the click): tracked again from the pick.
        let corrected = Self.click + [MagicPoint(position: Vec2(130.0 / 320, 92.0 / 180), subtract: false, sourceTime: Time(12, 24))]
        let before = model.seen
        let r = try await Self.tracker(url, engine).track(key: "p", points: corrected, from: 0, to: Self.end, store: store)
        let after = model.seen
        #expect(r.frames == 24 && !r.lost)
        // The click lies on the tracked patch: the tracked mask already answers it and stays (no new conditioning).
        #expect(after.conditions == before.conditions && after.tracks - before.tracks == 23 && after.clicks - before.clicks == 1)
        #expect(after.corrections == before.corrections)
        // Tracked on from the corrected frame itself: the stored matte is the start, not a new click.
        let from12 = try await Self.tracker(url, engine).track(key: "p", points: corrected, from: 0.5, to: Self.end, store: store)
        #expect(from12.frames == 12 && model.seen.conditions - after.conditions == 1 && model.seen.clicks == after.clicks)
    }

    /// A click off the tracked mask: the model is asked again with it on that frame; with no candidate that refines
    /// the tracked mask the stored matte (the system's pick) is conditioned on, as before.
    @Test func aCorrectionOffTheMaskWithoutARefinementConditionsOnTheStoredMatte() async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        _ = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        let off = Self.click + [MagicPoint(position: Vec2(150.0 / 320, 92.0 / 180), subtract: false, sourceTime: Time(12, 24))]
        let before = model.seen
        let r = try await Self.tracker(url, engine).track(key: "p", points: off, from: 0, to: Self.end, store: store)
        let after = model.seen
        #expect(r.frames == 24 && !r.lost)
        #expect(after.corrections - before.corrections == 1 && after.adopts == before.adopts)
        #expect(after.conditions - before.conditions == 1 && after.tracks - before.tracks == 23)
    }

    /// A click off the tracked mask that the model's second answer adds without losing the tracked mask: that answer
    /// is the frame's matte and is remembered; the stored matte is not used.
    @Test func aCorrectionOffTheMaskTakesTheModelsRefinement() async throws {
        let model = FakeSubjectModel()
        model.offersCorrections = true
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        _ = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        let click = Vec2(150.0 / 320, 92.0 / 180)
        let off = Self.click + [MagicPoint(position: click, subtract: false, sourceTime: Time(12, 24))]
        let before = model.seen
        let r = try await Self.tracker(url, engine).track(key: "p", points: off, from: 0, to: Self.end, store: store)
        let after = model.seen
        #expect(r.frames == 24 && !r.lost)
        #expect(after.corrections - before.corrections == 1 && after.adopts - before.adopts == 1 && after.conditions == before.conditions)
        let m = try #require(store.matte(key: "p", pts: 0.5))
        #expect(SubjectCorrectionRule.answers([MagicPoint(position: click, subtract: false, sourceTime: .zero)], matte: m))
    }

    @Test func aTrackFromAFrameStoredEmptyFollowsNothing() async throws {
        let model = FakeSubjectModel(blind: [8])
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        _ = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        let again = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 8.0 / 24, to: Self.end, store: store)
        #expect(again.frames == 0 && store.matte(key: "p", pts: 20.0 / 24)?.isBlank == false)
    }

    @Test func aMaskThatMustCoverStaysOnTheSystemsSegmentation() async throws {
        let model = FakeSubjectModel()
        let engine = Self.engine(FakeSubjectLoader { model })
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store, marksLost: false)
        #expect(r.frames == 24 && model.seen.sessions == 0)
    }

    // MARK: Memory

    @Test func memoryPressureTakesTheModelAwayAndItComesBack() async throws {
        let registry = MemoryPressureRegistry(systemEvents: false)
        let model = FakeSubjectModel()
        let loader = FakeSubjectLoader { model }
        let engine = Self.engine(loader, pressure: registry)
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let held = Self.tracker(url, engine)
        let lease = try #require(engine.lease())
        // A warning spares a model a run is on, and drops one nobody uses.
        engine.begin()
        registry.post(.warning)
        #expect(engine.status == .ready && lease.model != nil)
        // The spared model is let go when its last run ends, without waiting for another warning.
        engine.begin()
        engine.end()
        #expect(engine.status == .ready)
        engine.end()
        #expect(engine.status == .idle && lease.model == nil && engine.lease() == nil)
        // While memory is short nothing is loaded, and a tracker that held the model tracks without it.
        engine.prewarm()
        #expect(engine.status == .idle && loader.calls == 1)
        let r = try await held.track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 24 && model.seen.sessions == 0 && loader.calls == 1)
        registry.post(.normal)
        try await Self.ready(engine)
        #expect(loader.calls == 2 && engine.failures == 0)
    }

    @Test func aRunCountsAsOnTheModelFromTheMomentItGetsItsLease() async throws {
        let registry = MemoryPressureRegistry(systemEvents: false)
        let engine = Self.engine(FakeSubjectLoader { FakeSubjectModel() }, pressure: registry)
        try await Self.ready(engine)
        // No gap between getting the lease and being counted: a warning right after spares the model.
        let lease = try #require(try await engine.leaseForRun())
        registry.post(.warning)
        #expect(engine.status == .ready && lease.model != nil)
        // Its end lets the spared model go in one step: nothing is ready and nobody gets a lease of it afterwards.
        engine.end()
        #expect(engine.status == .idle && lease.model == nil && engine.lease() == nil)
        let none = try await engine.leaseForRun()
        #expect(none == nil)
    }

    @Test func criticalPressureMidRunFinishesTheRunOnTheSystemsSegmentation() async throws {
        let registry = MemoryPressureRegistry(systemEvents: false)
        let model = FakeSubjectModel(onTrack: { n in if n == 6 { registry.post(.critical) } })
        let engine = Self.engine(FakeSubjectLoader { model }, pressure: registry)
        try await Self.ready(engine)
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let r = try await Self.tracker(url, engine).track(key: "p", points: Self.click, from: 0, to: Self.end, store: store)
        #expect(r.frames == 24 && !r.lost && store.times(key: "p").count == 24)
        try Self.expectPatch(store, "p", frames: [0, 6, 7, 23])
        // Frame 6 was still the model's; from frame 7 on the system's segmentation. Not a failure of the model.
        #expect(model.seen.tracks == 6 && engine.status == .idle && engine.failures == 0)
    }

    @Test func aLoadThatIsCanceledStartsOverOnTheNextUse() async throws {
        let model = FakeSubjectModel()
        let loader = FakeSubjectLoader(hangs: 1) { model }
        let engine = Self.engine(loader)
        engine.prewarm()
        engine.prewarm()   // asked twice: one load
        #expect(engine.status == .warming && engine.lease() == nil)
        for _ in 0..<2000 where loader.calls == 0 { try await Task.sleep(for: .milliseconds(2)) }
        engine.cancelPrewarm()
        #expect(engine.status == .idle)
        try await Self.ready(engine)
        #expect(loader.calls == 2 && engine.failures == 0)
        // Let go by hand (the app under memory pressure): loads again on the next use.
        engine.release()
        #expect(engine.status == .idle && engine.lease() == nil)
        try await Self.ready(engine)
        #expect(loader.calls == 3)
    }

    // MARK: One load at a time

    /// A load nothing stops (as Core ML's): it ends when the test lets it, and only then looks at its cancellation
    /// (`honorsCancel`: between two parts, as the real loader does).
    final class StubbornLoader: SubjectMaskLoading, Sendable {
        private struct State { var calls = 0, inFlight = 0, peak = 0, permits = 0, waiting: [CheckedContinuation<Void, Never>] = [] }
        private let state = Mutex(State())
        let honorsCancel: Bool
        init(honorsCancel: Bool = false) { self.honorsCancel = honorsCancel }

        var calls: Int { state.withLock { $0.calls } }
        /// Most loads that ran at the same time.
        var peak: Int { state.withLock { $0.peak } }

        /// Lets one load end (the one waiting longest, else the next one to come).
        func finishOne() {
            let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
                if s.waiting.isEmpty { s.permits += 1; return nil }
                return s.waiting.removeFirst()
            }
            next?.resume()
        }

        func load(_ parts: SubjectMaskParts, compute: SubjectTrackCompute) async throws -> any SubjectTrackModel {
            state.withLock { $0.calls += 1; $0.inFlight += 1; $0.peak = max($0.peak, $0.inFlight) }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let go = state.withLock { s -> Bool in
                    if s.permits > 0 { s.permits -= 1; return true }
                    s.waiting.append(c)
                    return false
                }
                if go { c.resume() }
            }
            state.withLock { $0.inFlight -= 1 }
            if honorsCancel { try Task.checkCancellation() }
            return FakeSubjectModel()
        }
    }

    static func started(_ loader: StubbornLoader, _ calls: Int) async throws {
        for _ in 0..<2000 where loader.calls < calls { try await Task.sleep(for: .milliseconds(2)) }
        #expect(loader.calls == calls)
    }

    /// Memory got short while the model loaded: the load is given up, but it cannot be stopped. Asked again while
    /// it still runs, the engine starts no second load next to it (before: two loads, twice the memory, right after
    /// a memory warning) and takes the model of the one under way.
    @Test func aLoadThatCannotBeStoppedIsNotStartedASecondTimeAfterMemoryPressure() async throws {
        let registry = MemoryPressureRegistry(systemEvents: false)
        let loader = StubbornLoader()
        let engine = SubjectMaskEngine(locate: { .parts(Self.parts) }, compute: .gpu, loader: loader, pressure: registry)
        engine.prewarm()
        try await Self.started(loader, 1)
        registry.post(.warning)
        #expect(engine.status == .idle)
        registry.post(.normal)
        engine.prewarm()
        #expect(engine.status == .warming)
        try await Task.sleep(for: .milliseconds(150))
        #expect(loader.calls == 1 && loader.peak == 1 && engine.lease() == nil)
        loader.finishOne()
        try await Self.settle(engine)
        #expect(engine.status == .ready && engine.lease() != nil && loader.calls == 1 && engine.failures == 0)
    }

    /// The same after the tool was left and chosen again; and a load nobody asked for again leaves nothing behind.
    @Test func aLoadGivenUpAndNotAskedForAgainLeavesNoModel() async throws {
        let loader = StubbornLoader()
        let engine = SubjectMaskEngine(locate: { .parts(Self.parts) }, compute: .gpu, loader: loader)
        engine.prewarm()
        try await Self.started(loader, 1)
        engine.cancelPrewarm()
        engine.prewarm()
        engine.cancelPrewarm()
        #expect(engine.status == .idle && loader.calls == 1)
        loader.finishOne()
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.status == .idle && engine.lease() == nil && loader.calls == 1)
        // Nothing is in flight now: the next use loads.
        loader.finishOne()
        try await Self.ready(engine)
        #expect(loader.calls == 2 && loader.peak == 1)
    }

    /// A load that does end on its cancellation (between two parts) gives no model: the load asked for meanwhile
    /// starts when it is gone, not next to it.
    @Test func theLoadAskedForBehindACanceledOneStartsWhenThatOneEnded() async throws {
        let loader = StubbornLoader(honorsCancel: true)
        let engine = SubjectMaskEngine(locate: { .parts(Self.parts) }, compute: .gpu, loader: loader)
        engine.prewarm()
        try await Self.started(loader, 1)
        engine.cancelPrewarm()
        engine.prewarm()
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.status == .warming && loader.calls == 1)
        loader.finishOne()
        try await Self.started(loader, 2)
        #expect(engine.status == .warming && loader.peak == 1)
        loader.finishOne()
        try await Self.settle(engine)
        #expect(engine.status == .ready && loader.calls == 2 && loader.peak == 1 && engine.failures == 0)
    }

    /// A run that waits for the load asked for behind one that cannot be stopped keeps `cancelPrewarm` away, and
    /// gets the model of the load under way.
    @Test func aRunWaitingBehindALoadThatCannotBeStoppedGetsItsModel() async throws {
        let loader = StubbornLoader()
        let engine = SubjectMaskEngine(locate: { .parts(Self.parts) }, compute: .gpu, loader: loader)
        engine.prewarm()
        try await Self.started(loader, 1)
        engine.cancelPrewarm()
        let run = Task { try await engine.leaseForRun(wait: 20) }
        for _ in 0..<2000 where engine.status != .warming { try await Task.sleep(for: .milliseconds(2)) }
        try await Task.sleep(for: .milliseconds(60))
        engine.cancelPrewarm()
        #expect(engine.status == .warming && loader.calls == 1)
        loader.finishOne()
        let lease = try await run.value
        #expect(lease?.model != nil && engine.status == .ready && loader.calls == 1)
        engine.end()
    }

    /// A load that never returns: the first pick waits its time. Leaving the tool and choosing it again (or a memory
    /// warning) starts no new load, so the picks after it do not wait for the same hung load again (before: the
    /// full wait after every tool switch).
    @Test func aHungLoadIsNotWaitedForAgainAfterTheToolWasLeftAndChosenAgain() async throws {
        let registry = MemoryPressureRegistry(systemEvents: false)
        let loader = StubbornLoader()
        let engine = SubjectMaskEngine(locate: { .parts(Self.parts) }, compute: .gpu, loader: loader, pressure: registry)
        let first = try await engine.leaseForRun(wait: 0.4)
        #expect(first == nil && engine.status == .warming)
        let clock = ContinuousClock()
        engine.cancelPrewarm()
        try await Task.sleep(for: .milliseconds(300))
        engine.prewarm()
        var start = clock.now
        let second = try await engine.leaseForRun(wait: 30)
        #expect(second == nil && clock.now - start < .milliseconds(150) && loader.calls == 1)
        registry.post(.warning)
        registry.post(.normal)
        start = clock.now
        let third = try await engine.leaseForRun(wait: 30)
        #expect(third == nil && clock.now - start < .seconds(2) && loader.calls == 1 && engine.status == .warming)
        // It ends after all: its model serves the next run.
        loader.finishOne()
        try await Self.settle(engine)
        let fourth = try await engine.leaseForRun(wait: 30)
        #expect(fourth?.model != nil && loader.calls == 1)
        engine.end()
    }

    /// A load that did not end within `hungLoadSeconds` is written off: the next use loads again beside it (one
    /// fresh load, counted as a failure of the model), and whatever the hung one brings later is thrown away.
    @Test func aLoadHungPastItsDeadlineIsWrittenOffAndLoadedAgain() async throws {
        let loader = StubbornLoader()
        let engine = SubjectMaskEngine(locate: { .parts(Self.parts) }, compute: .gpu, loader: loader, hungLoadSeconds: 0.3)
        engine.prewarm()
        try await Self.started(loader, 1)
        engine.prewarm()
        #expect(loader.calls == 1)
        try await Task.sleep(for: .milliseconds(400))
        engine.prewarm()
        try await Self.started(loader, 2)
        engine.prewarm()
        #expect(engine.status == .warming && engine.failures == 1 && loader.calls == 2)
        // The hung one returns late: not taken.
        loader.finishOne()
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.status == .warming && engine.lease() == nil)
        loader.finishOne()
        try await Self.settle(engine)
        #expect(engine.status == .ready && loader.calls == 2 && loader.peak == 2)
    }

    /// The load after a written-off one hangs too: the model is given up for this launch, no third load starts.
    @Test func twoHungLoadsGiveTheModelUp() async throws {
        let loader = StubbornLoader()
        let engine = SubjectMaskEngine(locate: { .parts(Self.parts) }, compute: .gpu, loader: loader, hungLoadSeconds: 0.2)
        engine.prewarm()
        try await Self.started(loader, 1)
        try await Task.sleep(for: .milliseconds(300))
        engine.prewarm()
        try await Self.started(loader, 2)
        try await Task.sleep(for: .milliseconds(300))
        engine.prewarm()
        engine.prewarm()
        #expect(engine.status == .unavailable("the tracking model did not finish loading") && loader.calls == 2)
        loader.finishOne()
        loader.finishOne()
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.lease() == nil && loader.calls == 2)
    }

    // MARK: Loading with the tool

    /// The tool was chosen (`prewarm`) a moment before the first pick: that pick's run finds the model loaded and
    /// never says it is preparing (before: the load began with the first run, which waited for it).
    @Test func aModelLoadedWithTheToolLetsTheFirstRunStartWithoutWaiting() async throws {
        let loader = FakeSubjectLoader(delay: 0.3) { FakeSubjectModel() }
        let engine = Self.engine(loader)
        defer { engine.release() }
        engine.prewarm()
        engine.prewarm()
        try await Self.settle(engine)
        let told = Mutex<[Bool]>([])
        let clock = ContinuousClock()
        let start = clock.now
        let lease = try await engine.leaseForRun(wait: 20) { w in told.withLock { $0.append(w) } }
        #expect(lease?.model != nil && told.withLock { $0 }.isEmpty && clock.now - start < .milliseconds(150))
        #expect(loader.calls == 1)
        engine.end()
    }

    /// The tool was chosen and left again without a pick: the load is stopped and nothing stays loaded. Chosen while
    /// its first pick already waits, leaving it does not take the load away under that run.
    @Test func aLoadStartedWithTheToolIsStoppedWhenTheToolIsLeftUnused() async throws {
        let loader = FakeSubjectLoader(delay: 0.3) { FakeSubjectModel() }
        let engine = Self.engine(loader)
        defer { engine.release() }
        engine.prewarm()
        engine.cancelPrewarm()
        try await Task.sleep(for: .milliseconds(450))
        #expect(engine.status == .idle && engine.lease() == nil && loader.calls == 1)
        engine.prewarm()
        let run = Task { try await engine.leaseForRun(wait: 20) }
        try await Task.sleep(for: .milliseconds(80))
        engine.cancelPrewarm()
        let lease = try await run.value
        #expect(lease?.model != nil && engine.status == .ready && loader.calls == 2)
        engine.end()
    }

    // MARK: Edges

    @Test func theEdgeStepPullsTheMatteOntoThePicturesEdgeAndLeavesTheRestAlone() {
        let w = 320, h = 180
        // Picture: bright right of x = 160. Matte: soft ramp centered 3 px left of it (x = 157).
        var gray = [Float](repeating: 0.1, count: w * h), values = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                if x >= 160 { gray[y * w + x] = 0.9 }
                values[y * w + x] = min(max((Float(x) - 157) / 6 + 0.5, 0), 1)
            }
        }
        let matte = SubjectMatte(width: w, height: h, values: values)
        let out = SubjectMatteEdges.refine(matte, gray: gray)
        #expect(out.width == w && out.height == h && !out.values.contains { !($0 >= 0 && $0 <= 1) })
        let y = 90
        // Left of the picture's edge the matte went down, right of it up: the step follows the picture.
        #expect(out[158, y] < matte[158, y] - 0.1 && out[159, y] < 0.4)
        #expect(out[161, y] > 0.75)
        // Far from the edge nothing changed.
        #expect(out[40, y] == 0 && out[280, y] == 1)
        // A matte too small for the step comes back as it is.
        let small = SubjectMatte(width: 8, height: 8, values: [Float](repeating: 0.5, count: 64))
        #expect(SubjectMatteEdges.refine(small, gray: [Float](repeating: 0.5, count: 64)) == small)
    }
}
