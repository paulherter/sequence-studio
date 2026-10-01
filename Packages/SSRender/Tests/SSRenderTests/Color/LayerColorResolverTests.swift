import Foundation
import Testing
import Synchronization
import SSCore
@testable import SSRender

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
        let r = make()
        let warmed = Mutex(0)
        r.setOnWarmed { warmed.withLock { $0 += 1 } }
        _ = r.pipeline(for: .default, media: slogID)
        await r.waitUntilIdle()
        #expect(warmed.withLock { $0 } == 1)
        #expect(r.pipeline(for: .default, media: slogID)?.source == .sLog3SGamut3Cine)
        var c = ClipColor.default; c.effects[0].basic.tint = 10
        let during = r.pipeline(for: c, media: slogID)                    // not built yet: previous pipeline
        #expect(during?.source == .sLog3SGamut3Cine && during?.ops.count == 1)
        await r.waitUntilIdle()
        #expect(r.pipeline(for: c, media: slogID)?.ops.count == 2)
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
}
