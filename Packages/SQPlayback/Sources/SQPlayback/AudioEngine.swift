@preconcurrency import AVFoundation
import CoreAudio
import Darwin
import Foundation
import Synchronization
import SQCore
import SQMedia
import SQAudioFX

public enum AudioEngineError: Error, Sendable, Equatable {
    case noOutputDevice
    case startFailed(String)
}

/// Timeline audio output (ARCHITECTURE §7): `AudioFeeder` (own thread) -> `RingBuffer` (5 ms flush fades) ->
/// `AVAudioSourceNode` (render block copies from the ring only) -> `AVAudioUnitTimePitch` (rate = |speed|, pitch
/// preserved, bypassed at 1x) -> `mainMixerNode` -> output. The meter reads the source block before the
/// monitoring-only channel Solo/Mute stage (`MeterDrain`, off the render thread).
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
    private let meter: AudioMeterStore
    private let meterDrain: MeterDrain
    private let channelMonitor = ChannelMonitorStage()
    private let scrubChannelMonitor = ChannelMonitorStage()
    private let deviceLatencyFrames = Atomic<Int64>(0)
    private let pitchLatencyFrames = Atomic<Int64>(0)
    private let reverse = Atomic<Bool>(false)
    private let restartHandler = CallbackSlot()
    private let configurationChanges = Atomic<Int>(0)

    /// TimePitch parameters: own short lock so `setRate` never waits for `prepare`'s hardware start.
    private let timePitch = AVAudioUnitTimePitch()
    private let pitchLock = Mutex(())

    private struct Graph {
        let engine = AVAudioEngine()
        let source: AVAudioSourceNode
        /// Scrub grains (E-12): own node straight into the main mixer (no TimePitch latency, play ring untouched).
        let scrubSource: AVAudioSourceNode
        let format: AVAudioFormat
        var prepared = false
        var observer: (any NSObjectProtocol)?
        /// HAL id this engine's output unit was pinned to (nil = following the system default).
        var pinnedDevice: UInt32?
    }
    /// Settings > Playback > Output Device: a stored CoreAudio UID; nil or a missing device = the system default.
    private let outputUID = Mutex<String?>(nil)
    private let graph: Mutex<Graph>

    /// `media.audio(for:)` provides the sources (expected at 48 kHz, e.g. `AssetAudioSource.open(url:sampleRate: 48_000)`).
    public convenience init(media: any MediaResolver) {
        self.init(resolver: { try media.audio(for: $0) })
    }

    /// Scrub/step grains, rendered by their own source node into the main mixer (see `ScrubAudio`).
    public let scrubAudio: ScrubAudio?
    private let declickObserver: AudioDeClickObserver
    private let duckObserver: LiveDuckingObserver

    public init(resolver: @escaping AudioFeeder.Resolver) {
        let scrub = ScrubAudio(resolver: resolver, sampleRate: 48_000)
        scrubAudio = scrub
        ring = RingBuffer(capacity: Self.ringCapacity, fadeFrames: 240)
        feeder = AudioFeeder(timeline: Timeline(name: "", frameDuration: Time(1, 30)), ring: ring, sampleRate: 48_000,
                             blockFrames: 1024, resolver: resolver)
        feeder.declickFrames = AudioDeClick.currentFadeFrames()
        feeder.liveDucking = LiveDucking.current()
        let liveFeeder = feeder
        declickObserver = AudioDeClickObserver { liveFeeder.declickFrames = $0 }   // Preferences toggle applies live
        duckObserver = LiveDuckingObserver { liveFeeder.liveDucking = $0 }
        let meterStore = AudioMeterStore()
        meter = meterStore
        let drain = MeterDrain(store: meterStore)
        meterDrain = drain
        let stage = channelMonitor, scrubStage = scrubChannelMonitor
        let core = AudioRenderCore(ring: ring, flushGeneration: feeder.flushGeneration, fadeFrames: 240)
        self.core = core
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            preconditionFailure("48 kHz stereo float format")
        }
        let source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, abl in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard bufs.count >= 2, let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = bufs[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = Int(frameCount)
            isSilence.pointee = ObjCBool(core.render(left: l, right: r, count: n, hostNanos: hostNanosecondsNow()))
            drain.push(left: l, right: r, count: n)          // meter sees the mix before the monitoring gain
            stage.process(left: l, right: r, count: n)       // monitoring-only Solo/Mute
            return noErr
        }
        let voice = scrub.voice
        let scrubSource = AVAudioSourceNode(format: format) { isSilence, _, frameCount, abl in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard bufs.count >= 2, let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = bufs[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            isSilence.pointee = ObjCBool(voice.render(left: l, right: r, count: Int(frameCount)))
            scrubStage.process(left: l, right: r, count: Int(frameCount))
            return noErr
        }
        let g = Graph(source: source, scrubSource: scrubSource, format: format)
        monitor = MonitorGainDriver()
        graph = Mutex(g)
        monitor.bind { [weak self] v in self?.applyMonitorVolume(v) }
    }

    /// Every mixer write goes through the graph lock and only once the engine is prepared (no output device = no mixer access).
    private func applyMonitorVolume(_ v: Float) {
        graph.withLock { g in if g.prepared { g.engine.mainMixerNode.outputVolume = v } }
    }

    /// F7.5 listening level: drives the main mixer's output volume (after the meter tap, never in export). Preference-backed.
    private let monitor: MonitorGainDriver

    deinit { shutdown() }

    /// Stops the hardware and the feeder thread. `prepare()` brings them back.
    public func shutdown() {
        core.playing.store(false, ordering: .releasing)
        scrubAudio?.stop()
        feeder.stop()
        graph.withLock { g in
            if let o = g.observer { NotificationCenter.default.removeObserver(o); g.observer = nil }
            guard g.prepared else { return }
            g.engine.stop()
            meterDrain.stop()
            g.prepared = false
        }
    }

    /// One `prepare()` at a time: the pre-warm on a background queue and the first play may race; the second waits for the
    /// first and returns (the feeder starts once).
    private let prepareGate = Mutex(())

    public func prepare() throws {
        try prepareGate.withLock { _ in
        if graph.withLock({ $0.prepared }) { return }
        try graph.withLock { g in
            if g.prepared { return }
            guard Self.hasOutputDevice() else { throw AudioEngineError.noOutputDevice }
            let e = g.engine
            applyOutputDevice(&g)
            let out = e.outputNode.outputFormat(forBus: 0)
            guard out.channelCount > 0, out.sampleRate > 0 else { throw AudioEngineError.noOutputDevice }
            if g.source.engine == nil { e.attach(g.source); e.attach(timePitch); e.attach(g.scrubSource) }
            connect(g)
            g.engine.mainMixerNode.outputVolume = monitor.currentVolume
            meterDrain.start()
            e.prepare()
            do { try e.start() } catch {
                meterDrain.stop()
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
    }

    /// Chooses the output device by UID (nil = system default). A UID that is not connected falls back to the system
    /// default. Takes effect at once when the engine runs (restart + re-seek), otherwise at the next `prepare()`.
    public func setOutputDevice(uid: String?) {
        let changed = outputUID.withLock { cur -> Bool in
            let new = (uid?.isEmpty ?? true) ? nil : uid
            if cur == new { return false }
            cur = new
            return true
        }
        if changed, isPrepared { handleConfigurationChange() }
    }

    /// Points the (stopped) output unit at the chosen device. Pinning only happens for a connected, chosen device; once
    /// unpinned the unit is returned to the current system default so it follows it again.
    private func applyOutputDevice(_ g: inout Graph) {
        let uid = outputUID.withLock { $0 }
        var target: UInt32?
        if let uid, let device = AudioOutputDevices.resolve(uid: uid, in: AudioOutputDevices.available()) {
            if g.pinnedDevice != device.id { target = device.id }
            g.pinnedDevice = device.id
        } else if g.pinnedDevice != nil {
            target = AudioOutputDevices.defaultDeviceID()
            g.pinnedDevice = nil
        }
        guard var id = target, let unit = g.engine.outputNode.audioUnit else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                             UInt32(MemoryLayout<UInt32>.size))
    }

    private func connect(_ g: Graph) {
        g.engine.connect(g.source, to: timePitch, format: g.format)
        // Explicit mixer buses: reconnecting after a configuration change must not pile up inputs.
        g.engine.connect(timePitch, to: g.engine.mainMixerNode, fromBus: 0, toBus: 0, format: g.format)
        g.engine.connect(g.scrubSource, to: g.engine.mainMixerNode, fromBus: 0, toBus: 1, format: g.format)
    }

    /// Output configuration changed (device switched, sample rate changed): the engine stopped. Restart it, re-measure
    /// the latency, then let the clock re-seek. If the restart fails the clock's stall watchdog takes over.
    func handleConfigurationChange() {
        configurationChanges.add(1, ordering: .relaxed)
        let restarted = graph.withLock { g -> Bool in
            guard g.prepared else { return false }
            let e = g.engine
            if e.isRunning { e.stop() }
            applyOutputDevice(&g)
            connect(g)
            g.engine.mainMixerNode.outputVolume = monitor.currentVolume   // a dimmed monitor stays dimmed on new headphones
            e.prepare()
            do { try e.start() } catch { return false }
            measureDeviceLatency(e)
            return true
        }
        guard restarted else { return }
        measurePitchLatency()
        restartHandler.call()
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
        scrubAudio?.setTimeline(timeline, sequences: sequences)
    }

    public func mediaChanged(_ ids: Set<UUID>) { feeder.mediaChanged(ids) }

    public func setProjectLiveDucking(_ setting: ProjectLiveDucking?) {
        feeder.projectLiveDucking = setting
        scrubAudio?.setProjectLiveDucking(setting)
    }

    public func setDialogueSilences(_ provider: (any DialogueSilenceProvider)?) {
        feeder.dialogueSilences = provider
        scrubAudio?.setDialogueSilences(provider)
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
        feeder.declickFrames = AudioDeClick.currentFadeFrames()    // the setting takes effect at the next seek/play
        feeder.liveDucking = LiveDucking.current()
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
    public func resetLoudnessMeter() { meter.resetLoudness() }
    public func setChannelMonitor(_ state: ChannelMonitor) {
        channelMonitor.set(state)
        scrubChannelMonitor.set(state)
    }
    public var channelMonitorState: ChannelMonitor { channelMonitor.state }
    public func setRestartHandler(_ handler: (@Sendable () -> Void)?) { restartHandler.set(handler) }

    /// Test hook: the TimePitch configuration (pitch 0 cents = preserved) and the latency parts in frames.
    var timePitchSettings: (rate: Float, pitch: Float, bypass: Bool) {
        pitchLock.withLock { _ in (timePitch.rate, timePitch.pitch, timePitch.bypass) }
    }
    var latencyParts: (device: Int64, timePitch: Int64) {
        (deviceLatencyFrames.load(ordering: .acquiring), pitchLatencyFrames.load(ordering: .acquiring))
    }
}


/// Follows the `sq.monitor.*` preference and ramps the gain (no click). It holds only the value: the engine supplies the
/// mixer write (`bind`), which runs under the graph lock and only when the engine is prepared. Nothing runs on the audio
/// render thread and the export path never creates one of these.
final class MonitorGainDriver: @unchecked Sendable {
    private struct State { var ramp: MonitorGain.Ramp; var timer: DispatchSourceTimer?; var write: (@Sendable (Float) -> Void)? }
    private let defaults: UserDefaults
    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "sq.monitor.gain", qos: .utility)
    private var token: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        MonitorGain.applyLaunchRulesOnce(defaults: defaults)
        state = Mutex(State(ramp: MonitorGain.Ramp(current: MonitorGain.Setting.current(defaults: defaults).linear)))
        token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
            self?.refresh()
        }
    }
    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
        state.withLock { $0.timer?.cancel() }
    }

    /// The gain right now (applied when the engine starts or restarts).
    var currentVolume: Float { state.withLock { $0.ramp.value } }

    func bind(_ write: @escaping @Sendable (Float) -> Void) { state.withLock { $0.write = write } }

    func refresh() {
        let target = MonitorGain.Setting.current(defaults: defaults).linear
        state.withLock { st in
            guard st.ramp.target != target else { return }
            st.ramp.target = target
            guard st.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: MonitorGain.Ramp.stepSeconds)
            t.setEventHandler { [weak self] in self?.step() }
            st.timer = t
            t.resume()
        }
    }

    private func step() {
        let (next, write) = state.withLock { st -> (Float?, (@Sendable (Float) -> Void)?) in
            if let v = st.ramp.next() { return (v, st.write) }
            st.timer?.cancel(); st.timer = nil
            return (nil, nil)
        }
        if let next { write?(next) }
    }
}
