import Foundation
import SQCore

/// Smart render eligibility (analysis only, no writer path; the design notes 2026-10-04 "Smart render"): which output frames
/// could be copied from the source file without re-encoding. Conservative: any doubt = re-encode.
///
/// A frame is eligible only when exactly one plain layer is visible: a top-level media clip (no nest, generator, graphics,
/// adjustment layer, transition or caption burn-in), identity transform, no clip effect, identity color, normal speed on
/// the source frame grid, and a source whose stream already is what the encoder would write (codec FourCC, stored size =
/// output size without rotation, bit depth, chroma, frame rate, Rec.709 tags, bitrate at most 1.25x the target).
/// Eligible frames form runs (same clip, source advancing one frame per output frame); only whole closed GOPs inside a
/// run, at least `minimumPassthroughFrames` long, could be passed through.

/// What the export encodes.
public struct SmartRenderTarget: Sendable, Hashable {
    public var codec: String
    public var width: Int, height: Int
    public var bitDepth: Int
    public var chroma: String
    public var frameDuration: Time
    /// nil = no bitrate cap (ProRes: the data rate is the codec's own).
    public var averageBitsPerSecond: Int?

    public init(codec: String, width: Int, height: Int, bitDepth: Int, chroma: String, frameDuration: Time,
                averageBitsPerSecond: Int?) {
        self.codec = codec; self.width = width; self.height = height; self.bitDepth = bitDepth; self.chroma = chroma
        self.frameDuration = frameDuration; self.averageBitsPerSecond = averageBitsPerSecond
    }

    public init(settings: ExportSettings) {
        let v = settings.video
        let codec: String, chroma: String
        switch v.codec {
        case .h264: codec = "avc1"; chroma = "4:2:0"
        case .hevc: codec = "hvc1"; chroma = "4:2:0"
        case .prores422HQ: codec = "apch"; chroma = "4:2:2"
        case .prores422: codec = "apcn"; chroma = "4:2:2"
        case .prores422LT: codec = "apcs"; chroma = "4:2:2"
        case .prores422Proxy: codec = "apco"; chroma = "4:2:2"
        case .prores4444: codec = "ap4h"; chroma = "4:4:4"
        }
        self.init(codec: codec, width: v.width, height: v.height, bitDepth: v.bitDepth, chroma: chroma,
                  frameDuration: v.frameDuration, averageBitsPerSecond: v.codec.isMastering ? nil : v.bitrate.averageBitsPerSecond)
    }
}

/// The source stream facts the analysis needs (probed by the caller; nothing here reads files).
public struct SmartRenderSource: Sendable, Hashable {
    public var info: VideoTrackInfo
    /// Detected color space; nil = not detected (doubt: re-encode).
    public var colorSpace: ColorSpaceID?
    /// Presentation times of the sync samples, in the clip source's time base (`Clip.source`), ascending.
    public var syncSampleTimes: [Time]
    /// The sync samples start closed GOPs (IDR, no leading pictures that reference the GOP before). false = unknown.
    public var closedGOP: Bool
    public var averageBitsPerSecond: Int?

    public init(info: VideoTrackInfo, colorSpace: ColorSpaceID?, syncSampleTimes: [Time], closedGOP: Bool,
                averageBitsPerSecond: Int?) {
        self.info = info; self.colorSpace = colorSpace; self.syncSampleTimes = syncSampleTimes
        self.closedGOP = closedGOP; self.averageBitsPerSecond = averageBitsPerSecond
    }
}

/// Why a frame is re-encoded (the first failing check, in this order).
public enum SmartRenderReason: String, Sendable, Hashable, CaseIterable {
    case gap, composite, nestedOrGenerated, transition, captions, unknownSource, retimed, effects, transform
    case sourceFormat, sourceColor, color, bitrate, frameGrid
}

/// Output frames `frames` show `media` from `sourceStart` on, one source frame per output frame.
public struct SmartRenderRun: Sendable, Hashable {
    public var frames: Range<Int>
    public var clip: Clip.ID
    public var media: UUID
    public var sourceStart: Time
}

public struct SmartRenderPlan: Sendable, Hashable {
    public var totalFrames: Int
    /// Runs of eligible frames (before GOP alignment).
    public var runs: [SmartRenderRun]
    /// Whole closed GOPs inside the runs that could be copied (each at least the minimum length).
    public var passthrough: [SmartRenderRun]
    /// Frames re-encoded, by their first failing check.
    public var reasons: [SmartRenderReason: Int]

    public var eligibleFrames: Int { runs.reduce(0) { $0 + $1.frames.count } }
    public var passthroughFrames: Int { passthrough.reduce(0) { $0 + $1.frames.count } }
}

public enum SmartRender {
    static let rec709Tag = "ITU_R_709_2"
    /// A source may carry up to this much more than the target bitrate (the passed-through part would otherwise blow the
    /// file size or a platform's upload limit).
    static let bitrateTolerance = 1.25

    /// Plan for a whole sequence (no nesting is resolved: a nested clip is never eligible anyway).
    public static func plan(timeline: Timeline, range: TimeRange? = nil, sources: [UUID: SmartRenderSource],
                            target: SmartRenderTarget, burnIn: (Time) -> Bool = { _ in false },
                            minimumPassthroughFrames: Int) -> SmartRenderPlan {
        let r = range ?? TimeRange(start: .zero, duration: timeline.duration)
        let frames = ExportFrameCount.of(range: r, frameDuration: target.frameDuration)
        var clips: [Clip.ID: Clip] = [:]
        for track in timeline.tracks where track.kind == .video { for c in track.clips { clips[c.id] = c } }
        return plan(frameCount: frames, startTime: r.start, frameDuration: target.frameDuration,
                    layers: { timeline.videoLayers(at: $0) }, clips: clips, sources: sources, target: target,
                    burnIn: burnIn, minimumPassthroughFrames: minimumPassthroughFrames)
    }

    public static func plan(frameCount: Int, startTime: Time, frameDuration fd: Time, layers: (Time) -> [LayerRequest],
                            clips: [Clip.ID: Clip], sources: [UUID: SmartRenderSource], target: SmartRenderTarget,
                            burnIn: (Time) -> Bool = { _ in false }, minimumPassthroughFrames: Int) -> SmartRenderPlan {
        var reasons: [SmartRenderReason: Int] = [:]
        var runs: [SmartRenderRun] = []
        var last: (clip: Clip.ID, source: Time)?
        for i in 0..<max(0, frameCount) {
            let t = startTime + fd * Int64(i)
            let ls = layers(t)
            if let reason = check(ls, at: t, clips: clips, sources: sources, target: target, burnIn: burnIn) {
                reasons[reason, default: 0] += 1
                last = nil
                continue
            }
            let l = ls[0]
            if let p = last, p.clip == l.clip, p.source + fd == l.sourceTime, let k = runs.indices.last {
                runs[k].frames = runs[k].frames.lowerBound..<(i + 1)
            } else {
                runs.append(SmartRenderRun(frames: i..<(i + 1), clip: l.clip, media: l.media, sourceStart: l.sourceTime))
            }
            last = (l.clip, l.sourceTime)
        }
        let passthrough = runs.compactMap { run -> SmartRenderRun? in
            guard let s = sources[run.media], s.closedGOP else { return nil }
            return aligned(run, syncs: s.syncSampleTimes, frameDuration: fd, minimum: max(1, minimumPassthroughFrames))
        }
        return SmartRenderPlan(totalFrames: max(0, frameCount), runs: runs, passthrough: passthrough, reasons: reasons)
    }

    /// The first failing check for one output frame, nil = eligible.
    static func check(_ ls: [LayerRequest], at t: Time, clips: [Clip.ID: Clip], sources: [UUID: SmartRenderSource],
                      target: SmartRenderTarget, burnIn: (Time) -> Bool) -> SmartRenderReason? {
        guard let l = ls.first else { return .gap }
        guard ls.count == 1 else { return .composite }
        if !l.groups.isEmpty || l.generator != nil || l.shape != nil || l.clipDuration != nil { return .nestedOrGenerated }
        if l.pair != nil || l.inTransition { return .transition }
        if burnIn(t) { return .captions }
        guard let c = clips[l.clip], c.media == l.media, let s = sources[l.media] else { return .unknownSource }
        if c.isRetimed || c.holdFrame != nil || c.isStill || l.motionBlur != nil || l.interpolation != .frameSampling { return .retimed }
        if !c.effects.isEmpty || !l.effects.isIdentity || l.cornerRadius != 0 || l.blendMode != .normal { return .effects }
        if l.transform != .identity { return .transform }
        let v = s.info
        // Non-square pixels are desqueezed by the compositor: copying the stored frames would show them squeezed.
        if !v.displayPixelAspect.isSquare { return .sourceFormat }
        // Deinterlaced media: the stored samples are woven fields, the export is the progressive picture.
        if v.deinterlaceFieldOrder != nil { return .sourceFormat }
        if v.codec != target.codec || v.rotation != 0 || v.width != target.width || v.height != target.height
            || v.bitDepth != target.bitDepth || v.chroma != target.chroma
            || v.nominalFrameDuration != target.frameDuration || v.isVariableFrameRate { return .sourceFormat }
        if s.colorSpace != .rec709 || v.colorPrimaries != rec709Tag || v.transfer != rec709Tag || v.matrix != rec709Tag {
            return .sourceColor
        }
        if !l.color.isIdentity(rec709Source: true) { return .color }
        if let cap = target.averageBitsPerSecond {
            guard let b = s.averageBitsPerSecond, Double(b) <= Double(cap) * bitrateTolerance else { return .bitrate }
        }
        if !onGrid(l.sourceTime, target.frameDuration) { return .frameGrid }
        return nil
    }

    /// `t` is a whole number of frames.
    static func onGrid(_ t: Time, _ fd: Time) -> Bool {
        let n = Int128(t.value) * Int128(fd.timescale), d = Int128(t.timescale) * Int128(fd.value)
        return d != 0 && n % d == 0
    }

    /// The part of `run` from its first sync sample to its last one (whole GOPs), when at least `minimum` frames long.
    static func aligned(_ run: SmartRenderRun, syncs: [Time], frameDuration fd: Time, minimum: Int) -> SmartRenderRun? {
        let end = run.sourceStart + fd * Int64(run.frames.count)
        let inside = syncs.filter { $0 >= run.sourceStart && $0 <= end && onGrid($0 - run.sourceStart, fd) }
        guard let a = inside.first, let b = inside.last, a < b else { return nil }
        let off = frames(a - run.sourceStart, fd), len = frames(b - a, fd)
        guard len >= minimum else { return nil }
        let lo = run.frames.lowerBound + off
        return SmartRenderRun(frames: lo..<(lo + len), clip: run.clip, media: run.media, sourceStart: a)
    }

    static func frames(_ t: Time, _ fd: Time) -> Int {
        Int((Int128(t.value) * Int128(fd.timescale)) / (Int128(t.timescale) * Int128(fd.value)))
    }
}
