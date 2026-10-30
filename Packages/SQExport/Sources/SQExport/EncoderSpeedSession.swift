import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Encoder speed Balanced / Fast and constant bitrate: AVAssetWriter rejects `PrioritizeEncodingSpeedOverQuality` and `ReferenceBufferCount`
/// in its compression properties (`canApply` is false), so those exports encode with their own VTCompressionSession and
/// hand the compressed samples to a pass-through writer input. Quality keeps the AVAssetWriter encoder (unchanged output).
/// CBR takes the same path at every speed: only a session reports whether its encoder has `ConstantBitRate` (the
/// software encoders answer kVTPropertyNotSupportedErr), so the fallback is chosen per encoder and logged.
extension ExportWriter {
    /// Whether this export encodes through `SpeedEncoderSession` (H.264 / HEVC at Balanced or Fast, or at CBR).
    static func usesSpeedEncoder(_ s: ExportSettings) -> Bool {
        !s.video.codec.isProRes && (s.encoderSpeed != .quality || s.video.usesConstantBitrate || s.usesMultiPass)
    }

    /// `SQ_EXPORT_CBR_REALTIME_OFF=1`: RealTime false at constant bitrate too, as before 2026-10-09 (A/B bench only).
    static let constantBitrateSetsRealTimeOff = ProcessInfo.processInfo.environment["SQ_EXPORT_CBR_REALTIME_OFF"] == "1"

    /// Buffer (VBV) of the constant bitrate in seconds: every second of the stream stays near the target.
    static let constantBitrateBufferSeconds: Float = 0.5

    /// CBR on an encoder without `ConstantBitRate`: the average target (`required`) with the data rate limited to the
    /// target over every 1 s window (bytes, seconds; `limit`, which the software HEVC encoder refuses).
    static func constantBitrateFallback(_ s: ExportSettings) -> (required: [String: Any], limit: [String: Any]) {
        let b = s.video.bitrate.averageBitsPerSecond
        return ([kVTCompressionPropertyKey_AverageBitRate as String: b],
                [kVTCompressionPropertyKey_DataRateLimits as String: [b / 8, 1]])
    }

    /// Properties for the VTCompressionSession: the same rate / keyframe / profile / color choices as
    /// `videoOutputSettings`, plus the speed keys. `hints` may be refused by an encoder (set best-effort); `required` may not.
    /// The Maximum (`DataRateLimits`) is a hint: a refusal is logged, the export goes on with the average alone.
    /// At CBR `required` holds no rate keys: the session sets `ConstantBitRate` or `constantBitrateFallback` itself.
    static func speedEncoderProperties(_ s: ExportSettings) -> (required: [String: Any], hints: [String: Any]) {
        let v = s.video
        // The multi-pass preset is the "best" preset: it ignores the per-Mac speed preference (speed hint false, B-frames as set).
        let speed: EncoderSpeed = s.usesMultiPass ? .quality : s.encoderSpeed
        var r: [String: Any] = [
            kVTCompressionPropertyKey_MaxKeyFrameInterval as String: v.keyframeInterval,
            kVTCompressionPropertyKey_AllowFrameReordering as String:
                v.allowsFrameReordering && v.profile != .baseline && speed != .fast && !s.usesMultiPass,
            kVTCompressionPropertyKey_ColorPrimaries as String: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            kVTCompressionPropertyKey_TransferFunction as String: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            kVTCompressionPropertyKey_YCbCrMatrix as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
        ]
        if let q = v.constantQuality {
            r[kVTCompressionPropertyKey_Quality as String] = q
        } else if !v.usesConstantBitrate { r[kVTCompressionPropertyKey_AverageBitRate as String] = v.bitrate.averageBitsPerSecond }
        let profile: CFString? = switch (v.codec, v.profile) {
        case (.h264, .baseline): kVTProfileLevel_H264_Baseline_AutoLevel
        case (.h264, .main): kVTProfileLevel_H264_Main_AutoLevel
        case (.h264, .high): kVTProfileLevel_H264_High_AutoLevel
        case (.hevc, .main): kVTProfileLevel_HEVC_Main_AutoLevel
        case (.hevc, .main10): kVTProfileLevel_HEVC_Main10_AutoLevel
        default: nil      // Automatic: the encoder's choice, as on the Quality path
        }
        if let profile { r[kVTCompressionPropertyKey_ProfileLevel as String] = profile as String }
        if let hdr = hdrTags(s) {
            r.merge(hdr.sessionProperties) { $1 }
            r[kVTCompressionPropertyKey_ProfileLevel as String] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        var h: [String: Any] = [
            kVTCompressionPropertyKey_ExpectedFrameRate as String:
                Int((Double(v.frameDuration.timescale) / Double(max(1, v.frameDuration.value))).rounded()),
        ]
        // The Maximum is best effort: the software HEVC encoder takes no data rate limit (kVTPropertyNotSupportedErr).
        if !v.usesConstantBitrate, !v.usesConstantQuality, let m = v.bitrate.maxBitsPerSecond { h[kVTCompressionPropertyKey_DataRateLimits as String] = [m / 8, 1] }
        if speed != .quality || v.usesConstantBitrate {
            // Apple's "offline transcode the user waits for" (VTCompressionProperties.h), plus the speed hint below Quality.
            h[kVTCompressionPropertyKey_MaximizePowerEfficiency as String] = false
            // RealTime false, except with `ConstantBitRate`: there the hardware encoders lose 23-37 % of their speed to
            // it and gain nothing (same mean rate and 1 s windows; unset even gives luma PSNR +0.1-0.3 dB, +0.59 dB at HEVC
            // 40 Mbit/s; PLAYBACK-PERF "Export: constant bitrate encoder speed"). Unset is not real time: no frame is dropped, even at a starved rate
            // (RealTime true drops them in HEVC only). The software fallback sets it in the session.
            if !v.usesConstantBitrate || constantBitrateSetsRealTimeOff { h[kVTCompressionPropertyKey_RealTime as String] = false }
        }
        // Speed hint: true below Quality, false for the best-quality preset (set explicitly), unset at plain Quality.
        if speed != .quality { h[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true }
        else if s.usesMultiPass { h[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = false }
        // CABAC: better entropy coding than CAVLC at the same quality; Baseline cannot use it. Best effort (a hint).
        if v.codec == .h264, v.profile != .baseline { h[kVTCompressionPropertyKey_H264EntropyMode as String] = kVTH264EntropyMode_CABAC as String }
        // Fast: one reference frame (no B-frames above): least motion search and reference memory.
        if speed == .fast { h[kVTCompressionPropertyKey_ReferenceBufferCount as String] = 1 }
        return (r, h)
    }

    /// Encoder specification: nil lets VideoToolbox pick (hardware when present), else software only.
    static func speedEncoderSpecification(_ s: ExportSettings) -> [String: Any]? {
        s.video.hardwareEncoding ? nil
            : [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
    }
}

/// Whether an encoder that was asked for hardware really runs on it.
enum HardwareVerdict: Equatable, Sendable {
    /// Hardware was not asked for (the Software encoder setting).
    case notRequested
    case hardware
    /// Running in software and this Mac has no hardware encoder for the codec: allowed, as before.
    case softwareAllowed
    /// Running in software although this Mac has a hardware encoder for the codec: the export stops with a clear error.
    case softwareUnexpected
}

extension ExportWriter {
    static func hardwareVerdict(requested: Bool, usingHardware: Bool, hardwareEncoderExists: Bool) -> HardwareVerdict {
        if !requested { return .notRequested }
        if usingHardware { return .hardware }
        return hardwareEncoderExists ? .softwareUnexpected : .softwareAllowed
    }

    /// Test seam: replaces what the session reports (`usingHardware`) and whether the Mac has a hardware encoder.
    @TaskLocal static var hardwareReadbackOverride: (usingHardware: Bool, encoderExists: Bool)?

    /// Whether this Mac lists a hardware encoder for `codec` (VTCopyVideoEncoderList).
    static func hardwareEncoderExists(_ codec: CMVideoCodecType) -> Bool {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let entries = list as? [[String: Any]] else { return false }
        return entries.contains {
            ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == codec
                && ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
        }
    }

    /// Reads `UsingHardwareAcceleratedVideoEncoder` back from a prepared session, logs it, and throws when a silent software
    /// fallback happened on a Mac that has a hardware encoder for the codec.
    static func verifyHardware(session: VTCompressionSession, settings s: ExportSettings) throws -> HardwareVerdict {
        let codec: CMVideoCodecType = s.video.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var value: CFTypeRef?
        let st = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                       allocator: nil, valueOut: &value)
        // A software encoder does not list the property: absent means not hardware.
        let using = hardwareReadbackOverride?.usingHardware ?? (st == noErr && (value as? Bool) == true)
        let exists = hardwareReadbackOverride?.encoderExists ?? (s.video.hardwareEncoding && !using ? hardwareEncoderExists(codec) : using)
        let verdict = hardwareVerdict(requested: s.video.hardwareEncoding, usingHardware: using, hardwareEncoderExists: exists)
        NSLog("[export] %@ %dx%d encoder: hardware asked %@, UsingHardwareAcceleratedVideoEncoder %@ (%@)",
              s.video.codec.displayName, s.video.width, s.video.height, s.video.hardwareEncoding ? "yes" : "no",
              using ? "yes" : "no", "\(verdict)")
        if verdict == .softwareUnexpected {
            throw ExportError.hardwareEncoderUnavailable(
                "The \(s.video.codec.displayName) hardware encoder did not take \(s.video.width)x\(s.video.height) and would fall back to the slower software encoder. Turn off hardware encoding in the export settings to use software on purpose.")
        }
        return verdict
    }

    private static let hardwareChecked = NSLock()
    nonisolated(unsafe) private static var hardwareOK: Set<String> = []

    /// The AVAssetWriter path (Quality speed) owns its encoder session and does not show it: open a throwaway session with the
    /// same codec, size and profile once per combination and verify it. A no-op for ProRes and for software on purpose.
    static func verifyHardwareForWriter(_ s: ExportSettings) throws {
        guard !s.video.codec.isProRes, s.video.hardwareEncoding, !usesSpeedEncoder(s) else { return }
        let key = "\(s.video.codec.rawValue)-\(s.video.width)x\(s.video.height)-\(s.video.profile)"
        hardwareChecked.lock(); let done = hardwareOK.contains(key) && hardwareReadbackOverride == nil; hardwareChecked.unlock()
        if done { return }
        _ = try SpeedEncoderSession(settings: s)   // verifies in its init
        hardwareChecked.lock(); hardwareOK.insert(key); hardwareChecked.unlock()
    }
}

/// One VTCompressionSession; compressed samples (decode order) collect in a queue the export loop drains.
final class SpeedEncoderSession: @unchecked Sendable {
    private let session: VTCompressionSession
    private let lock = NSLock()
    private var ready: [CMSampleBuffer] = []
    private var failure: OSStatus = noErr
    private var dropped = false
    /// Test seam: the callback of this frame index (0-based) is swallowed, as an encoder that skips a frame without a drop flag.
    @TaskLocal static var swallowFrameIndex: Int?
    private let swallowIndex = SpeedEncoderSession.swallowFrameIndex
    private var encoded = 0
    /// How the session holds the bitrate.
    enum RateControl: Sendable, Equatable { case average, constant, constantFallback }
    let rateControl: RateControl
    /// The encoder refused the Maximum (`DataRateLimits`); the export runs on the average alone.
    let maximumRefused: Bool
    /// Whether the session runs VideoToolbox multi-pass (asked for and the encoder took the `MultiPassStorage`).
    let multiPass: Bool
    private var multiPassFile: URL?
    /// The hardware verdict read back after the session was prepared.
    private(set) var hardware: HardwareVerdict = .notRequested

    init(settings s: ExportSettings) throws {
        var out: VTCompressionSession?
        let codec: CMVideoCodecType = s.video.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(s.video.width), height: Int32(s.video.height),
                                            codecType: codec,
                                            encoderSpecification: ExportWriter.speedEncoderSpecification(s) as CFDictionary?,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &out)
        guard st == noErr, let out else { throw ExportError.writerFailed("VTCompressionSessionCreate \(st)") }
        session = out
        let props = ExportWriter.speedEncoderProperties(s)
        func require(_ d: [String: Any]) throws {
            for (k, v) in d {
                let r = VTSessionSetProperty(out, key: k as CFString, value: v as CFTypeRef)
                guard r == noErr else { VTCompressionSessionInvalidate(out); throw ExportError.writerFailed("encoder property \(k) \(r)") }
            }
        }
        try require(props.required)
        var refused = false
        for (k, v) in props.hints {
            let r = VTSessionSetProperty(out, key: k as CFString, value: v as CFTypeRef)
            if r != noErr, k == kVTCompressionPropertyKey_DataRateLimits as String {
                refused = true
                NSLog("[export] this %@ encoder takes no maximum bitrate (%d); encoding with the average alone", s.video.codec.displayName, r)
            }
        }
        maximumRefused = refused
        if s.video.usesConstantBitrate {
            let key = kVTCompressionPropertyKey_ConstantBitRate
            var supported: CFDictionary?
            VTSessionCopySupportedPropertyDictionary(out, supportedPropertyDictionaryOut: &supported)
            let listed = (supported as? [String: Any])?[key as String] != nil
            let st = listed ? VTSessionSetProperty(out, key: key, value: s.video.bitrate.averageBitsPerSecond as CFNumber)
                            : kVTPropertyNotSupportedErr
            if st == noErr {
                rateControl = .constant
                // Best effort. Measured on Apple silicon (1280x720, 6 Mbit/s): with the default buffer the first second
                // holds half the target and a hard scene change runs a second at 150 %; 0.5 s starts on target (130 %).
                _ = VTSessionSetProperty(out, key: kVTCompressionPropertyKey_VBVBufferDuration,
                                         value: ExportWriter.constantBitrateBufferSeconds as CFNumber)
            } else {
                let fallback = ExportWriter.constantBitrateFallback(s)
                try require(fallback.required)
                // Average rate control: the offline hint costs nothing here (left out of the hints for `ConstantBitRate`).
                _ = VTSessionSetProperty(out, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
                var limited = true
                for (k, v) in fallback.limit where VTSessionSetProperty(out, key: k as CFString, value: v as CFTypeRef) != noErr { limited = false }
                rateControl = .constantFallback
                NSLog("[export] CBR: this %@ encoder has no ConstantBitRate (%d); using the average bitrate %@",
                      s.video.codec.displayName, st,
                      limited ? "with a 1 s data rate limit at the target" : "alone, it takes no data rate limit either")
            }
        } else {
            rateControl = .average
        }
        // Multi-pass: the encoder needs its analysis storage before the first frame. An encoder without it encodes one pass.
        var passes = false
        if s.usesMultiPass {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("sq-multipass-\(UUID().uuidString).dat")
            var storage: VTMultiPassStorage?
            let made = VTMultiPassStorageCreate(allocator: nil, fileURL: file as CFURL, timeRange: .invalid, options: nil,
                                                multiPassStorageOut: &storage)
            let set = made == noErr ? VTSessionSetProperty(out, key: kVTCompressionPropertyKey_MultiPassStorage, value: storage)
                                    : made
            if set == noErr { passes = true; multiPassFile = file }
            else { NSLog("[export] this %@ encoder takes no multi-pass storage (%d); encoding in one pass", s.video.codec.displayName, set) }
        }
        multiPass = passes
        VTCompressionSessionPrepareToEncodeFrames(out)
        hardware = try ExportWriter.verifyHardware(session: out, settings: s)
    }

    /// The session's current value of a property (tests read `RealTime` back).
    func copyProperty(_ key: CFString, into out: inout CFTypeRef?) -> OSStatus {
        VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &out)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
        if let multiPassFile { try? FileManager.default.removeItem(at: multiPassFile) }
    }

    /// Starts a pass over the frames. `final`: the encoder must write this one (no further pass is asked for).
    func beginPass(final: Bool) throws {
        let st = VTCompressionSessionBeginPass(session, flags: final ? .beginFinalPass : [], nil)
        guard st == noErr else { throw ExportError.writerFailed("begin pass \(st)") }
    }

    /// Ends the pass; true when the encoder wants another one (`nextPassRanges` says which frames it needs).
    func endPass() throws -> Bool {
        var more: DarwinBoolean = false
        let st = VTCompressionSessionEndPass(session, furtherPassesRequestedOut: &more, nil)
        guard st == noErr else { throw ExportError.writerFailed("end pass \(st)") }
        return more.boolValue
    }

    /// The time ranges the next pass must be fed with (empty: all frames).
    func nextPassRanges() throws -> [CMTimeRange] {
        var count: CMItemCount = 0
        var ranges: UnsafePointer<CMTimeRange>?
        let st = VTCompressionSessionGetTimeRangesForNextPass(session, timeRangeCountOut: &count, timeRangeArrayOut: &ranges)
        guard st == noErr else { throw ExportError.writerFailed("pass time ranges \(st)") }
        guard let ranges, count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ranges, count: count))
    }

    /// Encoder output callbacks so far, and how many ran at a lower QoS than the thread that sent their frame.
    var callbackQoS: (callbacks: Int, below: Int) { lock.lock(); defer { lock.unlock() }; return (callbacks, callbacksBelow) }
    private var callbacks = 0, callbacksBelow = 0

    /// True when `a` is a lower QoS class than `b` (unspecified compares as neither).
    static func isBelow(_ a: qos_class_t, _ b: qos_class_t) -> Bool {
        a != QOS_CLASS_UNSPECIFIED && b != QOS_CLASS_UNSPECIFIED && a.rawValue < b.rawValue
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime, duration: CMTime) throws {
        let index = encoded; encoded += 1
        let swallow = swallowIndex == index
        // QoS discipline (F1 FCP study: a compression callback below the sender's QoS stalls the pipeline behind it):
        // each callback is checked against the QoS of the thread that sent its frame, a mismatch is logged once.
        let senderQoS = qos_class_self()
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: duration,
                                                 frameProperties: nil, infoFlagsOut: nil) { [weak self] status, flags, sb in
            guard let self else { return }
            let callbackQoS = qos_class_self()
            self.lock.lock(); defer { self.lock.unlock() }
            self.callbacks += 1
            if Self.isBelow(callbackQoS, senderQoS) {
                self.callbacksBelow += 1
                if self.callbacksBelow == 1 {
                    NSLog("[export] encoder callback ran at QoS 0x%x, below the sender's 0x%x",
                          callbackQoS.rawValue, senderQoS.rawValue)
                }
            }
            if status != noErr { if self.failure == noErr { self.failure = status }; return }
            if flags.contains(.frameDropped) { self.dropped = true; return }
            if swallow { return }
            if let sb { self.ready.append(sb) }
        }
        guard st == noErr else { throw ExportError.writerFailed("encode frame \(st)") }
    }

    /// Flushes every pending frame (B-frame lookahead) into the queue.
    func complete() throws {
        let st = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard st == noErr else { throw ExportError.writerFailed("complete frames \(st)") }
    }

    /// Samples encoded so far, in decode order; throws the first encoder error.
    func take() throws -> [CMSampleBuffer] {
        lock.lock(); defer { lock.unlock() }
        if failure != noErr { throw ExportError.writerFailed("encoder \(failure)") }
        // An export never shortens silently.
        if dropped { throw ExportError.writerFailed("the encoder dropped a frame") }
        let r = ready; ready.removeAll(keepingCapacity: true)
        return r
    }
}
