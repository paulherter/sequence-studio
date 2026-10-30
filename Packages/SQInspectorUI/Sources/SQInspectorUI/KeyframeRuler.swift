import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQEditorSession

/// Pure tick layout of the Effect Controls ruler (same x mapping as the keyframe lanes, zoom included).
public enum KeyframeRulerLayout {
    public struct Tick: Equatable, Sendable {
        /// Clip-local time.
        public var local: Time
        public var major: Bool
    }

    /// Ticks over the whole clip range 0...duration for the given lane width.
    public static func ticks(width: CGFloat, duration: Time, frameDuration: Time, nominalFPS: Int) -> [Tick] {
        ticks(geometry: KeyframeLaneGeometry(width: width, duration: duration), frameDuration: frameDuration, nominalFPS: nominalFPS)
    }

    /// Ticks inside the visible window only (a long clip zoomed to a few frames must not produce a tick per frame of the clip).
    public static func ticks(geometry geo: KeyframeLaneGeometry, frameDuration: Time, nominalFPS: Int) -> [Tick] {
        let frames = geo.duration.frameIndex(frameDuration: frameDuration)
        guard frames > 0 else { return [] }
        let fdSecs = Double(frameDuration.value) / Double(frameDuration.timescale)
        let ppf = geo.pointsPerSecond * fdSecs
        guard ppf > 0 else { return [] }
        let scale = RulerScale.scale(pointsPerFrame: ppf, nominalFPS: nominalFPS)
        let minor = Int64(max(scale.minorFrames, 1)), major = Int64(max(scale.majorFrames, 1))
        // Visible frames, with one tick of slack on each side (the lane inset is 10 pt).
        let first = max(Int64(((geo.viewStart - 12 / max(geo.pointsPerSecond, 1e-9)) / fdSecs).rounded(.down)), 0)
        let last = min(Int64(((geo.viewStart + geo.viewSpan + 12 / max(geo.pointsPerSecond, 1e-9)) / fdSecs).rounded(.up)), frames)
        guard first <= last else { return [] }
        var out: [Tick] = []
        var f = (first / minor) * minor
        while f <= last {
            out.append(Tick(local: frameDuration * f, major: f % major == 0))
            f += minor
        }
        return out
    }

    /// Timeline time for a pointer x in the ruler, frame-snapped and clamped to the clip.
    public static func seekTime(atX x: CGFloat, width: CGFloat, clipStart: Time, duration: Time, frameDuration: Time) -> Time {
        clipStart + KeyframeLaneGeometry(width: width, duration: duration).time(at: x, frameDuration: frameDuration)
    }

    /// "00:00:15:00" -> "15:00", "00:01:05:12" -> "1:05:12": the mini ruler drops the leading zero groups (v9 `.kruler`).
    public static func shortLabel(_ timecode: String) -> String {
        var parts = timecode.split(whereSeparator: { $0 == ":" || $0 == ";" }).map(String.init)
        guard parts.count > 2 else { return timecode }
        while parts.count > 2, let n = Int(parts[0]), n == 0 { parts.removeFirst() }
        if parts.count > 2, let n = Int(parts[0]) { parts[0] = String(n) }
        return parts.joined(separator: ":")
    }
}

/// The clip line of Effect Controls (v9 `.clhead`): its texts, shared by the Mac view and the shared-toolkit panel.
public enum EffectControlsHeaderText {
    /// "Video · 00:00:02:00": the clip line's tooltip (kind and duration).
    public static func clipInfo(kind: TrackKind, duration: Time, frameDuration: Time, kindName: String? = nil) -> String {
        let tc = TimecodeFormat(frameDuration: frameDuration)
        return "\(kindName ?? (kind == .audio ? "Audio" : "Video")) \u{00B7} \(tc.string(for: duration, frameDuration: frameDuration))"
    }

    /// "Main · V1 · 00:00:15:00 – 00:00:17:00" (v9 `.clhead .m`): sequence, track and the clip's range in the sequence.
    /// `kindName` (Text, Shape, Graphic ...) leads when the clip is not plain video or audio.
    public static func clipMeta(sequence: String?, track: String?, start: Time, end: Time, frameDuration: Time, kindName: String? = nil) -> String {
        let tc = TimecodeFormat(frameDuration: frameDuration)
        let range = "\(tc.string(for: start, frameDuration: frameDuration)) \u{2013} \(tc.string(for: end, frameDuration: frameDuration))"
        return ([kindName, sequence, track].compactMap { $0 }.filter { !$0.isEmpty } + [range]).joined(separator: " \u{00B7} ")
    }
}
