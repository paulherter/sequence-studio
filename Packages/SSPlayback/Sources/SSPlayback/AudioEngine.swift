@preconcurrency import AVFoundation
import CoreAudio
import Darwin
import Foundation
import Synchronization
import SSCore
import SSMedia

public enum AudioEngineError: Error, Sendable, Equatable {
    case noOutputDevice
    case startFailed(String)
}

/// `mach_absolute_time` in nanoseconds (the host time base of `AudioRenderStamp`). Real-time safe.
@inline(__always) func hostNanosecondsNow() -> Int64 {
    let tb = hostTimebase
    return Int64(Int128(mach_absolute_time()) * Int128(tb.numer) / Int128(tb.denom))
}
private let hostTimebase: (numer: UInt32, denom: UInt32) = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (info.numer, info.denom)
}()

/// Real-time side of `AudioEngine`, separated from AVAudioEngine so it can be tested headless.
///
/// `render` runs on the Core Audio thread: it only copies from the ring and touches atomics (no locks, no allocation).
/// - Playing: pops from the ring; a short pop is silence (zero-filled by the ring) and counts one underrun.
/// - Priming (after `beginPriming(generation:)`): until the feeder has flushed for THAT generation (lock-free
///   `FlushGeneration`) and the ring holds a whole render call, the old material keeps playing if output was running (so
///   the ring's crossfade has a tail), otherwise silence. Shortage while priming is not an underrun. A newer
///   `beginPriming` during priming is never lost (sequence counter, the render thread only records what it completed).
/// - Stopped: the next `fadeFrames` frames are popped with a raised-cosine fade-out, then silence (ring not consumed).
/// Every consuming call publishes an `AudioRenderStamp` (seqlock) for the clock's interpolation and watchdog.
final class AudioRenderCore: @unchecked Sendable {
    let ring: RingBuffer
    let flushGeneration: FlushGeneration
    let fadeFrames: Int
    let playing = Atomic<Bool>(false)
    private let primeSeq = Atomic<Int>(0)
    private let primeTarget = Atomic<Int>(0)
    private let underruns = Atomic<Int>(0)
    private let ramp: UnsafeMutablePointer<Float>       // 0 -> 1
    // Stamp seqlock (odd = render thread writing).
    private let stampSeq = Atomic<Int>(0)
    private let stampFrames = Atomic<Int64>(0)
    private let stampQuantum = Atomic<Int64>(0)
    private let stampNanos = Atomic<Int64>(0)
    // Render thread only.
    private var primedSeq = 0
    private var wasPlaying = false
    private var fadeOutPos: Int

    init(ring: RingBuffer, flushGeneration: FlushGeneration, fadeFrames: Int = 240) {
        self.ring = ring; self.flushGeneration = flushGeneration; self.fadeFrames = fadeFrames
        let n = max(1, fadeFrames)
        ramp = .allocate(capacity: n)
        for k in 0..<n { ramp[k] = Float(0.5 - 0.5 * cos(Double.pi * (Double(k) + 0.5) / Double(n))) }
        fadeOutPos = fadeFrames
    }
    deinit { ramp.deallocate() }

    var underrunCount: Int { underruns.load(ordering: .relaxed) }

    /// Call after the feeder seek that returned `generation`: output waits for that generation's flush.
    func beginPriming(generation: Int) {
        primeTarget.store(generation, ordering: .releasing)
        primeSeq.add(1, ordering: .releasing)
    }

    var lastRender: AudioRenderStamp {
        while true {
            let s1 = stampSeq.load(ordering: .acquiring)
            if s1 & 1 == 1 { continue }
            let st = AudioRenderStamp(frames: stampFrames.load(ordering: .relaxed), quantum: stampQuantum.load(ordering: .relaxed),
                                      hostNanos: stampNanos.load(ordering: .relaxed))
            atomicMemoryFence(ordering: .acquiring)
            if stampSeq.load(ordering: .relaxed) == s1 { return st }
        }
    }

    /// Fills `count` frames. Returns true when the output is pure silence.
    func render(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count: Int, hostNanos: Int64) -> Bool {
        guard playing.load(ordering: .acquiring) else {
            if wasPlaying { wasPlaying = false; fadeOutPos = 0 }
            guard fadeOutPos < fadeFrames else { return silence(l, r, count) }
            let n = min(count, fadeFrames - fadeOutPos)
            let got = ring.pop(left: l, right: r, count: n)
            for j in 0..<n { let g = 1 - ramp[fadeOutPos + j]; l[j] *= g; r[j] *= g }
            fadeOutPos += n
            if n < count { (l + n).update(repeating: 0, count: count - n); (r + n).update(repeating: 0, count: count - n) }
            stamp(got, hostNanos)
            return false
        }
        let seq = primeSeq.load(ordering: .acquiring)
        if seq != primedSeq {
            let target = primeTarget.load(ordering: .acquiring)
            if flushGeneration.value.load(ordering: .acquiring) < target {   // feeder has not flushed for the seek yet
                guard wasPlaying else { return silence(l, r, count) }
                stamp(ring.pop(left: l, right: r, count: count), hostNanos)    // old material, shortage not counted
                return false
            }
            guard ring.availableToRead >= count else { return silence(l, r, count) }
            primedSeq = seq
        }
        wasPlaying = true
        fadeOutPos = fadeFrames
        let got = ring.pop(left: l, right: r, count: count)
        if got < count { underruns.add(1, ordering: .relaxed) }
        stamp(got, hostNanos)
        return false
    }

    private func stamp(_ n: Int, _ nanos: Int64) {
        guard n > 0 else { return }
        stampSeq.add(1, ordering: .acquiringAndReleasing)
        stampFrames.store(ring.consumedFrames, ordering: .relaxed)
        stampQuantum.store(Int64(n), ordering: .relaxed)
        stampNanos.store(nanos, ordering: .relaxed)
        stampSeq.add(1, ordering: .releasing)
    }

    private func silence(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ count: Int) -> Bool {
        l.update(repeating: 0, count: count); r.update(repeating: 0, count: count)
        return true
    }
}

/// Peak/RMS of the last metered buffer, written by the tap thread, read by the UI.
final class AudioMeterStore: Sendable {
    private let value = Mutex(AudioMeterSnapshot())
    var snapshot: AudioMeterSnapshot { value.withLock { $0 } }

    func measure(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, count: Int) {
        func level(_ p: UnsafePointer<Float>) -> AudioMeterLevel {
            var peak: Float = 0, sum: Float = 0
            for i in 0..<count { let v = p[i]; peak = max(peak, abs(v)); sum += v * v }
            return AudioMeterLevel(peak: peak, rms: count > 0 ? (sum / Float(count)).squareRoot() : 0)
        }
        let a = level(l), b = level(r)
        value.withLock { s in s.left = a; s.right = b; s.sequence += 1 }
    }
}

/// Timeline audio output (ARCHITECTURE §7): `AudioFeeder` (own thread) -> `RingBuffer` (5 ms flush fades) ->
/// `AVAudioSourceNode` (render block copies from the ring only) -> `AVAudioUnitTimePitch` (rate = |speed|, pitch
/// preserved, bypassed at 1x) -> `mainMixerNode` -> output. A tap on the source node feeds the meter.
///
/// Mixer rate is fixed at 48 kHz (feeder precondition); the main mixer converts to the device rate.
/// Call `prepare()` before playing (starts the hardware and the feeder thread; throws without an output device; may
/// block while the hardware starts). The hardware keeps running while paused (instant start, silence rendered);
/// `shutdown()` or deinit stops it. A device configuration change restarts the engine, re-measures the latency and
/// calls the restart handler (the clock re-seeks at its position).
///
/// Latency (`outputLatency`) = device presentation latency (measured at prepare / configuration change) + TimePitch
/// latency re-read at every `setRate` (it depends on bypass and rate).
public final class AudioEngine: AudioPlaying, @unchecked Sendable {
    public static let ringCapacity = 1 << 16          // 1.36 s at 1x, 170 ms at 8x
    public let sampleRate = 48_000
    public let ring: RingBuffer
    public let feeder: AudioFeeder
    let core: AudioRenderCore
    private let meter = AudioMeterStore()
    private let deviceLatencyFrames = Atomic<Int64>(0)
    private let pitchLatencyFrames = Atomic<Int64>(0)
    private let reverse = Atomic<Bool>(false)
    private let restartHandler = Mutex<(@Sendable () -> Void)?>(nil)
    private let configurationChanges = Atomic<Int>(0)

    /// TimePitch parameters: own short lock so `setRate` never waits for `prepare`'s hardware start.
    private let timePitch = AVAudioUnitTimePitch()
    private let pitchLock = Mutex(())

    private struct Graph {
        let engine = AVAudioEngine()
        let source: AVAudioSourceNode
        let format: AVAudioFormat
        var prepared = false
        var observer: (any NSObjectProtocol)?
    }
    private let graph: Mutex<Graph>

    /// `media.audio(for:)` provides the sources (expected at 48 kHz, e.g. `AssetAudioSource.open(url:sampleRate: 48_000)`).
    public convenience init(media: any MediaResolver) {
        self.init(resolver: { try media.audio(for: $0) })
    }

    public init(resolver: @escaping AudioFeeder.Resolver) {
        ring = RingBuffer(capacity: Self.ringCapacity, fadeFrames: 240)
        feeder = AudioFeeder(timeline: Timeline(name: "", frameDuration: Time(1, 30)), ring: ring, sampleRate: 48_000,
                             blockFrames: 1024, resolver: resolver)
        let core = AudioRenderCore(ring: ring, flushGeneration: feeder.flushGeneration, fadeFrames: 240)
        self.core = core
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            preconditionFailure("48 kHz stereo float format")
        }
        let source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, abl in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard bufs.count >= 2, let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = bufs[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            isSilence.pointee = ObjCBool(core.render(left: l, right: r, count: Int(frameCount), hostNanos: hostNanosecondsNow()))
            return noErr
        }
        graph = Mutex(Graph(source: source, format: format))
    }

    deinit { shutdown() }

    /// Stops the hardware and the feeder thread. `prepare()` brings them back.
    public func shutdown() {
        core.playing.store(false, ordering: .releasing)
        feeder.stop()
        graph.withLock { g in
            if let o = g.observer { NotificationCenter.default.removeObserver(o); g.observer = nil }
            guard g.prepared else { return }
            g.engine.stop()
            g.source.removeTap(onBus: 0)
            g.prepared = false
        }
    }

    public func prepare() throws {
        try graph.withLock { g in
            if g.prepared { return }
            guard Self.hasOutputDevice() else { throw AudioEngineError.noOutputDevice }
            let e = g.engine
            let out = e.outputNode.outputFormat(forBus: 0)
            guard out.channelCount > 0, out.sampleRate > 0 else { throw AudioEngineError.noOutputDevice }
            if g.source.engine == nil { e.attach(g.source); e.attach(timePitch) }
            connect(g)
            let meter = self.meter
            g.source.installTap(onBus: 0, bufferSize: 1024, format: g.format) { buffer, _ in
                guard let ch = buffer.floatChannelData, buffer.format.channelCount >= 2 else { return }
                meter.measure(ch[0], ch[1], count: Int(buffer.frameLength))
            }
            e.prepare()
            do { try e.start() } catch {
                g.source.removeTap(onBus: 0)
                throw AudioEngineError.startFailed(String(describing: error))
            }
            measureDeviceLatency(e)
            if g.observer == nil {
                g.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e,
                                                                    queue: nil) { [weak self] _ in self?.handleConfigurationChange() }
            }
            g.prepared = true
        }
        measurePitchLatency()
        feeder.start()
    }

    private func connect(_ g: Graph) {
        g.engine.connect(g.source, to: timePitch, format: g.format)
        g.engine.connect(timePitch, to: g.engine.mainMixerNode, format: g.format)
    }

    /// Output configuration changed (device switched, sample rate changed): the engine stopped. Restart it, re-measure
    /// the latency, then let the clock re-seek. If the restart fails the clock's stall watchdog takes over.
    func handleConfigurationChange() {
        configurationChanges.add(1, ordering: .relaxed)
        let restarted = graph.withLock { g -> Bool in
            guard g.prepared else { return false }
            let e = g.engine
            if e.isRunning { e.stop() }
            connect(g)
            e.prepare()
            do { try e.start() } catch { return false }
            measureDeviceLatency(e)
            return true
        }
        guard restarted else { return }
        measurePitchLatency()
        restartHandler.withLock { $0 }?()
    }

    var configurationChangeCount: Int { configurationChanges.load(ordering: .relaxed) }

    /// Hardware boundary: seconds (Double) -> whole 48 kHz frames.
    private static func frames(_ seconds: TimeInterval) -> Int64 { Int64((max(0, seconds) * 48_000).rounded()) }

    private func measureDeviceLatency(_ e: AVAudioEngine) {
        deviceLatencyFrames.store(Self.frames(e.outputNode.presentationLatency), ordering: .releasing)
    }

    private func measurePitchLatency() {
        let l = pitchLock.withLock { _ in Self.effectiveLatency(timePitch) }
        pitchLatencyFrames.store(Self.frames(l), ordering: .releasing)
    }

    /// The unit reports its processing latency (measured on an M1 Max: 4096 frames at 1x/-1x, 3072 at 2x, 2304 at 8x,
    /// 10240 at 1/4x, in 48 kHz frames) even while bypassed; a bypassed effect passes audio straight through, so 0 then.
    private static func effectiveLatency(_ tp: AVAudioUnitTimePitch) -> TimeInterval { tp.bypass ? 0 : tp.latency }

    public var isPrepared: Bool { graph.withLock { $0.prepared } }

    /// A default output device exists (Core Audio HAL query; touches no AVAudioEngine).
    public static func hasOutputDevice() -> Bool {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown
    }

    public func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {
        feeder.setTimeline(timeline, sequences: sequences)
    }

    public func start() { core.playing.store(true, ordering: .releasing) }
    public func stop() { core.playing.store(false, ordering: .releasing) }

    public func setRate(_ rate: PlaybackRate) {
        guard !rate.isPaused else { return }
        reverse.store(rate.isReverse, ordering: .releasing)
        let mag = rate.magnitude
        let l = pitchLock.withLock { _ -> TimeInterval in
            timePitch.rate = Float(mag.num) / Float(mag.den)
            timePitch.pitch = 0
            timePitch.bypass = mag == .forward
            return Self.effectiveLatency(timePitch)
        }
        pitchLatencyFrames.store(Self.frames(l), ordering: .releasing)
    }

    @discardableResult public func seek(to position: Time) -> Int {
        let frame = max(0, AudioFeeder.roundFrame(position, Int64(sampleRate)))
        let gen = feeder.seek(to: frame, reverse: reverse.load(ordering: .acquiring))
        core.beginPriming(generation: gen)
        return gen
    }

    public var flushed: (generation: Int, epoch: Int, latency: Int) { feeder.flushed }
    public var consumedAtEpoch: (epoch: Int, frames: Int64) { ring.consumedAtEpoch }
    public var consumedFrames: Int64 { ring.consumedFrames }
    public var lastRender: AudioRenderStamp { core.lastRender }
    public func hostNanoseconds() -> Int64 { hostNanosecondsNow() }
    public var outputLatency: Time {
        Time(deviceLatencyFrames.load(ordering: .acquiring) + pitchLatencyFrames.load(ordering: .acquiring), Int64(sampleRate))
    }
    public var underrunCount: Int { core.underrunCount }
    public func meterSnapshot() -> AudioMeterSnapshot { meter.snapshot }
    public func setRestartHandler(_ handler: (@Sendable () -> Void)?) { restartHandler.withLock { $0 = handler } }

    /// Test hook: the TimePitch configuration (pitch 0 cents = preserved) and the latency parts in frames.
    var timePitchSettings: (rate: Float, pitch: Float, bypass: Bool) {
        pitchLock.withLock { _ in (timePitch.rate, timePitch.pitch, timePitch.bypass) }
    }
    var latencyParts: (device: Int64, timePitch: Int64) {
        (deviceLatencyFrames.load(ordering: .acquiring), pitchLatencyFrames.load(ordering: .acquiring))
    }
}
