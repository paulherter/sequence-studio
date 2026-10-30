import CSQFFmpeg
import Foundation
import SQCore
import SQAudioFX
import SQPlayback
import Synchronization

public enum WASAPIAudioError: Error, Sendable, Equatable {
    case noOutputDevice(String)
    case startFailed(String)
}

/// Timeline audio output on Windows: the same `AudioFeeder` -> `RingBuffer` -> `AudioRenderCore` chain as the Mac's
/// `AudioEngine`, with a WASAPI shared-mode stream (48 kHz stereo float, event driven) as the device.
/// |rate| != 1 (shuttle) keeps the pitch through `ShuttleStretch` (the Mac's AVAudioUnitTimePitch).
/// shortcut: no scrub audio, no device choice or device-change restart; upgrade with the Windows playback UI
/// (Phase 3).
public final class WASAPIAudioEngine: AudioPlaying, @unchecked Sendable {
    public let sampleRate = 48_000
    public let ring: RingBuffer
    public let feeder: AudioFeeder
    private let core: AudioRenderCore
    private let sink: RenderSink
    private let reverse = Atomic<Bool>(false)
    private let output = Mutex<OpaquePointer?>(nil)
    private let latencyFrames = Atomic<Int64>(0)
    private let restartHandler = Mutex<(@Sendable () -> Void)?>(nil)

    public init(resolver: @escaping AudioFeeder.Resolver) {
        MonitorGain.applyLaunchRulesOnce()   // before the sink reads the stored listening level
        ring = RingBuffer(capacity: 1 << 16, fadeFrames: 240)
        feeder = AudioFeeder(timeline: Timeline(name: "", frameDuration: Time(1, 30)), ring: ring, sampleRate: 48_000,
                             blockFrames: 1024, resolver: resolver)
        feeder.applyAudioPreferences()      // De-Click and Live Ducking; the app calls it again after Preferences change
        core = AudioRenderCore(ring: ring, flushGeneration: feeder.flushGeneration, fadeFrames: 240)
        sink = RenderSink(core: core, meter: MeterDrain(store: meterStore))
    }

    deinit { shutdown() }

    /// Stops the device and the feeder thread.
    public func shutdown() {
        core.playing.store(false, ordering: .releasing)
        output.withLock { o in
            if let w = o { sq_wasapi_stop(w); sq_wasapi_close(w) }
            o = nil
        }
        feeder.stop()
        sink.meter.stop()
    }

    /// Name of the output device (nil before `prepare()`).
    public var deviceName: String? { output.withLock { o in o.map { String(cString: sq_wasapi_device_name($0)) } } }
    /// Frames the device has pulled since `prepare()`.
    public var renderedFrames: Int64 { output.withLock { o in o.map { sq_wasapi_rendered_frames($0) } ?? 0 } }

    public func prepare() throws {
        try output.withLock { o in
            if o != nil { return }
            o = try openDevice(preferredDevice.withLock { $0 })
            feeder.start()
            sink.meter.start()
        }
    }

    /// The device Preferences > Audio Output picked; nil = the system default.
    private let preferredDevice = Mutex<String?>(nil)

    /// Active output devices (id, friendly name), the Mac `AudioOutputDevices.available()`.
    public static func outputDevices() -> [(uid: String, name: String)] {
        let needed = Int(sq_wasapi_list_outputs(nil, 0))
        guard needed > 1 else { return [] }
        var buf = [CChar](repeating: 0, count: needed + 64)
        _ = sq_wasapi_list_outputs(&buf, Int32(buf.count))
        let text = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let id = parts.first, !id.isEmpty else { return nil }
            return (String(id), parts.count > 1 ? String(parts[1]) : String(id))
        }
    }

    /// Plays on `uid` (nil = system default; a device that is not connected falls back to it). Reopens only the device
    /// when it is running: the feeder, the ring and the meter keep going.
    public func setOutputDevice(_ uid: String?) {
        let changed = preferredDevice.withLock { p in defer { p = uid }; return p != uid }
        guard changed else { return }
        output.withLock { o in
            guard let old = o else { return }
            sq_wasapi_stop(old); sq_wasapi_close(old)
            o = try? openDevice(uid)
        }
        restartHandler.withLock { $0 }?()
    }

    /// Opens and starts `uid` (nil = default) with the render sink.
    private func openDevice(_ uid: String?) throws -> OpaquePointer {
        var w: OpaquePointer?
        var err = [CChar](repeating: 0, count: 256)
        let ctx = Unmanaged.passUnretained(sink).toOpaque()
        let render: SQWasapiRender = { ctx, buf, frames, _ in
            guard let ctx, let buf else { return }
            Unmanaged<RenderSink>.fromOpaque(ctx).takeUnretainedValue().render(buf, Int(frames))
        }
        let r = sq_wasapi_open_device(uid, render, ctx, &w, &err, Int32(err.count))
        guard r == 0, let w else { throw WASAPIAudioError.noOutputDevice(FFmpegError.from("WASAPI", r, err).description) }
        let s = sq_wasapi_start(w)
        guard s == 0 else { sq_wasapi_close(w); throw WASAPIAudioError.startFailed("WASAPI start failed (\(s))") }
        latencyFrames.store(sq_wasapi_latency_frames(w), ordering: .releasing)
        return w
    }

    public func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {
        feeder.setTimeline(timeline, sequences: sequences)
    }
    public func mediaChanged(_ ids: Set<UUID>) { feeder.mediaChanged(ids) }
    public func setProjectLiveDucking(_ setting: ProjectLiveDucking?) { feeder.projectLiveDucking = setting }
    public func setDialogueSilences(_ provider: (any DialogueSilenceProvider)?) { feeder.dialogueSilences = provider }
    public func start() { core.playing.store(true, ordering: .releasing) }
    public func stop() { core.playing.store(false, ordering: .releasing) }
    public func setRate(_ rate: PlaybackRate) {
        guard !rate.isPaused else { return }
        reverse.store(rate.isReverse, ordering: .releasing)
        let mag = rate.magnitude
        sink.setSpeed(Double(mag.num) / Double(mag.den))
    }

    @discardableResult public func seek(to position: Time) -> Int {
        let frame = max(0, AudioFeeder.roundFrame(position, Int64(sampleRate)))
        let gen = feeder.seek(to: frame, reverse: reverse.load(ordering: .acquiring))
        core.beginPriming(generation: gen)
        sink.requestReset()
        return gen
    }

    public var flushed: (generation: Int, epoch: Int, latency: Int) { feeder.flushed }
    public var consumedAtEpoch: (epoch: Int, frames: Int64) { ring.consumedAtEpoch }
    public var consumedFrames: Int64 { ring.consumedFrames }
    public var lastRender: AudioRenderStamp { core.lastRender }
    public func hostNanoseconds() -> Int64 { hostNanosecondsNow() }
    public var outputLatency: Time {
        Time(latencyFrames.load(ordering: .acquiring) + (sink.stretching ? Int64(ShuttleStretch.latencyFrames) : 0),
             Int64(sampleRate))
    }
    public var underrunCount: Int { core.underrunCount }
    /// The meter feed (the Mac AudioEngine's MeterDrain): the render callback pushes the timeline mix before the shuttle
    /// stretch, a utility timer measures peak, RMS and BS.1770 loudness off the audio thread.
    private let meterStore = AudioMeterStore()
    public func meterSnapshot() -> AudioMeterSnapshot { meterStore.snapshot }
    public func resetLoudnessMeter() { meterStore.resetLoudness() }
    public func setRestartHandler(_ handler: (@Sendable () -> Void)?) { restartHandler.withLock { $0 = handler } }
    /// Monitoring-only Solo/Mute and the listening level (Dim): after the meter push, speakers only.
    public func setChannelMonitor(_ state: ChannelMonitor) { sink.channels.set(state) }
    public var channelMonitorState: ChannelMonitor { sink.channels.state }
    public func setMonitorGain(_ setting: MonitorGain.Setting) { sink.gain.set(setting) }

    /// Audio-thread side: planar scratch buffers, the core renders into them (through `ShuttleStretch` at |rate| != 1),
    /// then they are interleaved for WASAPI.
    final class RenderSink: @unchecked Sendable {
        let core: AudioRenderCore
        let meter: MeterDrain
        let channels = ChannelMonitorStage()
        let gain = MonitorGainStage(linear: MonitorGain.Setting.current().linear)
        private let stretch = ShuttleStretch()
        /// Speed (|rate|) as Double bits; set on the control thread, read per callback.
        private let speedBits = Atomic<UInt64>(1.0.bitPattern)
        private let resetPending = Atomic<Bool>(false)
        func setSpeed(_ s: Double) {
            let old = Double(bitPattern: speedBits.exchange(s.bitPattern, ordering: .acquiringAndReleasing))
            if old != s { requestReset() }
        }
        func requestReset() { resetPending.store(true, ordering: .releasing) }
        var stretching: Bool { Double(bitPattern: speedBits.load(ordering: .acquiring)) != 1 }
        let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
        static let chunk = 4096
        init(core: AudioRenderCore, meter: MeterDrain) {
            self.core = core; self.meter = meter
            left = .allocate(capacity: Self.chunk); right = .allocate(capacity: Self.chunk)
            left.initialize(repeating: 0, count: Self.chunk); right.initialize(repeating: 0, count: Self.chunk)
        }
        deinit { left.deallocate(); right.deallocate() }

        func render(_ out: UnsafeMutablePointer<Float>, _ frames: Int) {
            if resetPending.exchange(false, ordering: .acquiringAndReleasing) { stretch.reset() }
            let speed = Double(bitPattern: speedBits.load(ordering: .acquiring))
            var done = 0
            while done < frames {
                let n = min(Self.chunk, frames - done)
                if speed == 1 {
                    _ = core.render(left: left, right: right, count: n, hostNanos: hostNanosecondsNow())
                    meter.push(left: left, right: right, count: n)
                } else {
                    let core = core, meter = meter
                    stretch.render(rate: speed, left: left, right: right, count: n) { l, r, c in
                        var got = 0
                        while got < c {   // the core renders at most `chunk` frames per call into any buffer
                            let m = min(Self.chunk, c - got)
                            _ = core.render(left: l + got, right: r + got, count: m, hostNanos: hostNanosecondsNow())
                            meter.push(left: l + got, right: r + got, count: m)
                            got += m
                        }
                    }
                }
                channels.process(left: left, right: right, count: n)   // the meter saw the mix before these two
                gain.process(left: left, right: right, count: n)
                let o = out + 2 * done
                for i in 0..<n { o[2 * i] = left[i]; o[2 * i + 1] = right[i] }
                done += n
            }
        }
    }
}
