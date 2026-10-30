import AVFoundation
import CoreVideo
import Foundation
import SQCore
import Synchronization
import Testing
@testable import SQAnalysis

// The Vision compute fallback (Neural Engine -> CPU) per request. Before, a process-wide switch: one failure was final,
// and the second of two concurrent failures failed without its CPU try.

private struct Boom: Error {}

@Suite struct ComputeFallbackTests {
    @Test func oneFailureFallsBackAndTheNextRequestWorks() throws {
        let f = ComputeFallback(name: "test", retryAfter: 3)
        var calls: [Bool] = []
        // The default devices fail once: that request is answered by the CPU.
        let first = try f.run { cpu -> String in
            calls.append(cpu)
            if !cpu { throw Boom() }
            return "cpu"
        }
        #expect(first == "cpu" && calls == [false, true])
        #expect(f.prefersCPU)
        // The next requests work (CPU first, three times), then the default devices are tried again.
        calls = []
        for _ in 0..<4 { _ = try f.run { cpu -> Int in calls.append(cpu); return 1 } }
        #expect(calls == [true, true, true, false])
        #expect(!f.prefersCPU)
    }

    @Test func aCPUFailureDoesNotPoisonLaterRequests() throws {
        let f = ComputeFallback(name: "test", retryAfter: 100)
        _ = try f.run { cpu -> Int in if !cpu { throw Boom() }; return 1 }
        #expect(f.prefersCPU)
        // CPU first now, and the CPU fails: the same request goes to the default devices and works.
        var calls: [Bool] = []
        let r = try f.run { cpu -> String in
            calls.append(cpu)
            if cpu { throw Boom() }
            return "default"
        }
        #expect(r == "default" && calls == [true, false])
        #expect(!f.prefersCPU)
        // Both ways fail for one request: it throws, and the request after it runs as if nothing had happened.
        #expect(throws: Boom.self) { try f.run { _ -> Int in throw Boom() } }
        #expect(!f.prefersCPU)
        calls = []
        let after = try f.run { cpu -> Int in calls.append(cpu); return 7 }
        #expect(after == 7 && calls == [false])
    }

    @Test func concurrentFailuresEachGetTheirOwnCPUTry() async throws {
        let f = ComputeFallback(name: "test", retryAfter: 5)
        let n = 64
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<n {
                group.addTask {
                    // The default devices always fail, the CPU always works.
                    (try? f.run { cpu -> Bool in
                        if !cpu { throw Boom() }
                        return true
                    }) ?? false
                }
            }
            var out: [Bool] = []
            for await r in group { out.append(r) }
            return out
        }
        #expect(results.count == n && results.allSatisfy { $0 })
    }

    /// A segmenter built on the fallback: its first call fails on the default devices, every frame is still answered.
    @Test func aSegmenterOnTheFallbackAnswersEveryFrame() throws {
        final class Flaky: InstanceSegmenting, Sendable {
            let fallback = ComputeFallback(name: "test", retryAfter: 2)
            let defaultCalls = Mutex(0)
            func segment(_ frame: CVPixelBuffer) throws -> InstanceFrame? {
                try fallback.run { cpu in
                    if !cpu, defaultCalls.withLock({ $0 += 1; return $0 }) == 1 { throw Boom() }
                    return InstanceFrame(labels: InstanceLabels(width: 2, height: 2, labels: [1, 0, 0, 0]))
                }
            }
        }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        let frame = try #require(pb)
        let s = Flaky()
        for _ in 0..<6 { #expect(try s.segment(frame) != nil) }
    }
}

@Suite struct MagicTrackStopTests {
    /// Cancels the task that runs it while a frame is segmented.
    final class StoppingSegmenter: InstanceSegmenting, Sendable {
        let inner = MagicMaskTests.PatchSegmenter()
        let calls = Mutex(0)
        let stopAt: Int
        let stop: @Sendable () -> Void
        init(stopAt: Int, stop: @escaping @Sendable () -> Void) { self.stopAt = stopAt; self.stop = stop }
        func segment(_ pb: CVPixelBuffer) throws -> InstanceFrame? {
            if calls.withLock({ $0 += 1; return $0 }) == stopAt { stop() }
            return try inner.segment(pb)
        }
    }

    /// A run stopped while a frame is on its way (its mask was removed) writes nothing more: not that frame, none after.
    @Test func aStoppedTrackWritesNothingMore() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let task = Mutex<Task<Void, Never>?>(nil)
        let segmenter = StoppingSegmenter(stopAt: 5) { task.withLock { $0?.cancel() } }
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: segmenter)
        let click = [MagicPoint(position: Vec2(80.0 / 320, 90.0 / 180), subtract: false, sourceTime: .zero)]
        let gate = AsyncStream<Void>.makeStream()
        let t = Task {
            for await _ in gate.stream { break }       // starts once the task is stored
            do {
                _ = try await tracker.track(key: "p", points: click, from: 0, to: 23.0 / 24, store: store)
                Issue.record("the stopped track ran to its end")
            } catch is CancellationError {
            } catch { Issue.record("unexpected error \(error)") }
        }
        task.withLock { $0 = t }
        gate.continuation.yield()
        await t.value
        #expect(store.times(key: "p").count == 4)
        #expect(segmenter.calls.withLock { $0 } == 5)
    }

    /// Notes the queue each frame is segmented on.
    final class WhereSegmenter: InstanceSegmenting, Sendable {
        let inner = MagicMaskTests.PatchSegmenter()
        let queues = Mutex<[String]>([])
        func segment(_ pb: CVPixelBuffer) throws -> InstanceFrame? {
            queues.withLock { $0.append(String(cString: __dispatch_queue_get_label(nil))) }
            return try inner.segment(pb)
        }
    }

    /// The shown frame's read and Vision request block: they run on the one frame thread, not on the cooperative pool
    /// (a call that hangs there took a pool thread per retry). After a call was given up the work goes on, on a fresh one.
    @Test func theShownFrameIsSegmentedOnItsOwnThread() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let segmenter = WhereSegmenter()
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: segmenter)
        #expect(try await tracker.segment(at: 0) != nil)
        MagicMaskTracker.abandonStuckFrameWork()
        #expect(try await tracker.segment(at: 0) != nil)
        #expect(segmenter.queues.withLock { $0 } == ["sq.subject.frame", "sq.subject.frame"])
    }

    /// A read that hands out no frame is an error, not "this frame shows nothing".
    @Test func aReadWithoutAFrameIsAnError() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
        await #expect(throws: SubjectFrameError.noFrame(100)) { _ = try await tracker.segment(at: 100) }
    }

    /// A run whose mask was removed does not write its mattes file again when it ends; a run stopped by the user does.
    @Test func aTrackThatMayNotKeepItsFramesWritesNoFile() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: dir) }
        let store = MagicMatteStore(directory: dir)
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
        let click = [MagicPoint(position: Vec2(80.0 / 320, 90.0 / 180), subtract: false, sourceTime: .zero)]
        _ = try await tracker.track(key: "gone", points: click, from: 0, to: 5.0 / 24, store: store, keep: { false })
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("gone.sqmatte").path))
        _ = try await tracker.track(key: "kept", points: click, from: 0, to: 5.0 / 24, store: store, keep: { true })
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("kept.sqmatte").path))
    }

    /// Stopped while a frame is narrowed (`refine`): neither that frame's followed matte nor its narrowed one is stored.
    @Test func aTrackStoppedWhileAFrameIsNarrowedStoresNothingOfThatFrame() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MagicMatteStore(directory: nil)
        let task = Mutex<Task<Void, Never>?>(nil)
        let narrowed = Mutex(0)
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
        let click = [MagicPoint(position: Vec2(80.0 / 320, 90.0 / 180), subtract: false, sourceTime: .zero)]
        let gate = AsyncStream<Void>.makeStream()
        let t = Task {
            for await _ in gate.stream { break }
            do {
                _ = try await tracker.track(key: "p", points: click, from: 0, to: 23.0 / 24, store: store, refinedKey: "r",
                                            refine: { _, _, m in
                    if narrowed.withLock({ $0 += 1; return $0 }) == 3 { task.withLock { $0?.cancel() } }
                    return m
                })
                Issue.record("the stopped track ran to its end")
            } catch is CancellationError {
            } catch { Issue.record("unexpected error \(error)") }
        }
        task.withLock { $0 = t }
        gate.continuation.yield()
        await t.value
        #expect(store.times(key: "p").count == 2 && store.times(key: "r").count == 2)
    }

    /// What a hook sees of the reads that hang.
    final class Hung: @unchecked Sendable {
        private let lock = NSLock()
        private var readers: [AVAssetReader] = []
        private var released = false
        var count: Int { lock.withLock { readers.count } }
        var canceled: Int { lock.withLock { readers.filter { $0.status == .cancelled }.count } }
        func release() { lock.withLock { released = true } }
        /// A decoder that never hands out its frame: returns only when the reader is canceled (or the test is over).
        func hang(_ r: AVAssetReader) {
            lock.withLock { readers.append(r) }
            for _ in 0..<12_000 {
                if lock.withLock({ released }) || r.status != .reading { return }
                usleep(5_000)
            }
        }
        /// Blocks the calling thread (never suspends: the test must go on even when the pool has no thread left).
        static func wait(seconds: Double, until done: () -> Bool) -> Bool {
            for _ in 0..<Int(seconds * 200) { if done() { return true }; usleep(5_000) }
            return done()
        }
    }

    /// A read that hangs in the decoder never reaches a cancellation check of its own: canceling its task cancels the
    /// reader, on the frame lane (track, precompute) and on the frame thread (hover) alike.
    @Test func cancelingTheTaskCancelsAReadThatHangs() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
        _ = try await tracker.segment(at: 0)            // the file's first frame time is known: the hook is the next stop
        for hover in [false, true] {
            let hung = Hung()
            let task = Task {
                try await FrameReader.$onReader.withValue({ hung.hang($0) }) {
                    if hover { _ = try await tracker.segment(at: 0.5) } else {
                        try await FrameReader(url: url, maxDimension: 320).forEach(from: 0, to: 1) { _, _ in true }
                    }
                }
            }
            #expect(Hung.wait(seconds: 30) { hung.count == 1 })
            task.cancel()
            #expect(Hung.wait(seconds: 1) { hung.canceled == 1 }, "hover \(hover)")
            await #expect(throws: CancellationError.self) { try await task.value }
            hung.release()
        }
    }

    /// The root cause of "Magic is dead in the whole program" (2026-10-09): every frame request read its file on a
    /// thread of the cooperative pool, and one pool's worth of reads that hang left no thread for any task. Twice as
    /// many reads as cores hang here (hover requests and track-style reads): other tasks still run, and once the
    /// requests are given up the next frame is segmented.
    @Test func readsThatHangLeaveThePoolFree() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let tracker = MagicMaskTracker(url: url, limits: .current, segmenter: MagicMaskTests.PatchSegmenter())
        _ = try await tracker.segment(at: 0)
        let hung = Hung()
        defer { hung.release() }
        let n = 2 * ProcessInfo.processInfo.activeProcessorCount
        var tasks: [Task<Void, Never>] = []
        for i in 0..<n {
            tasks.append(Task.detached {
                await FrameReader.$onReader.withValue({ hung.hang($0) }) {
                    if i % 2 == 0 { _ = try? await tracker.segment(at: Double(i % 24) / 24) } else {
                        try? await FrameReader(url: url, maxDimension: 320).forEach(from: 0, to: 1) { _, _ in true }
                    }
                }
            })
        }
        // Reads hang on the frame thread and on every thread of the frame lane.
        #expect(Hung.wait(seconds: 30) { hung.count >= 2 })
        let ran = Mutex(false)
        Task.detached { ran.withLock { $0 = true } }
        #expect(Hung.wait(seconds: 5) { ran.withLock { $0 } }, "no pool thread left for a trivial task")
        // Given up (the session's deadline, Stop): the readers are canceled, their threads come back.
        for t in tasks { t.cancel() }
        let again = Mutex(false)
        let next = Task.detached {
            if (try? await tracker.segment(at: 0)) != nil { again.withLock { $0 = true } }
        }
        #expect(Hung.wait(seconds: 20) { again.withLock { $0 } }, "the next frame was not segmented")
        next.cancel()
        for t in tasks { await t.value }
    }
}

@Suite struct ReadStopRaceTests {
    /// `cancelReading` during `copyNextSampleBuffer` crashed MediaToolbox (2026-10-17). A stop at every moment of a scan,
    /// many times over, ends it with a cancellation (or lets it finish) and never crashes.
    @Test func stoppingAScanAtAnyMomentIsSafe() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        for i in 0..<40 {
            let reader = FrameReader(url: url, maxDimension: 320)
            let plan = try await reader.plan()
            let stopper = Thread {
                usleep(UInt32(i % 10) * 1_500)
                reader.stop.stop()
            }
            stopper.start()
            do {
                for _ in 0..<3 { try reader.read(plan, from: 0, to: 1) { _, _ in true } }
            } catch is CancellationError {}
            #expect(reader.stop.isStopped)
        }
    }

    /// A stop that arrives while a copy runs never cancels the reader under it, however long the copy takes (a loaded
    /// machine made one outlast the old 2 s grace and crashed MediaToolbox). The cancel comes once the copy is over.
    @Test func aStopDuringACopyWaitsForTheCopy() async throws {
        let url = try await MaskTrackerTests().writeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        nonisolated(unsafe) let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        #expect(reader.startReading())
        let stop = ReadStop()
        stop.attach(reader)
        let during = Mutex<AVAssetReader.Status?>(nil)
        stop.duringCopy = {
            stop.stop()
            usleep(600_000)
            during.withLock { $0 = reader.status }
        }
        _ = stop.copy(out)
        #expect(during.withLock { $0 } == .reading)
        stop.release(reader)
        #expect(reader.status == .cancelled)
        #expect(stop.copy(out) == nil)
    }
}
