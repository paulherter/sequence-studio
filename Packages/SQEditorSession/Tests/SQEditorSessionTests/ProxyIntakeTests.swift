import Foundation
import Synchronization
import Testing
import SQCore
import SQMedia
import SQProxy
@testable import SQEditorSession

/// Blocks every transcode until `open()`; records starts and cancellations (portable: no CoreMedia).
final class IntakeGateTranscoder: ProxyTranscoding {
    let started = Mutex<[URL]>([])
    let cancelled = Mutex(0)
    let isOpen = Mutex(false)
    func open() { isOpen.withLock { $0 = true } }
    func transcode(source: URL, kind: ProxyKind, destination: URL, timeRange: TimeRange?,
                   progress: @Sendable @escaping (Double) -> Void) async throws -> TranscodeOutput {
        started.withLock { $0.append(source) }
        while !isOpen.withLock({ $0 }) {
            if Task.isCancelled { cancelled.withLock { $0 += 1 }; throw CancellationError() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        try Data("proxy".utf8).write(to: destination)
        return TranscodeOutput(dimensions: ProxyDimensions(width: 16, height: 16), sourceDuration: Time(1, 1))
    }
}

/// The portable proxy intake (Windows): media is probed when the session syncs (import, open), not when a monitor first
/// shows it; the Auto rule queues heavy sources; Off queues nothing; removed media cancels its job.
@Suite(.serialized) @MainActor struct ProxyIntakeTests {
    struct Rig {
        let dir: URL
        let intake: ProxyIntake
        let transcoder: IntakeGateTranscoder
        let settings: ProxySettingsStore
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    final class Probed: Sendable { let names = Mutex<[String]>([]) }

    nonisolated static let video = VideoTrackInfo(width: 3840, height: 2160, codec: "hevc", bitDepth: 10, chroma: "4:2:0",
                                      nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)

    private func rig(mode: ProxyMode = .auto, canMatch: Bool = true) async throws -> (Rig, Probed) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-intake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = ProxyCache(directory: dir.appendingPathComponent("cache"))
        let transcoder = IntakeGateTranscoder()
        let queue = ProxyQueue(cache: cache, transcoder: transcoder)
        await queue.start()
        let settings = ProxySettingsStore(defaults: UserDefaults(suiteName: "sq-intake-\(UUID().uuidString)")!)
        settings.setMode(mode, project: nil)
        let probed = Probed()
        let intake = ProxyIntake(provider: ProxyProvider(cache: cache, interlaced: { _ in false }), queue: queue,
                                 settings: settings,
                                 machine: { MachineProfile(memoryBytes: 32 << 30, cores: 16, isAppleSilicon: $0) },
                                 probe: { url in
                                     probed.names.withLock { $0.append(url.lastPathComponent) }
                                     return ProxySourceProbe(seek: SourceSeekInfo(codecFourCC: "hvc1", maxSyncDistance: 250),
                                                             video: Self.video, hardwareDecode: false, canMatch: canMatch)
                                 })
        return (Rig(dir: dir, intake: intake, transcoder: transcoder, settings: settings), probed)
    }

    private func source(_ r: Rig, _ name: String, seed: UInt8 = 1) throws -> MediaRef {
        let u = r.dir.appendingPathComponent(name)
        var d = Data(count: 50_000)
        for i in 0..<d.count { d[i] = UInt8(truncatingIfNeeded: i &* 31) ^ seed }
        try d.write(to: u)
        return MediaRef(name: name, path: u.path, fingerprint: MediaFingerprint(size: 50_000),
                        info: MediaInfo(duration: Time(100, 1), video: Self.video))
    }

    private func eventually(_ what: String, _ ok: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(60)
        while !ok(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(ok(), "\(what)")
    }

    @Test func syncProbesEachFileOnceAndQueuesHeavySources() async throws {
        let (r, probed) = try await rig()
        defer { r.cleanup() }
        let a = try source(r, "A.mp4"), b = try source(r, "B.mp4", seed: 2)
        r.intake.sync([a, b], projectID: nil, activeTimeline: nil)
        await eventually("the first source reaches the transcoder (one job at a time)") { r.transcoder.started.withLock { $0.count } == 1 }
        await eventually("both probed") { probed.names.withLock { $0.count } == 2 }
        #expect(Set(probed.names.withLock { $0 }) == ["A.mp4", "B.mp4"])
        if case .needsProxy = r.intake.decisions[a.path] {} else { Issue.record("A: \(String(describing: r.intake.decisions[a.path]))") }
        // A second sync with the same files probes nothing again.
        r.intake.sync([a, b], projectID: nil, activeTimeline: nil)
        r.transcoder.open()
        await r.intake.settle()
        #expect(probed.names.withLock { $0.count } == 2)
        #expect(r.transcoder.started.withLock { $0.count } == 2)
        #expect(r.intake.provider.cachedLookup(for: URL(fileURLWithPath: a.path), preferring: ProxyProvider.scrubPreference) != nil)
    }

    @Test func offModeProbesButQueuesNothing() async throws {
        let (r, probed) = try await rig(mode: .off)
        defer { r.cleanup() }
        let a = try source(r, "A.mp4")
        r.intake.sync([a], projectID: nil, activeTimeline: nil)
        await r.intake.settle()
        #expect(probed.names.withLock { $0 } == ["A.mp4"])
        #expect(r.intake.decisions[a.path] == .skip(.disabled))
        #expect(r.transcoder.started.withLock { $0.isEmpty })
    }

    @Test func sourcesWhoseFramesCannotMatchGetNoProxy() async throws {
        let (r, _) = try await rig(canMatch: false)
        defer { r.cleanup() }
        r.intake.sync([try source(r, "EDIT.mov")], projectID: nil, activeTimeline: nil)
        await r.intake.settle()
        #expect(r.transcoder.started.withLock { $0.isEmpty })
    }

    @Test func removedMediaCancelsItsJobAndAChangedFileIsProbedAgain() async throws {
        let (r, probed) = try await rig()
        defer { r.cleanup() }
        let a = try source(r, "A.mp4")
        r.intake.sync([a], projectID: nil, activeTimeline: nil)
        await eventually("A is transcoding") { r.transcoder.started.withLock { $0.count } == 1 }
        r.intake.sync([], projectID: nil, activeTimeline: nil)
        await eventually("the job is canceled") { r.transcoder.cancelled.withLock { $0 } == 1 }
        await r.intake.settle()
        // Back with other bytes (another size): probed again.
        var d = Data(count: 60_000); d[0] = 9
        try d.write(to: URL(fileURLWithPath: a.path))
        r.intake.sync([a], projectID: nil, activeTimeline: nil)
        await eventually("A is probed again") { probed.names.withLock { $0.count } == 2 }
        r.transcoder.open()
        await r.intake.settle()
    }

    /// Preferences > Cache Folder applies at once (Windows): the old queue's job is canceled, the last synced media is
    /// looked at again in the new folder and its missing proxy is made there.
    @Test func retargetMovesTheIntakeToTheNewCacheFolder() async throws {
        let (r, probed) = try await rig()
        defer { r.cleanup() }
        let a = try source(r, "A.mp4")
        r.intake.sync([a], projectID: nil, activeTimeline: nil)
        await eventually("A is transcoding into the first folder") { r.transcoder.started.withLock { $0.count } == 1 }
        let cache2 = ProxyCache(directory: r.dir.appendingPathComponent("cache2"))
        let transcoder2 = IntakeGateTranscoder()
        let queue2 = ProxyQueue(cache: cache2, transcoder: transcoder2)
        await queue2.start()
        let provider2 = ProxyProvider(cache: cache2, interlaced: { _ in false })
        r.intake.retarget(provider: provider2, queue: queue2)
        #expect(r.intake.provider === provider2)
        await eventually("the first folder's job is canceled") { r.transcoder.cancelled.withLock { $0 } == 1 }
        await eventually("A is transcoding into the new folder") { transcoder2.started.withLock { $0.count } == 1 }
        transcoder2.open()
        await r.intake.settle()
        #expect(probed.names.withLock { $0.count } == 2)
        #expect(provider2.cachedLookup(for: URL(fileURLWithPath: a.path), preferring: ProxyProvider.scrubPreference)?
            .url.deletingLastPathComponent().lastPathComponent == "cache2")
        #expect(r.transcoder.started.withLock { $0.count } == 1)
    }
}
