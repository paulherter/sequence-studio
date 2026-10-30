import Foundation
import SQCore

/// The clip body layout both timelines share (the Mac `ClipDrawing`, the canvas `TimelinePanel`): the name strip on top
/// of a tall clip and the area under it where the waveform, the thumbnails and the volume / opacity lines live.
public enum ClipBodyMetrics {
    public static let nameStripHeight: CGFloat = 13
    /// Tracks at least this tall put the name in a top band and keep waveform / thumbnails below it (one fill, no second tone).
    public static let bodyMinHeight: CGFloat = 26

    /// Board `.thh`: the thumbnail column of a media video clip, 25 pt wide, a 1 px dark rule on its right.
    public static let thumbnailWidth: CGFloat = 25

    /// The thumbnail column a clip that is not flat (and not offline) gets in a row of `rowHeight`: `width`, or 0 when the
    /// row is too low or the clip too narrow for it.
    public static func thumbnailColumn(clipWidth: CGFloat, rowHeight: CGFloat, width: CGFloat) -> CGFloat {
        rowHeight - 2 >= bodyMinHeight && clipWidth >= width + 24 ? width : 0
    }

    /// The waveform area inside a clip's full rectangle (also where the volume line moves).
    public static func waveformRect(in rect: CGRect) -> CGRect {
        let body = rect.insetBy(dx: 0, dy: 1)
        let top = body.height >= bodyMinHeight ? body.minY + nameStripHeight : body.minY
        return CGRect(x: body.minX, y: top + 1, width: body.width, height: body.maxY - top - 2)
    }
}

/// What a clip's waveform shows: the level it plays at and, with a speed track, where each point of the clip reads its
/// source (the inputs of `WaveformPath.Input`).
public enum ClipAudioCurves {
    /// Level in dB at seconds since the clip start for the waveform: Volume line plus Audio Gain.
    public static func volumeDB(of clip: Clip) -> @Sendable (Double) -> Double {
        let c = clip
        if !c.animation.volume.isAnimated {          // no keys: one level for the whole clip, not one evaluation per column
            let db = AudioGain.db(fromLinear: c.volume(at: c.start))
            return { _ in db }
        }
        return { sec in
            // `sec` counts source seconds from the clip's source start: map through speed and direction.
            let t = c.timelineTime(forSource: c.source.start + Time(Int64((sec * 1_000_000).rounded()), 1_000_000))
            return AudioGain.db(fromLinear: c.volume(at: t))
        }
    }

    /// Waveform mapping of a clip with a speed track: clip fraction -> source seconds since `source.start` (nil for constant clips).
    public static func sourceMap(of clip: Clip) -> (@Sendable (Double) -> Double)? {
        guard let k = clip.speedKeys else { return nil }
        let total = Double(k.duration.value) / Double(k.duration.timescale)
        let base = Double(clip.source.start.value) / Double(clip.source.start.timescale)
        return { f in k.positionApprox(atSeconds: f * total) - base }
    }
}
