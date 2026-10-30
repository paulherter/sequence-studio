import Foundation
import SQAudioFX
import SQCore
import SQDrawKit
import SQUIKit

/// The Source monitor's drag sources (the Mac `StreamDragView`): the picture drags both streams, the footer's film and
/// waveform handles drag one. The drag starts after 4 pt of movement and reports window pixels, so the host can hover
/// and drop on the timeline as it does for Project list drags.
public enum MonitorDragPhase: Sendable, Equatable { case moved, ended, canceled }

/// The level meter beside the Source waveform (SourceWaveformView's `meter`): the Source player's own output,
/// the same ballistics as the Program meter; the readout click clears the clip latch, a label click solos (Alt: mutes).
public struct SourceWaveMeter: Sendable {
    public var meter = AudioMeter()
    public private(set) var channelMonitor = ChannelMonitor()
    private var feed = MeterFeed()
    private var lastBufferTime: Double = 0
    /// No new buffer for this long = stopped: the bars fall to zero at once (SourceWaveformView.staleSeconds).
    static let staleSeconds: Double = 0.15

    public init() {}

    /// One poll: `reading` is the Source engine's meter feed with its identity.
    public mutating func poll(_ reading: (source: ObjectIdentifier, sequence: Int, peaks: [Float])?, now: Double) {
        if let peaks = feed.peaks(for: reading) {
            lastBufferTime = now
            meter.update(peaks: peaks, at: now)
        } else if now - lastBufferTime > Self.staleSeconds, !meter.isSettled {
            meter.silence()
        }
        meter.tick(at: now)
    }

    public var labels: [MeterChannelLabel] {
        meter.channelNames.indices.map { i in
            let chs = meter.channels(forBar: i, channelCount: ChannelMonitor.channelCount)
            if chs.allSatisfy(channelMonitor.isMuted) { return .muted }
            if chs.allSatisfy(channelMonitor.isSoloed) { return .soloed }
            if !chs.contains(where: channelMonitor.isAudible) { return .silenced }
            return .normal
        }
    }

    /// A click at `p` (meter coordinates, `height` tall); true when Solo / Mute changed.
    public mutating func click(_ p: CGPoint, height: CGFloat, alt: Bool) -> Bool {
        switch meter.hit(p, height: height) {
        case .resetClip: meter.resetClip(); return false
        case .channel(let bar):
            let chs = meter.channels(forBar: bar, channelCount: ChannelMonitor.channelCount)
            if alt { channelMonitor.toggleMute(chs) } else { channelMonitor.toggleSolo(chs) }
            return true
        case .none: return false
        }
    }
}

extension MonitorPanel {
    /// The meter column right of the Source waveform (zero when no meter feed is set or the waveform is not shown).
    public var waveMeterRect: CGRect {
        guard showsWaveform, waveMeterReading != nil else { return .zero }
        return CGRect(x: slot.maxX - AudioMeter.width - Self.waveInset / 2, y: slot.minY, width: AudioMeter.width, height: slot.height)
    }

    /// Width the waveform and its scrub map use: the meter column is not part of it.
    var waveContentWidth: CGFloat {
        waveMeterRect.width > 0 ? max(1, slot.width - AudioMeter.width - Self.waveInset) : slot.width
    }

    /// Per frame while the Source tab shows (the Mac 30 Hz timer).
    public func pollWaveMeter(now: Double) {
        guard showsWaveform, let r = waveMeterReading else { return }
        waveMeter.poll(r(), now: now)
    }

    func drawWaveMeter(_ c: inout Canvas) {
        let r = waveMeterRect
        guard r.width > 0 else { return }
        waveMeter.meter.draw(&c, in: r, theme: theme, labels: waveMeter.labels)
    }

    /// Press on the Source picture or a stream handle: a drag may start (the 4 pt threshold runs in `sourceDragMoved`).
    /// False when there is nothing to drag (no clip, no host hook).
    func beginSourceDragPress(_ streams: SourceStreams, at p: CGPoint) -> Bool {
        guard model.mode == .source, onSourceDrag != nil, emptyText == nil else { return false }
        sourceDrag = SourceDragState(streams: streams, start: p, active: false)
        return true
    }

    /// A pointer move with a press pending or a drag running; `x`, `y` in window pixels.
    func sourceDragMoved(_ p: CGPoint, x: Float, y: Float) {
        guard var d = sourceDrag else { return }
        if !d.active {
            guard hypot(p.x - d.start.x, p.y - d.start.y) > 4 else { return }
            d.active = true
            sourceDrag = d
        }
        onSourceDrag?(d.streams, .moved, x, y)
    }

    /// The press ended: drops when the drag ran (a plain click does nothing, as on the Mac).
    func sourceDragEnded(x: Float, y: Float, canceled: Bool = false) {
        guard let d = sourceDrag else { return }
        sourceDrag = nil
        guard d.active else { return }
        onSourceDrag?(d.streams, canceled ? .canceled : .ended, x, y)
        model.onDragEnded?()
    }

    /// The drag running now (its streams), for the host's ghost; nil while only pressed.
    public var activeSourceDrag: SourceStreams? { sourceDrag.flatMap { $0.active ? $0.streams : nil } }
}

struct SourceDragState {
    var streams: SourceStreams
    var start: CGPoint
    var active: Bool
}

/// The tile that follows the pointer during a Source drag (the Mac `StreamDragView.ghostImage` drag image): a 60 x 106
/// tile with the streams' icon and a tip box under it, the tile centered on the pointer.
public enum SourceDragGhost {
    public static let tile = CGSize(width: 60, height: 106)
    static let gap: CGFloat = 6, pad: CGFloat = 4

    public static func tipText(_ streams: SourceStreams) -> String {
        switch streams { case .both: "Video and audio"; case .videoOnly: "Video only"; case .audioOnly: "Audio only" }
    }

    /// Tile and tip box for the pointer `p` (points) and a tip `tipWidth` wide; the Mac drag frame's placement.
    public static func layout(pointer p: CGPoint, tipWidth: CGFloat) -> (tile: CGRect, tip: CGRect) {
        let tipBox = CGSize(width: ceil(tipWidth) + 12, height: 20)
        let width = max(tile.width, tipBox.width) + 2 * pad
        let origin = CGPoint(x: p.x - tile.width / 2, y: p.y - tile.height / 2)
        let t = CGRect(x: origin.x + (width - tile.width) / 2, y: origin.y + pad, width: tile.width, height: tile.height)
        let box = CGRect(x: origin.x + (width - tipBox.width) / 2, y: t.maxY + gap, width: tipBox.width, height: tipBox.height)
        return (t, box)
    }

    public static func draw(_ c: inout Canvas, streams: SourceStreams, pointer p: CGPoint, theme t: DrawTheme) {
        let tip = tipText(streams), size = CGFloat(DrawTheme.TypeSize.caption)
        let r = layout(pointer: p, tipWidth: c.size(of: tip, fontSize: size).width)
        let radius = CGFloat(DrawTheme.Radius.control)
        c.fill(roundedRect: r.tile, radius: radius, t.fill)
        c.stroke(roundedRect: r.tile, radius: radius, width: 1.5, t.yellow)
        let icon: SQIcon = streams == .audioOnly ? .waveform : streams == .videoOnly ? .film : .sequence
        c.draw(icon: icon, at: CGPoint(x: r.tile.midX - 11, y: r.tile.midY - 11), size: 22, t.label2)
        c.fill(roundedRect: r.tip, radius: radius, t.overlay)
        c.draw(tip, in: r.tip.insetBy(dx: 6, dy: 0), fontSize: size, t.label)
    }
}
