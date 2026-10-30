import Foundation
import Synchronization
import Testing
@testable import SQCore

private let gb: UInt64 = 1 << 30

@Suite struct WorkLimitsTests {
    @Test func simulationOnlyLowersRAMAndCores() {
        let real = (mem: 32 * gb, cores: 10)
        let air = MachineResources.current(environment: ["SQ_RAM_GB": "8", "SQ_CORES": "8"],
                                           physicalMemory: real.mem, cores: real.cores)
        #expect(air.memoryBytes == 8 * gb && air.cores == 8 && air.isLowMemory)
        let bigger = MachineResources.current(environment: ["SQ_RAM_GB": "64", "SQ_CORES": "32"],
                                              physicalMemory: real.mem, cores: real.cores)
        #expect(bigger.memoryBytes == real.mem && bigger.cores == real.cores)
        let junk = MachineResources.current(environment: ["SQ_RAM_GB": "x", "SQ_CORES": "0"],
                                            physicalMemory: real.mem, cores: real.cores, isIntel: false)
        #expect(junk == MachineResources(memoryBytes: real.mem, cores: real.cores))
    }

    @Test func eightGigabyteAirGetsNarrowLanes() {
        let air = MachineResources(memoryBytes: 8 * gb, cores: 8).limits
        #expect(air.importProbes == 4)
        #expect(air.posterDecodes == 2)
        #expect(air.waveformReads == 2)
        #expect(air.proxyTranscodes == 1)
        #expect(air.maskTrackDimension == 480 && air.maskTrackChunkSeconds == 0.5)
        let big = MachineResources(memoryBytes: 32 * gb, cores: 10).limits
        #expect(big.maskTrackDimension == 640 && big.maskTrackChunkSeconds == 1)
        // Subject mask: full size on a strong Mac, 640 on a weak one (4 cores), 540 with 8 GB.
        #expect(big.subjectMaskDimension == 960 && air.subjectMaskDimension == 540)
        #expect(MachineResources(memoryBytes: 16 * gb, cores: 4).limits.subjectMaskDimension == 640)
    }

    @Test func bigMacGetsWiderLanesButStaysBounded() {
        let max = MachineResources(memoryBytes: 32 * gb, cores: 10).limits
        #expect(max.importProbes == 5)
        #expect(max.posterDecodes == 4)
        #expect(max.waveformReads == 2)
        #expect(max.proxyTranscodes == 1)
        let studio = MachineResources(memoryBytes: 128 * gb, cores: 24).limits
        #expect(studio.importProbes == 8)
        #expect(studio.posterDecodes == 6)
        #expect(studio.waveformReads == 3)
        #expect(studio.proxyTranscodes == 2)
    }

    @Test func pictureAnalysesRunOneAtATimeOnSmallMacs() {
        // Stabilizer analysis (decode + Vision, ~0.7 cores, 30-60 MB each): one at a time on an 8 GB Mac or <= 4 cores
        // (SQ_CORES=4), two on bigger Macs.
        #expect(MachineResources(memoryBytes: 8 * gb, cores: 8).limits.pictureAnalyses == 1)
        #expect(MachineResources(memoryBytes: 32 * gb, cores: 4).limits.pictureAnalyses == 1)
        #expect(MachineResources(memoryBytes: 32 * gb, cores: 10).limits.pictureAnalyses == 2)
        #expect(MachineResources(memoryBytes: 4 * gb, cores: 2).limits.pictureAnalyses == 1)
    }

    @Test func softwareDecodeIsCappedOnWeakMacs() {
        // Table: (RAM GB, cores, intel) -> (software sessions, preview frame MB, preview decode jobs, reduced decode)
        let table: [(UInt64, Int, Bool, Int, Int, Int, Bool)] = [
            (8, 8, false, 2, 192, 2, true),    // MacBook Air 8 GB
            (4, 2, false, 1, 96, 1, true),     // tiny
            (32, 4, false, 2, 192, 2, true),   // few cores
            (32, 10, true, 2, 192, 2, true),   // Intel
            (16, 10, false, 8, 768, 4, false), // 16 GB Apple silicon: unchanged
            (32, 10, false, 8, 768, 4, false),
            (128, 24, false, 8, 768, 4, false),
        ]
        for (ram, cores, intel, sessions, mb, jobs, reduced) in table {
            let l = MachineResources(memoryBytes: ram * gb, cores: cores, isIntel: intel).limits
            #expect(l.softwareDecoderSessions == sessions, "\(ram) GB \(cores) cores intel \(intel)")
            #expect(l.previewDecoderFrameBytes == mb << 20, "\(ram) GB \(cores) cores intel \(intel)")
            #expect(l.previewDecodeJobs == jobs)
            #expect(l.reducedPreviewDecode == reduced)
        }
    }

    @Test func intelFlagComesFromTheEnvironmentInjection() {
        let m = MachineResources.current(environment: [:], physicalMemory: 32 * gb, cores: 10, isIntel: true)
        #expect(m.isIntel && m.isWeakForDecode)
        #expect(!MachineResources.current(environment: [:], physicalMemory: 32 * gb, cores: 10, isIntel: false).isWeakForDecode)
    }

    @Test func tinyMachineStillMakesProgress() {
        let l = MachineResources(memoryBytes: 4 * gb, cores: 2).limits
        #expect(l.importProbes >= 1 && l.posterDecodes >= 1 && l.waveformReads >= 1 && l.proxyTranscodes == 1)
        #expect(l.importProbes <= 2 && l.posterDecodes == 1)
    }

    @Test func exportDecoderBudgetIsHalvedOnlyOnLowMemoryMacs() {
        // Weak-Mac part 3: an export's decoder sessions and kept frames (all parallel segments together).
        let air = MachineResources(memoryBytes: 8 * gb, cores: 8).limits
        #expect(air.exportDecoderSessions == 4 && air.exportFrameBytes == 384 << 20)
        let tiny = MachineResources(memoryBytes: 4 * gb, cores: 2).limits
        #expect(tiny.exportDecoderSessions == 4 && tiny.exportFrameBytes == 384 << 20)
        // 16 GB and up: unchanged (8 sessions, 768 MB, the DecoderBudget defaults).
        for m in [16 * gb, 32 * gb, 128 * gb] {
            let l = MachineResources(memoryBytes: m, cores: 10).limits
            #expect(l.exportDecoderSessions == 8 && l.exportFrameBytes == 768 << 20)
        }
    }

    @Test func exportCompositorPoolIsSmallOnLowMemoryMacs() {
        // Free intermediate textures of each export compositor (one per parallel segment): was 1 GB everywhere.
        #expect(MachineResources(memoryBytes: 8 * gb, cores: 8).limits.exportIntermediatePoolBytes == 256 << 20)
        #expect(MachineResources(memoryBytes: 4 * gb, cores: 4).limits.exportIntermediatePoolBytes == 256 << 20)
        #expect(MachineResources(memoryBytes: 16 * gb, cores: 10).limits.exportIntermediatePoolBytes == 1 << 30)
        #expect(MachineResources(memoryBytes: 64 * gb, cores: 16).limits.exportIntermediatePoolBytes == 1 << 30)
    }

    @Test func layerDecodesAreBoundedByCoresAndMemory() {
        #expect(MachineResources(memoryBytes: 8 * gb, cores: 8).limits.layerDecodes == 2)
        #expect(MachineResources(memoryBytes: 32 * gb, cores: 10).limits.layerDecodes == 4)
        #expect(MachineResources(memoryBytes: 128 * gb, cores: 24).limits.layerDecodes == 4)
        #expect(MachineResources(memoryBytes: 16 * gb, cores: 4).limits.layerDecodes == 2)
        // One core (SQ_CORES=1): serial, as before.
        #expect(MachineResources(memoryBytes: 8 * gb, cores: 1).limits.layerDecodes == 1)
        #expect(MachineResources(memoryBytes: 32 * gb, cores: 1).limits.layerDecodes == 1)
    }

    @Test func exportRendersAheadOnlyWithMemoryAndCoresToSpare() {
        // A frame in flight holds its compositor intermediates (~400 MB at 4K): off on 8 GB Macs and on one core.
        #expect(!MachineResources(memoryBytes: 8 * gb, cores: 8).limits.exportRenderAhead)
        #expect(MachineResources(memoryBytes: 16 * gb, cores: 8).limits.exportRenderAhead)
        #expect(MachineResources(memoryBytes: 64 * gb, cores: 10).limits.exportRenderAhead)
        #expect(!MachineResources(memoryBytes: 32 * gb, cores: 1).limits.exportRenderAhead)
    }

    @Test func limiterNeverRunsMoreThanItsWidth() async throws {
        let limiter = AsyncLimiter(width: 3)
        let c = Counter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<40 {
                g.addTask {
                    await limiter.run {
                        c.enter()
                        try? await Task.sleep(for: .milliseconds(2))
                        c.leave()
                    }
                }
            }
        }
        #expect(c.peak == 3)
        #expect(limiter.freeSlots == 3)
    }

    @Test func cancelledWaiterGivesUpItsTurn() async throws {
        let limiter = AsyncLimiter(width: 1)
        let gate = AsyncStream<Void>.makeStream()
        let holder = Task { await limiter.run { for await _ in gate.stream { break } } }
        while limiter.freeSlots > 0 { await Task.yield() }
        let waiter = Task { () -> Bool in
            do { try await limiter.runThrowing { }; return true } catch { return false }
        }
        while limiter.waiting == 0 { await Task.yield() }
        waiter.cancel()
        #expect(await waiter.value == false)
        #expect(limiter.waiting == 0)
        gate.continuation.yield(); gate.continuation.finish()
        await holder.value
        #expect(limiter.freeSlots == 1)
    }
}

private final class Counter: Sendable {
    private let s = Mutex((now: 0, peak: 0))
    func enter() { s.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) } }
    func leave() { s.withLock { $0.now -= 1 } }
    var peak: Int { s.withLock { $0.peak } }
}
