import Foundation
import Testing
import Synchronization
import SQCore
@testable import SQRender

private func constantLUT(_ v: Float, title: String) -> CubeLUT {
    CubeLUT(title: title, kind: .lut3D, size: 2, table: Array(repeating: SIMD3<Float>(repeating: v), count: 8))
}

/// LUT provider whose contents and file stamps tests can change; counts lookups.
private final class MutableProvider: LUTProvider, @unchecked Sendable {
    let lock = NSLock()
    var table: [LUTRef: CubeLUT] = [:]
    var stamps: [LUTRef: LUTStamp] = [:]
    var lookups = 0
    func lut(for ref: LUTRef) -> CubeLUT? { lock.lock(); defer { lock.unlock() }; lookups += 1; return table[ref] }
    func stamp(for ref: LUTRef) -> LUTStamp? { lock.lock(); defer { lock.unlock() }; return stamps[ref] }
    func set(_ ref: LUTRef, _ lut: CubeLUT?, stamp: LUTStamp? = nil) {
        lock.lock(); defer { lock.unlock() }
        table[ref] = lut; stamps[ref] = stamp
    }
}

@Suite struct LayerColorResolverTests {
    let slogID = UUID(), rec709ID = UUID()

    func make(provider: LUTProvider? = nil, embedded: String? = nil) -> LayerColorResolver {
        let slog = MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine, embeddedLUTName: embedded)
        let plain = MediaInfo(duration: Time(1, 1), detectedColorSpace: .rec709)
        let (s, r) = (slogID, rec709ID)
        return LayerColorResolver(lutProvider: provider) { $0 == s ? slog : ($0 == r ? plain : nil) }
    }

    @Test func identityRec709TakesFastPath() {
        let r = make()
        #expect(r.pipeline(for: .default, media: rec709ID) == nil)
        #expect(r.pipeline(for: .default, media: UUID()) == nil)          // unknown media = Rec.709
        #expect(r.cachedCount == 0)                                       // no work, no cache
        var c = ClipColor.default
        c.effects[0].basic.exposure = 1; c.effects[0].setEnabled(.basicCorrection, false)
        #expect(r.pipelineBlocking(for: c, media: rec709ID) == nil)       // disabled correction is identity
    }

    @Test func reorderingGraphStepsKeepsTheLUTCacheEntry() async {
        let p = MutableProvider()
        let a = LUTRef.file("/a.cube"), b = LUTRef.file("/b.cube")
        p.set(a, constantLUT(0.2, title: "a")); p.set(b, constantLUT(0.6, title: "b"))
        func grade(_ order: [LUTRef]) -> ClipColor {
            var g = ColorGraph(); g.isActive = true
            g.steps = order.map { var s = ColorStep(label: "S"); s.lut = $0; return s }
            var c = ClipColor.default; c.graph = g
            return c
        }
        let r = make(provider: p)
        _ = r.pipeline(for: grade([a, b]), media: slogID)
        await r.waitUntilIdle()
        _ = r.pipeline(for: grade([b, a]), media: slogID)
        await r.waitUntilIdle()
        #expect(r.cachedCount == 1, "same LUT set in another Step order is the same cache entry")
    }

    @Test func lookupNeverBuildsOnTheCallingThread() async {
        let p = MutableProvider()
        var c = ClipColor.default; c.effects[0].inputLUT = .file("/x.cube")
        p.set(.file("/x.cube"), constantLUT(0.5, title: "x"))
        let r = make(provider: p)
        #expect(r.pipeline(for: c, media: slogID) == nil)                 // miss: identity until warm
        await r.waitUntilIdle()
        #expect(r.pipeline(for: c, media: slogID)?.conversionLUT?.title == "x")
    }

    @Test func missReturnsPreviousPipelineOfThatMediaAndNotifiesWhenWarm() async {
        let p = MutableProvider()
        let ref = LUTRef.file("/look.cube")
        p.set(ref, constantLUT(0.5, title: "look"))
        let r = make(provider: p)
        let warmed = Mutex(0)
        r.setOnWarmed { warmed.withLock { $0 += 1 } }
        // Without LUTs nothing is read from disk: the pipeline is assembled on the spot.
        #expect(r.pipeline(for: .default, media: slogID)?.source == .sLog3SGamut3Cine)
        var c = ClipColor.default; c.effects[0].creative.look = ref
        let during = r.pipeline(for: c, media: slogID)                    // LUT not loaded yet: previous pipeline
        #expect(during?.source == .sLog3SGamut3Cine && during?.creativeLUT == nil)
        await r.waitUntilIdle()
        #expect(warmed.withLock { $0 } == 1)
        #expect(r.pipeline(for: c, media: slogID)?.creativeLUT?.title == "look")
    }

    /// Review: the remembered pipeline per owner is bounded by pruning the least recently used owners, not by forgetting
    /// all of them: an owner on screen keeps the fallback it draws while a changed grade's LUTs load.
    @Test func servedPruningKeepsRecentlyUsedOwners() async {
        let p = MutableProvider()
        let ref = LUTRef.file("/late.cube")
        let r = make(provider: p)
        let onScreen = UUID()
        var graded = ClipColor.default; graded.effects[0].basic.exposure = 1
        let limit = LayerColorResolver.servedLimit
        func filler(_ n: Int) {
            for i in 0..<n {
                var c = ClipColor.default; c.effects[0].basic.exposure = Float(i % 7 + 2) / 10
                _ = r.pipelineBlocking(for: c, media: rec709ID, owner: UUID())
            }
        }
        filler(limit - 2)
        #expect(r.pipeline(for: graded, media: rec709ID, owner: onScreen) != nil)
        filler(8)                                                          // overflows right after the owner was drawn
        #expect(r.servedCount <= limit)
        var changed = graded; changed.effects[0].creative.look = ref       // LUT not loaded yet: previous pipeline
        p.set(ref, constantLUT(0.5, title: "late"))
        let during = r.pipeline(for: changed, media: rec709ID, owner: onScreen)
        #expect(during != nil && during?.creativeLUT == nil)
        await r.waitUntilIdle()
    }

    /// Review finding (W5.2): a keyframed grade is a new ClipColor every frame. Each frame must render its own values
    /// at once (no lag behind the playhead) while the LUTs are loaded only once.
    @Test func keyframedGradeFramesShareTheLUTsAndRenderTheirOwnValues() async {
        let p = MutableProvider()
        let ref = LUTRef.file("/look.cube")
        p.set(ref, constantLUT(0.5, title: "look"))
        let r = make(provider: p)
        func frame(_ exposure: Float) -> ClipColor {
            var c = ClipColor.default
            c.effects[0].creative.look = ref; c.effects[0].creative.intensity = 50
            c.effects[0].basic.exposure = exposure
            return c
        }
        r.warm([(frame(0), slogID)])
        await r.waitUntilIdle()
        let loads = p.lock.withLock { p.lookups }
        let probe = SIMD3<Float>(repeating: 0.4)
        for exposure: Float in [0, 0.5, 1, 1.5] {
            let c = frame(exposure)
            let got = r.pipeline(for: c, media: slogID)
            let expected = ColorPipeline.from(clipColor: c, mediaID: slogID,
                                              mediaInfo: MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine),
                                              lutProvider: p)
            #expect(got?.process(probe) == expected.process(probe), "exposure \(exposure)")
        }
        #expect(r.pipelineBlocking(for: frame(2), media: slogID)?.creativeLUT?.title == "look")
        // `expected` above asked the provider 4 times; the resolver itself loaded nothing more.
        #expect(p.lock.withLock { p.lookups } == loads + 4)
        #expect(r.cachedCount == 1)
    }

    @Test func blockingBuildCachesForLookups() {
        let r = make()
        #expect(r.pipelineBlocking(for: .default, media: slogID)?.source == .sLog3SGamut3Cine)
        #expect(r.cachedCount == 1)
        #expect(r.pipeline(for: .default, media: slogID) != nil)
        r.invalidate()
        #expect(r.cachedCount == 0)
    }

    @Test func failedLUTIsRetriedOnNextWarm() async {
        let p = MutableProvider()
        let ref = LUTRef.embedded(slogID)
        let r = make(provider: p, embedded: "Look")
        #expect(r.pipelineBlocking(for: .default, media: slogID)?.conversionLUT == nil)   // embedded LUT failed to load
        // Still failing: a plain lookup serves the degraded pipeline but does not pin it.
        p.set(ref, constantLUT(0.25, title: "embedded"))
        r.warm([(.default, slogID)])
        await r.waitUntilIdle()
        #expect(r.pipeline(for: .default, media: slogID)?.conversionLUT?.title == "embedded")
    }

    @Test func editedFileLUTIsReloadedOnWarm() async {
        let p = MutableProvider()
        let ref = LUTRef.file("/a.cube")
        var c = ClipColor.default
        c.effects[0].creative.look = ref
        p.set(ref, constantLUT(0.1, title: "v1"), stamp: LUTStamp(modified: Date(timeIntervalSince1970: 1), size: 10))
        let r = make(provider: p)
        #expect(r.pipelineBlocking(for: c, media: slogID)?.creativeLUT?.title == "v1")
        p.set(ref, constantLUT(0.2, title: "v2"), stamp: LUTStamp(modified: Date(timeIntervalSince1970: 2), size: 10))
        r.warm([(c, slogID)])
        await r.waitUntilIdle()
        #expect(r.pipeline(for: c, media: slogID)?.creativeLUT?.title == "v2")
    }

    @Test func cachingProviderKeysFileLUTsByStamp() {
        let data = Mutex(Data("TITLE \"a\"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8))
        let stamp = Mutex(LUTStamp(modified: Date(timeIntervalSince1970: 1), size: 1))
        let loads = Mutex(0)
        let p = CachingLUTProvider(file: { _ in loads.withLock { $0 += 1 }; return data.withLock { $0 } },
                                   embedded: { _ in nil }, stamp: { _ in stamp.withLock { $0 } })
        #expect(p.lut(for: .file("/a.cube")) != nil)
        #expect(p.lut(for: .file("/a.cube")) != nil)
        #expect(loads.withLock { $0 } == 1)
        stamp.withLock { $0 = LUTStamp(modified: Date(timeIntervalSince1970: 2), size: 1) }
        #expect(p.lut(for: .file("/a.cube")) != nil)
        #expect(loads.withLock { $0 } == 2)
    }

    @Test func sourceOverrideToRec709IsIdentity() {
        let r = make()
        var c = ClipColor.default; c.source = .rec709
        #expect(r.pipelineBlocking(for: c, media: slogID) == nil)
        c.source = .hlgBT2020
        #expect(r.pipelineBlocking(for: c, media: rec709ID)?.source == .hlgBT2020)
    }

    @Test func disabledInputLUTOnLogMediaStillConverts() {
        let r = make()
        var c = ClipColor.default; c.effects[0].setEnabled(.basicCorrection, false)
        let p = r.pipelineBlocking(for: c, media: slogID)
        #expect(p?.source == .sLog3SGamut3Cine && p?.conversionLUT == nil)
        #expect(p?.process(SIMD3(repeating: 0.5)) != SIMD3<Float>(repeating: TransferFunctions.bt709InverseOETF(0.5)))
    }

    /// Source and Program monitors resolve color through the same resolver: a clip (owner) and a bare media preview
    /// (no owner) with the same settings give the same chain. Auto-detected log once overexposed the Source monitor only.
    @Test func sourceAndProgramShareTheColorPipeline() {
        let r = make()
        let program = r.pipelineBlocking(for: .default, media: slogID, owner: UUID())
        let source = r.pipelineBlocking(for: .default, media: slogID, owner: nil)
        #expect(program?.source == .sLog3SGamut3Cine)
        #expect(source?.source == program?.source)
        for v: Float in [0.1, 0.35, 0.6, 0.9] {
            let px = SIMD3<Float>(v, v * 0.8, v * 0.6)
            #expect(source?.process(px) == program?.process(px))
        }
        // Plain Rec.709 media is untouched in both.
        #expect(r.pipelineBlocking(for: .default, media: rec709ID, owner: nil) == nil)
        #expect(r.pipelineBlocking(for: .default, media: rec709ID, owner: UUID()) == nil)
    }
}

/// Source and Program monitors ask the same resolver; the pipeline must not depend on who asks (a clip owner in the
/// Program, the media itself in the Source monitor). Regression: auto-detected log made only the Source monitor wrong.
@Suite struct MonitorColorPipelineParityTests {
    @Test func sourceAndProgramGetTheSamePipeline() {
        let media = UUID()
        let info = MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine)
        let resolver = LayerColorResolver(lutProvider: nil) { $0 == media ? info : nil }
        let program = resolver.pipelineBlocking(for: .default, media: media, owner: UUID())
        let source = resolver.pipelineBlocking(for: .default, media: media, owner: media)
        let anonymous = resolver.pipelineBlocking(for: .default, media: media)
        #expect(program != nil, "a detected log source is converted, never shown raw")
        for other in [source, anonymous] {
            #expect(other?.source == program?.source)
            for v in [SIMD3<Float>(0.1, 0.2, 0.3), SIMD3(0.42, 0.42, 0.42), SIMD3(0.9, 0.5, 0.05)] {
                #expect(other?.process(v) == program?.process(v))
            }
        }
    }
}
