import CoreVideo
import Darwin
import Foundation
import SQCore
import Synchronization
import Testing
@testable import SQAnalysis

// Gyroflow analysis lifecycle without the Rust library: a fake libsqgyro built from C function pointers. A path with
// "block" waits in open until the test opens the gate (a long gyro read); "nodata" fails like a file without gyro data.
// Stabilizer bug 2026-10-07: Cancel did nothing, a failed analysis could not be retried, playback restarted a canceled one.

private enum FakeGyro {
    static let gate = DispatchSemaphore(value: 0)
    static let opens = Atomic<Int>(0)
    static let frees = Atomic<Int>(0)
}

private let fakeLibrary = SQGyroLibrary(
    open: { path, info, err, n in
        FakeGyro.opens.add(1, ordering: .relaxed)
        let p = String(cString: path)
        if p.contains("block") { FakeGyro.gate.wait() }
        if p.contains("nodata") {
            if let err { _ = "no gyro data in file".withCString { strncpy(err, $0, n - 1) } }
            return nil
        }
        info?.storeBytes(of: UInt32(64), toByteOffset: 0, as: UInt32.self)
        info?.storeBytes(of: UInt32(36), toByteOffset: 4, as: UInt32.self)
        info?.storeBytes(of: 30.0, toByteOffset: 8, as: Double.self)
        return OpaquePointer(bitPattern: 0x10)
    },
    setParams: { _, _, _, _, _ in },
    recompute: { _ in 1 },
    processPlane: { _, _, _, _, _, _, _, _, _, _ in 0 },
    motionStep: { _, _, _, _, _ in 0 },
    free: { _ in FakeGyro.frees.add(1, ordering: .relaxed) },
    setLensParams: nil)

@Suite(.serialized) struct GyroflowEngineLifecycleTests {
    let options = GyroflowOptions()

    private func until(_ what: String, _ ok: () -> Bool) async throws {
        for _ in 0..<400 where !ok() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ok(), "timed out waiting for \(what)")
    }

    private func frame() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    @Test func runsToReadyAndTellsObservers() async throws {
        let engine = GyroflowEngine(library: fakeLibrary)
        let heard = Atomic<Int>(0)
        engine.addObserver { heard.add(1, ordering: .relaxed) }
        engine.prepare(path: "/fake/ok.mp4", options: options)
        try await until("ready") { engine.analysisState(path: "/fake/ok.mp4", options: options) == .ready }
        try await until("observers") { heard.load(ordering: .relaxed) >= 2 }
    }

    @Test func cancelIsIdleAtOnceDropsTheResultAndPlaybackDoesNotRestartIt() async throws {
        let engine = GyroflowEngine(library: fakeLibrary)
        let heard = Atomic<Int>(0)
        engine.addObserver { heard.add(1, ordering: .relaxed) }
        let path = "/fake/block-cancel.mp4"
        let freesBefore = FakeGyro.frees.load(ordering: .relaxed)
        let opensBefore = FakeGyro.opens.load(ordering: .relaxed)
        engine.prepare(path: path, options: options)
        #expect(engine.analysisState(path: path, options: options) == .analysing(0))
        try await until("open started") { FakeGyro.opens.load(ordering: .relaxed) > opensBefore }

        engine.cancel(path: path, options: options)
        #expect(engine.analysisState(path: path, options: options) == .idle)
        // Playback drawing a frame does not start it again.
        #expect(engine.warp(frame(), path: path, options: options, timestampUS: 0, wait: false) == nil)
        #expect(engine.analysisState(path: path, options: options) == .idle)
        try await until("cancel heard") { heard.load(ordering: .relaxed) >= 2 }

        // The read finishes late: its handle is freed and the state stays idle.
        FakeGyro.gate.signal()
        try await until("late result freed") { FakeGyro.frees.load(ordering: .relaxed) > freesBefore }
        #expect(engine.analysisState(path: path, options: options) == .idle)

        // Analyze again starts a new run.
        engine.prepare(path: path, options: options)
        #expect(engine.analysisState(path: path, options: options) == .analysing(0))
        FakeGyro.gate.signal()
        try await until("ready after restart") { engine.analysisState(path: path, options: options) == .ready }
        // A finished analysis is not dropped by Cancel.
        engine.cancel(path: path, options: options)
        #expect(engine.analysisState(path: path, options: options) == .ready)
    }

    @Test func aFileWithoutGyroDataFailsWithTheReasonAndCanBeTriedAgain() async throws {
        let engine = GyroflowEngine(library: fakeLibrary)
        let path = "/fake/nodata.mp4"
        engine.prepare(path: path, options: options)
        try await until("failed") { engine.analysisState(path: path, options: options) == .failed(GyroStabilization.noGyroDataReason) }
        let opens = FakeGyro.opens.load(ordering: .relaxed)
        engine.prepare(path: path, options: options)
        try await until("tried again") { FakeGyro.opens.load(ordering: .relaxed) > opens }
        try await until("failed again") { engine.analysisState(path: path, options: options) == .failed(GyroStabilization.noGyroDataReason) }
    }

    @Test func exportStillWaitsForACancelledAnalysis() async throws {
        let engine = GyroflowEngine(library: fakeLibrary)
        let path = "/fake/block-export.mp4"
        let opensBefore = FakeGyro.opens.load(ordering: .relaxed)
        engine.prepare(path: path, options: options)
        // Cancel only once the read blocks: a run canceled before open never consumes the signal, and the stray
        // token on the shared gate would let a later test's "blocking" open through.
        try await until("first read started") { FakeGyro.opens.load(ordering: .relaxed) > opensBefore }
        engine.cancel(path: path, options: options)
        FakeGyro.gate.signal()          // the canceled run's read
        // Export asks with wait: the analysis runs again (the fake warp itself returns nil).
        let pb = frame()
        let done = Atomic<Bool>(false)
        DispatchQueue.global().async {
            _ = engine.warp(pb, path: path, options: options, timestampUS: 0, wait: true)
            done.store(true, ordering: .relaxed)
        }
        try await until("export run started") { engine.analysisState(path: path, options: options) != .idle }
        FakeGyro.gate.signal()
        try await until("export done") { done.load(ordering: .relaxed) }
        #expect(engine.analysisState(path: path, options: options) == .ready)
    }

    /// A slider drag makes an option set per tick: only the running job and the newest one are smoothed.
    @Test func aDragSmoothsOnlyTheRunningAndTheNewestOptionSet() async throws {
        let engine = GyroflowEngine(library: fakeLibrary)
        let path = "/fake/block-drag.mp4"
        func opts(_ z: Double) -> GyroflowOptions { var o = GyroflowOptions(); o.zoomLimit = z; return o }
        let opensBefore = FakeGyro.opens.load(ordering: .relaxed)
        engine.prepare(path: path, options: opts(110))
        try await until("first open started") { FakeGyro.opens.load(ordering: .relaxed) > opensBefore }
        for z in [120.0, 130, 140, 150] { _ = engine.warp(frame(), path: path, options: opts(z), timestampUS: 0, wait: false) }
        FakeGyro.gate.signal()          // the first read finishes; the newest one reads next
        try await until("newest waits in open") { FakeGyro.opens.load(ordering: .relaxed) > opensBefore + 1 }
        FakeGyro.gate.signal()
        try await until("newest ready") { engine.analysisState(path: path, options: opts(150)) == .ready }
        #expect(engine.analysisState(path: path, options: opts(110)) == .ready)
        for z in [120.0, 130, 140] { #expect(engine.analysisState(path: path, options: opts(z)) == .idle) }
        #expect(FakeGyro.opens.load(ordering: .relaxed) == opensBefore + 2)
    }
}
