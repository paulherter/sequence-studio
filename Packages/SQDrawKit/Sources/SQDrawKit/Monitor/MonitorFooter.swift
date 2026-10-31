import Foundation
import SQCore
import SQUIKit

// The footer of the Program and Source monitors (Mac SQMonitorUI `MonitorPanelView` footer and `MonitorScrubBar`),
// translated to the portable canvas: the same scrub math, the same gesture rules, the same look. The Mac view keeps
// its AppKit shell and uses `MonitorScrubMath` from here.

/// Maths of the strip under a monitor's picture: x position <-> time over the whole duration.
public struct MonitorScrubMath: Sendable, Equatable {
    public var duration: Time
    public var frameDuration: Time
    public var width: CGFloat
    /// Space on both sides (v9 `.mtr` padding: track from 12 to width - 12).
    public var inset: CGFloat = 12

    public init(duration: Time, frameDuration: Time, width: CGFloat, inset: CGFloat = 12) {
        self.duration = duration; self.frameDuration = frameDuration; self.width = width; self.inset = inset
    }

    private var span: CGFloat { max(width - 2 * inset, 1) }

    /// Frame-snapped time under `x`, clamped to the first and last frame.
    public func time(atX x: CGFloat) -> Time {
        guard duration > .zero else { return .zero }
        let f = Double(min(max((x - inset) / span, 0), 1))
        let scale: Int64 = 100_000
        let raw = Time(Int64((f * Double(scale)).rounded()) * duration.value, scale * duration.timescale)
        return min(raw.snapped(to: frameDuration), max(.zero, duration - frameDuration))
    }

    /// What a mouse-down at `x` grabs: the In or Out grip (when marks are given and within `slop` points), else the playhead
    /// (scrubbing). The nearest grip wins; a tie goes to the grip so a mark just set at the playhead can still be dragged.
    public enum Hit: Sendable, Equatable { case markIn, markOut, playhead }
    public static let hitSlop: CGFloat = 6

    public func hit(x: CGFloat, markIn: Time?, markOut: Time?, slop: CGFloat = MonitorScrubMath.hitSlop) -> Hit {
        var best: (Hit, CGFloat)?
        for (hit, mark) in [(Hit.markIn, markIn), (Hit.markOut, markOut)] {
            guard let m = mark else { continue }
            let d = abs(self.x(for: m) - x)
            if d <= slop, best == nil || d < best!.1 { best = (hit, d) }
        }
        return best?.0 ?? .playhead
    }

    public func x(for t: Time) -> CGFloat {
        guard duration > .zero else { return inset }
        let f = Double(t.value) / Double(t.timescale) / (Double(duration.value) / Double(duration.timescale))
        return inset + span * CGFloat(min(max(f, 0), 1))
    }

    /// Mark In and stored Mark Out of a range gesture from two frames in either order (Out is stored one frame past the last).
    public static func range(_ a: Time, _ b: Time, frameDuration: Time) -> (markIn: Time, markOut: Time) {
        (min(a, b), max(a, b) + frameDuration)
    }

    /// The range moved by `delta`, same length, kept inside 0...duration.
    public func movedRange(markIn: Time, markOut: Time, by delta: Time) -> (markIn: Time, markOut: Time) {
        let len = markOut - markIn
        var i = markIn + delta
        if i + len > duration { i = duration - len }
        if i < .zero { i = .zero }
        return (i, i + len)
    }
}


/// The marks state the footer draws and edits (MonitorPanelModel's fields the scrub bar and row read).
public struct MonitorFooterState: Sendable, Equatable {
    public var mode: MonitorMode
    public var currentTime: Time = .zero
    public var duration: Time = .zero
    public var frameDuration: Time
    public var markIn: Time?
    public var markOut: Time?
    public var markerTimes: [Time] = []
    public var isPlaying = false
    /// The host edits marks (MonitorPanelModel.marksEditable: an `onMarkEdit` and not a source file view).
    public var marksEditable = true
    /// Source monitor showing a file: marks are locked, dragging the empty track scrubs.
    public var sourceFileView = false
    public var timecode: Timecode

    public init(mode: MonitorMode, frameDuration: Time, dropFrame: Bool = false) {
        self.mode = mode; self.frameDuration = frameDuration
        timecode = Timecode(frameDuration: frameDuration, dropFrame: dropFrame)
    }

    public var hasRange: Bool { markIn != nil || markOut != nil }
    public var durationText: String { timecode.format(duration) }
    /// Length between In and Out (Out defaults to the end, In to the start); nil when neither is set.
    public var inOutDurationText: String? {
        guard hasRange else { return nil }
        let len = (markOut ?? duration) - (markIn ?? .zero)
        return timecode.format(len < .zero ? .zero : len)
    }
    public var footerDurationText: String { inOutDurationText ?? durationText }

    /// Drag preview: moves the In or Out to the frame `frame` (`.playhead` is ignored). Out is stored one frame past it.
    /// (MonitorPanelModel.previewMark.)
    public mutating func previewMark(_ end: MonitorScrubMath.Hit, frame: Time) {
        switch end {
        case .markIn:
            markIn = frame
            if let o = markOut, o <= frame { markOut = nil }
        case .markOut:
            let out = frame + frameDuration
            markOut = out
            if let i = markIn, i >= out { markIn = nil }
        case .playhead: break
        }
    }

    /// Drag preview of the whole range (middle drag, or a new range dragged out on the bar): stored In and stored Out.
    public mutating func previewRange(markIn newIn: Time, markOut newOut: Time) {
        markIn = newIn
        markOut = max(newOut, newIn + frameDuration)
    }
}

/// What the footer asks the host for (MonitorPanelModel's callbacks: perform, onScrub/onSeek, previewMark/Range, commit).
public enum MonitorFooterEvent: Sendable, Equatable {
    case action(MonitorAction)
    case scrubBegan, scrub(Time), scrubEnded
    /// A drag preview of one mark or of the whole range (the host draws it, nothing is stored yet).
    case previewMark(MonitorScrubMath.Hit, Time)
    case previewRange(markIn: Time, markOut: Time)
    /// Mouse-up: store the previewed mark / range as one undo step.
    case commitMark(MonitorScrubMath.Hit)
    case commitRange(MonitorRangeCommit)
    /// Right-click on the strip: the host opens `MonitorFooter.markMenu` at this point.
    case markMenu(x: CGFloat, y: CGFloat)
    /// Return in the timecode field (the Mac `commitTimecode`): the host parses and seeks (`commitTimecodeText`).
    case commitTimecode(String)
}

/// Which range gesture ended (MonitorPanelModel.commitRange's kinds).
public enum MonitorRangeCommit: Sendable, Equatable { case body, newRange }

/// The scrub strip gesture (MonitorScrubBar's mouse handling). Click scrubs, dragging the playhead scrubs; drag an edge
/// moves that mark, drag inside the range moves the whole range, drag on empty track marks a new range.
public struct MonitorScrubGesture: Sendable {
    enum Drag: Sendable, Equatable {
        case scrub
        case grip(MonitorScrubMath.Hit)
        case moveRange(startX: CGFloat, markIn: Time, markOut: Time)
        case pending(startX: CGFloat)
        case newRange(anchor: Time)
    }
    private(set) var drag: Drag?
    public init() {}
    public var isActive: Bool { drag != nil }

    /// What a press at `x` picks up. Order: an edge, the playhead, the inside of the range, else empty track.
    static func target(atX x: CGFloat, _ s: MonitorFooterState, _ m: MonitorScrubMath) -> Drag {
        if s.marksEditable {
            let grip = m.hit(x: x, markIn: s.markIn, markOut: s.markOut)
            if grip != .playhead { return .grip(grip) }
        }
        if abs(m.x(for: s.currentTime) - x) <= MonitorScrubMath.hitSlop { return .scrub }
        if s.marksEditable, s.hasRange {
            let i = s.markIn ?? .zero, o = s.markOut ?? s.duration
            if x > m.x(for: i), x < m.x(for: o) { return .moveRange(startX: x, markIn: i, markOut: o) }
        }
        return .pending(startX: x)
    }

    /// Hover cursor: resize at a grip, open hand inside the range, else arrow.
    public enum Cursor: Sendable, Equatable { case arrow, resizeLeftRight, openHand }
    public static func cursor(atX x: CGFloat, _ s: MonitorFooterState, _ m: MonitorScrubMath) -> Cursor {
        switch target(atX: x, s, m) {
        case .grip: .resizeLeftRight
        case .moveRange: .openHand
        default: .arrow
        }
    }

    private static func scrub(_ t: Time) -> MonitorFooterEvent { .scrub(t) }

    public mutating func down(x: CGFloat, _ s: MonitorFooterState, _ m: MonitorScrubMath) -> [MonitorFooterEvent] {
        guard s.duration > .zero else { return [] }
        let d = Self.target(atX: x, s, m)
        drag = d
        switch d {
        case .grip(let h): return [.previewMark(h, m.time(atX: x))]
        case .scrub: return [.scrubBegan, .scrub(m.time(atX: x))]
        default: return []
        }
    }

    public mutating func dragged(x: CGFloat, _ s: MonitorFooterState, _ m: MonitorScrubMath) -> [MonitorFooterEvent] {
        guard let d = drag else { return [] }
        switch d {
        case .scrub: return [.scrub(m.time(atX: x))]
        case .grip(let h): return [.previewMark(h, m.time(atX: x))]
        case .moveRange(let startX, let i, let o):
            let r = m.movedRange(markIn: i, markOut: o, by: m.time(atX: x) - m.time(atX: startX))
            return [.previewRange(markIn: r.markIn, markOut: r.markOut)]
        case .pending(let startX):
            guard abs(x - startX) > 3 else { return [] }
            if s.sourceFileView {                     // marks are locked: dragging the empty track scrubs
                drag = .scrub; return [.scrubBegan, .scrub(m.time(atX: x))]
            }
            drag = .newRange(anchor: m.time(atX: startX))
            return dragged(x: x, s, m)
        case .newRange(let anchor):
            let r = MonitorScrubMath.range(anchor, m.time(atX: x), frameDuration: s.frameDuration)
            return [.previewRange(markIn: r.markIn, markOut: r.markOut)]
        }
    }

    public mutating func up(x: CGFloat, _ s: MonitorFooterState, _ m: MonitorScrubMath) -> [MonitorFooterEvent] {
        defer { drag = nil }
        switch drag {
        case .grip(let h): return [.commitMark(h)]
        case .moveRange: return [.commitRange(.body)]
        case .newRange: return [.commitRange(.newRange)]
        case .scrub: return [.scrubEnded]
        case .pending: return [.scrubBegan, .scrub(m.time(atX: x)), .scrubEnded]   // a click on empty track: seek there
        case nil: return []
        }
    }
}

/// The monitor footer (v9 `.mtr`): scrub bar on top, then one row: timecode left | five buttons centered | In/Out icon
/// + the one duration (+ Source: Insert / Overwrite) right. Sizes in points; the canvas scales.
public struct MonitorFooter: Sendable {
    public static let height: CGFloat = 66          // Theme.Metrics.monitorFooter
    public static let scrubHeight: CGFloat = 16     // Theme.Metrics.scrubBar
    static let rowHeight: CGFloat = 28
    static let smallGlyph: CGFloat = 12
    static let playGlyph: CGFloat = 16
    static let smallBox: CGFloat = 24               // Theme.Row.controlLarge
    static let timecodeWidth: CGFloat = 92
    static let gripWidth: CGFloat = 3
    static let buttonGap: CGFloat = 2               // Theme.Spacing.xxs
    static let iconToLabel: CGFloat = 6

    /// Icon and title per footer action (MonitorPanelView.symbols).
    public static let symbols: [MonitorAction: (SQIcon, String)] = [
        .markIn: (.markIn, "Mark In"), .markOut: (.markOut, "Mark Out"),
        .goToIn: (.goToStart, "Go to In"), .goToOut: (.goToEnd, "Go to Out"),
        .stepBack: (.stepBack, "Step Back"), .stepForward: (.stepForward, "Step Forward"),
        .playPause: (.play, "Play"), .addMarker: (.marker, "Add Marker"),
        .insert: (.insertEdit, "Insert"), .overwrite: (.overwriteEdit, "Overwrite"),
        .lift: (.arrowUpFromLine, "Clear Range"), .extract: (.arrowUpToLine, "Delete Range"),
        .exportFrame: (.camera, "Export Frame"),
    ]

    public private(set) var frame = CGRect.zero
    public private(set) var scrubRect = CGRect.zero
    public private(set) var timecodeRect = CGRect.zero
    public private(set) var durationRect = CGRect.zero
    public private(set) var inOutIconRect = CGRect.zero
    /// Footer buttons in drawing order (transport, then the Source edit buttons).
    public private(set) var buttons: [(MonitorAction, CGRect)] = []
    /// Source monitor: the Drag Video Only / Drag Audio Only handles at the right end (the Mac `StreamDragView` pair);
    /// a press starts a drag of that stream onto the timeline (the panel runs it). Dropped first when narrow.
    public private(set) var streamHandles: [(SourceStreams, CGRect)] = []
    /// Board `.hdl`: 26 x 22 capsule, 2 pt between the two.
    static let handleSize = CGSize(width: 26, height: 22)
    static let handleGap: CGFloat = 2
    public var hovered: MonitorAction?
    public var pressed: MonitorAction?
    public private(set) var gesture = MonitorScrubGesture()
    /// The timecode field while it is edited (Go to Timecode or a click on it); nil = it shows the time.
    public private(set) var timecodeEdit: TextEditState?
    /// A press on the timecode: where it began and the time then; past 3 pt it is a scrub (the Mac `TimecodeField`).
    private var timecodePress: (x: CGFloat, start: Time, dragging: Bool)?

    public init() {}

    public func scrubMath(_ s: MonitorFooterState) -> MonitorScrubMath {
        MonitorScrubMath(duration: s.duration, frameDuration: s.frameDuration, width: scrubRect.width)
    }

    /// Lays the footer out in `r` (its full width, `height` tall). Narrow panels drop the edit buttons, then the
    /// duration (MonitorPanelView.layout's order of loss); timecode and the five buttons always stay.
    public mutating func layout(_ r: CGRect, _ s: MonitorFooterState, durationWidth: CGFloat) {
        frame = r
        scrubRect = CGRect(x: r.minX, y: r.minY + 8, width: r.width, height: Self.scrubHeight)
        let rowMid = r.maxY - 8 - Self.rowHeight / 2
        timecodeRect = CGRect(x: r.minX + 12 - 2, y: rowMid - Self.rowHeight / 2, width: Self.timecodeWidth, height: Self.rowHeight)
        let bar = MonitorAction.buttonBar(for: s.mode)
        func w(_ a: MonitorAction) -> CGFloat { a == .playPause ? Self.rowHeight : Self.smallBox }
        let transportW = bar.map(w).reduce(0, +) + Self.buttonGap * CGFloat(bar.count - 1)
        let edits: [MonitorAction] = s.mode == .source ? [.insert, .overwrite] : []
        let iconW: CGFloat = 14
        let editsW = edits.isEmpty ? 0 : CGFloat(edits.count) * (Self.smallBox + Self.iconToLabel)
        let handles: [SourceStreams] = s.mode == .source ? [.videoOnly, .audioOnly] : []
        let handlesW = handles.isEmpty ? 0 : 2 * Self.handleSize.width + Self.handleGap + Self.iconToLabel
        // Transport centered on the footer, never left of the timecode; the right group (marks, duration, edits, handles)
        // must start after where the transport really ends, so it drops pieces from the outside in instead of overlapping.
        let transportStart = max((r.midX - transportW / 2).rounded(), timecodeRect.maxX)
        let room = r.maxX - 12 - (transportStart + transportW + 4)
        let base = iconW + Self.iconToLabel + durationWidth
        var showEdits = !edits.isEmpty, showDuration = true
        let showHandles = !handles.isEmpty && room >= base + editsW + handlesW
        if room < base + editsW { showEdits = false }
        if room < base { showDuration = false }
        var x = max((r.midX - transportW / 2).rounded(), timecodeRect.maxX)
        buttons = []
        for a in bar {
            let bw = w(a)
            buttons.append((a, CGRect(x: x, y: rowMid - bw / 2, width: bw, height: bw)))
            x += bw + Self.buttonGap
        }
        var right = r.maxX - 12
        streamHandles = []
        if showHandles {
            for h in handles.reversed() {
                right -= Self.handleSize.width
                streamHandles.insert((h, CGRect(x: right, y: rowMid - Self.handleSize.height / 2, width: Self.handleSize.width,
                                                height: Self.handleSize.height)), at: 0)
                right -= Self.handleGap
            }
            right += Self.handleGap - Self.iconToLabel
        }
        if showEdits {
            for a in edits.reversed() {
                right -= Self.smallBox
                buttons.append((a, CGRect(x: right, y: rowMid - Self.smallBox / 2, width: Self.smallBox, height: Self.smallBox)))
                right -= Self.iconToLabel
            }
        }
        durationRect = showDuration ? CGRect(x: right - durationWidth, y: rowMid - Self.rowHeight / 2, width: durationWidth,
                                             height: Self.rowHeight) : .zero
        if showDuration { right -= durationWidth + Self.iconToLabel }
        inOutIconRect = CGRect(x: right - iconW, y: rowMid - iconW / 2, width: iconW, height: iconW)
    }

    public func button(at p: CGPoint) -> MonitorAction? { buttons.first { $0.1.contains(p) }?.0 }
    /// The stream handle under `p` (Source monitor).
    public func streamHandle(at p: CGPoint) -> SourceStreams? { streamHandles.first { $0.1.contains(p) }?.0 }

    /// Drag tip under the ghost (StreamDragView.tipText).
    public static func dragTip(_ streams: SourceStreams) -> String {
        switch streams { case .both: "Video and audio"; case .videoOnly: "Video only"; case .audioOnly: "Audio only" }
    }
    /// The handle's icon (and the ghost's): film for video, waveform for audio, sequence for both.
    public static func dragIcon(_ streams: SourceStreams) -> SQIcon {
        streams == .audioOnly ? .waveform : streams == .videoOnly ? .film : .sequence
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, _ s: MonitorFooterState, theme t: DrawTheme) {
        drawScrubBar(&c, s, theme: t)
        let size: CGFloat = 12    // Theme.Typography.shell / shellStrong
        if timecodeEdit != nil { drawTimecodeEdit(&c, theme: t) } else {
            c.draw(s.timecode.format(s.currentTime), in: timecodeRect, fontSize: size, t.accent, align: .left, face: c.semibold)   // shellStrong
        }
        for (a, r) in buttons {
            let isPlay = a == .playPause
            if pressed == a { c.fill(roundedRect: r, radius: isPlay ? 6 : 4, t.fillPressed) }
            else if hovered == a { c.fill(roundedRect: r, radius: isPlay ? 6 : 4, t.fillHover) }
            let glyph = isPlay ? Self.playGlyph : Self.smallGlyph
            let icon: SQIcon = isPlay ? (s.isPlaying ? .pause : .play) : Self.symbols[a]!.0
            c.draw(icon: icon, at: CGPoint(x: r.midX - glyph / 2, y: r.midY - glyph / 2), size: glyph,
                   isPlay ? t.label : t.label2)
        }
        for (h, r) in streamHandles {
            // StreamDragView.draw: fill2 capsule with a hairline edge, the 14 pt icon in label2.
            c.fill(roundedRect: r, radius: r.height / 2, t.fill)
            c.stroke(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), radius: r.height / 2, width: 0.5, t.separator)
            c.draw(icon: Self.dragIcon(h), at: CGPoint(x: r.midX - 7, y: r.midY - 7), size: 14, t.label2)
        }
        c.draw(icon: .markInOut, at: inOutIconRect.origin, size: inOutIconRect.width, t.label3)
        if durationRect.width > 0 {
            c.draw(s.footerDurationText, in: durationRect, fontSize: size, t.label3, align: .right)
        }
    }

    /// MonitorScrubBar.draw: 2 pt bar at y 7, In to Out as a 6 pt tinted band at y 5, 3 x 12 accent grips, yellow
    /// marker triangles above the track, playhead 2 x 14 at y 1.
    public func drawScrubBar(_ c: inout Canvas, _ s: MonitorFooterState, theme t: DrawTheme) {
        let m = scrubMath(s)
        c.saveGState()
        c.translateBy(x: scrubRect.minX, y: scrubRect.minY)
        let track = CGRect(x: m.inset, y: 7, width: max(scrubRect.width - 2 * m.inset, 0), height: 2)
        c.fill(roundedRect: track, radius: track.height / 2, t.fillPressed)
        if s.hasRange {
            let a = m.x(for: s.markIn ?? .zero), b = m.x(for: s.markOut ?? s.duration)
            if b > a {
                let band = CGRect(x: a, y: 5, width: b - a, height: 6)
                c.fill(roundedRect: band, radius: band.height / 2, t.accentTint)
            }
        }
        for (mark, isIn) in [(s.markIn, true), (s.markOut, false)] {
            guard let mark else { continue }
            let hx = m.x(for: mark)
            let grip = CGRect(x: isIn ? hx : hx - Self.gripWidth, y: 2, width: Self.gripWidth, height: 12)
            c.fill(roundedRect: grip, radius: grip.width / 2, t.accent)
        }
        for time in s.markerTimes {
            let mx = m.x(for: time)
            c.fill(polygon: [CGPoint(x: mx - 3, y: 0), CGPoint(x: mx + 3, y: 0), CGPoint(x: mx, y: 5)], t.yellow)
        }
        let x = m.x(for: s.currentTime)
        c.fill(roundedRect: CGRect(x: x - 1, y: 1, width: 2, height: 14), radius: 1, t.playhead)
        c.restoreGState()
    }

    // MARK: Input (points, footer coordinates of the canvas)

    public mutating func mouseDown(_ p: CGPoint, _ s: MonitorFooterState, right: Bool = false,
                                   caretIndex: ((CGFloat) -> Int)? = nil) -> [MonitorFooterEvent] {
        if !right, timecodeRect.contains(p) {
            if var e = timecodeEdit {            // a click in the open field moves the caret
                if let caretIndex { e.place(caretIndex(p.x - timecodeRect.minX)) } else { e.selectAll() }
                timecodeEdit = e
            } else {
                timecodePress = (p.x, s.currentTime, false)
            }
            return []
        }
        timecodeEdit = nil                       // a press elsewhere ends the edit; the field shows the time again
        if scrubRect.contains(p) {
            if right { return s.duration > .zero ? [.markMenu(x: p.x, y: p.y)] : [] }
            return gesture.down(x: p.x - scrubRect.minX, s, scrubMath(s))
        }
        if !right, let a = button(at: p) { pressed = a }
        return []
    }
    public mutating func mouseDragged(_ p: CGPoint, _ s: MonitorFooterState) -> [MonitorFooterEvent] {
        if var tp = timecodePress {
            let dx = p.x - tp.x
            var out: [MonitorFooterEvent] = []
            if !tp.dragging, abs(dx) > 3 { tp.dragging = true; out.append(.scrubBegan) }
            timecodePress = tp
            guard tp.dragging else { return out }
            // `MonitorPanelModel.time(offsetFrom:frames:)`: 1 frame per 2 pt, never before 0, on the frame grid.
            let frames = Int64((dx / 2).rounded())
            return out + [.scrub(max(.zero, (tp.start + s.frameDuration * frames).snapped(to: s.frameDuration)))]
        }
        return gesture.dragged(x: p.x - scrubRect.minX, s, scrubMath(s))
    }
    public mutating func mouseUp(_ p: CGPoint, _ s: MonitorFooterState) -> [MonitorFooterEvent] {
        if let tp = timecodePress {
            timecodePress = nil
            if tp.dragging { return [.scrubEnded] }
            beginTimecodeEdit(s)                 // a click opens the field with its text selected
            return []
        }
        if gesture.isActive { return gesture.up(x: p.x - scrubRect.minX, s, scrubMath(s)) }
        defer { pressed = nil }
        if let a = pressed, button(at: p) == a { return [.action(a)] }
        return []
    }
    public mutating func mouseMoved(_ p: CGPoint) { hovered = button(at: p) }

    // MARK: Timecode field (the Mac `MonitorPanelView.timecodeField`)

    public var isEditingTimecode: Bool { timecodeEdit != nil }

    /// Go to Timecode and a click on the timecode: the position text, all selected.
    public mutating func beginTimecodeEdit(_ s: MonitorFooterState) {
        timecodeEdit = TextEditState(s.timecode.position(s.currentTime), selectAll: true)
    }

    public mutating func endTimecodeEdit() { timecodeEdit = nil }

    /// A key while the field is open (nil = not editing): Return commits, Esc puts the time back.
    public mutating func timecodeKey(_ k: InputKey, modifiers: InputModifiers) -> [MonitorFooterEvent]? {
        guard var e = timecodeEdit else { return nil }
        switch e.handle(k, modifiers: modifiers) {
        case .commit: timecodeEdit = nil; return [.commitTimecode(e.string)]
        case .cancel: timecodeEdit = nil; return []
        default: timecodeEdit = e; return []
        }
    }

    /// The caret offsets of the field's text from its left edge (12 pt glyphs as drawn); a click maps through them.
    public static func timecodeCarets(_ text: String, measure: (String) -> CGFloat) -> [CGFloat] {
        let chars = Array(text)
        return (0...chars.count).map { measure(String(chars.prefix($0))) }
    }

    /// Index of the caret nearest to `x` (offset from the field's left edge).
    public static func caretIndex(at x: CGFloat, carets: [CGFloat]) -> Int {
        carets.indices.min { abs(carets[$0] - x) < abs(carets[$1] - x) } ?? 0
    }

    private func drawTimecodeEdit(_ c: inout Canvas, theme t: DrawTheme) {
        guard let e = timecodeEdit else { return }
        let r = timecodeRect, size: CGFloat = 12
        let semibold = c.semibold
        let xs = Self.timecodeCarets(e.string) { c.size(of: $0, fontSize: size, face: semibold).width }
        let lineH: CGFloat = 16, top = (r.midY - lineH / 2).rounded()
        if e.hasSelection {
            let x0 = xs[e.selection.lowerBound], x1 = xs[e.selection.upperBound]
            c.fill(CGRect(x: r.minX + x0, y: top, width: x1 - x0, height: lineH), t.accent.alpha(0.3))
        }
        c.draw(e.string, in: r, fontSize: size, t.accent, align: .left, face: semibold)
        let cx = r.minX + xs[min(e.caret, xs.count - 1)]
        c.strokeLine(from: CGPoint(x: cx, y: top), to: CGPoint(x: cx, y: top + lineH), width: 1, t.accent)
        HostRequests.current.caret = c.px(CGRect(x: cx, y: top, width: 0, height: lineH))
    }

    /// The scrub bar's right-click menu (MonitorPanelModel.markMenu): title, action, enabled.
    public static func markMenu(_ s: MonitorFooterState) -> [(title: String, action: MonitorAction, enabled: Bool)?] {
        let editable = !s.sourceFileView
        return [("Remove In", .clearIn, editable && s.markIn != nil), ("Remove Out", .clearOut, editable && s.markOut != nil),
                ("Remove In and Out", .clearInOut, editable && s.hasRange), nil,
                ("Go to In", .goToIn, s.hasRange), ("Go to Out", .goToOut, s.hasRange)]
    }
}
