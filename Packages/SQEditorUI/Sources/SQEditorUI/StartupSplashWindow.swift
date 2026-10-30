import AppKit
import QuartzCore
import SQCore
import SQUIKit

/// Pip, the playhead mascot, drawn with Core Animation layers (no web view, no image asset). Geometry is the artwork's
/// 904 x 830 box (`pip-startbild` viewBox 60 250 904 830) with y flipped; the anchor is the tip under his chin, so he
/// stands on the timeline ruler like a playhead.
@MainActor final class SplashPip {
    static let artWidth: CGFloat = 904
    static let artHeight: CGFloat = 830
    /// Tip of the head: 95.18 % down the artwork box.
    static let tipAnchorY: CGFloat = 1 - 0.9518

    let art = CALayer()
    private let eyes = CALayer()
    private let eyeRects = [CALayer(), CALayer()]
    private var happy = [CAShapeLayer(), CAShapeLayer()]
    private let cheeks = CALayer()
    private let mouth = CAShapeLayer()
    private let smilePath: CGPath
    private let grinPath: CGPath
    private let flatPath: CGPath
    private let mouthO = CAShapeLayer()

    /// SVG point to art coordinates.
    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x - 60, y: 1080 - y) }

    init(height: CGFloat) {
        art.bounds = CGRect(x: 0, y: 0, width: Self.artWidth, height: Self.artHeight)
        art.anchorPoint = CGPoint(x: 0.5, y: Self.tipAnchorY)
        let p = Self.pt
        let head = CGMutablePath()
        head.move(to: p(261, 280))
        head.addLine(to: p(763, 280))
        head.addCurve(to: p(887, 404), control1: p(842.4, 280), control2: p(887, 324.6))
        head.addLine(to: p(887, 730))
        head.addCurve(to: p(812, 844), control1: p(887, 777.9), control2: p(851.6, 814.1))
        head.addLine(to: p(605.8, 1000))
        head.addCurve(to: p(418.2, 1000), control1: p(559.5, 1035), control2: p(464.5, 1035))
        head.addLine(to: p(212, 844))
        head.addCurve(to: p(137, 730), control1: p(172.4, 814.1), control2: p(137, 777.9))
        head.addLine(to: p(137, 404))
        head.addCurve(to: p(261, 280), control1: p(137, 324.6), control2: p(181.6, 280))
        head.closeSubpath()

        let fill = CAGradientLayer()
        fill.frame = art.bounds
        fill.colors = [Theme.Splash.pipTop.cgColor, Theme.Splash.pipBottom.cgColor]
        // Unit space is bottom-up: SVG gradient runs y 280 (top) to 1046.
        fill.startPoint = CGPoint(x: 0.5, y: (1080 - 280) / Self.artHeight)
        fill.endPoint = CGPoint(x: 0.5, y: (1080 - 1046) / Self.artHeight)
        let mask = CAShapeLayer()
        mask.frame = art.bounds
        mask.path = head
        fill.mask = mask
        art.addSublayer(fill)
        let edge = CAShapeLayer()
        edge.frame = art.bounds
        edge.path = head
        edge.fillColor = nil
        edge.strokeColor = Theme.Splash.pipEdge.cgColor
        edge.lineWidth = 8
        art.addSublayer(edge)

        // Cheeks (shown only in the Ready moment).
        cheeks.frame = art.bounds
        for cx in [286.0, 738.0] {
            let c = CAShapeLayer()
            c.path = CGPath(ellipseIn: CGRect(x: cx - 50 - 60, y: 1080 - 716 - 30, width: 100, height: 60), transform: nil)
            c.fillColor = Theme.Splash.pipCheek.cgColor
            cheeks.addSublayer(c)
        }
        cheeks.opacity = 0
        art.addSublayer(cheeks)

        eyes.frame = art.bounds
        for (i, x) in [347.5, 602.5].enumerated() {
            let r = eyeRects[i]
            r.backgroundColor = Theme.Splash.pipFace.cgColor
            r.frame = CGRect(x: x - 60, y: 1080 - 691, width: 74, height: 186)
            r.cornerRadius = r.bounds.width / 2
            eyes.addSublayer(r)
            let h = CAShapeLayer()
            let hp = CGMutablePath()
            hp.move(to: p(x - 12.5, 650))
            hp.addQuadCurve(to: p(x + 86.5, 650), control: p(x + 37, 580))
            h.path = hp
            h.fillColor = nil
            h.strokeColor = Theme.Splash.pipFace.cgColor
            h.lineWidth = 34
            h.lineCap = .round
            h.isHidden = true
            eyes.addSublayer(h)
            happy[i] = h
        }
        art.addSublayer(eyes)

        let smile = CGMutablePath()
        smile.move(to: p(434, 763))
        smile.addQuadCurve(to: p(590, 763), control: p(512, 837))
        smilePath = smile
        let grin = CGMutablePath()
        grin.move(to: p(418, 752))
        grin.addQuadCurve(to: p(606, 752), control: p(512, 862))
        grinPath = grin
        let flat = CGMutablePath()
        flat.move(to: p(462, 782))
        flat.addLine(to: p(562, 782))
        flatPath = flat
        mouthO.path = CGPath(ellipseIn: CGRect(x: 512 - 23 - 60, y: 1080 - 792 - 27, width: 46, height: 54), transform: nil)
        mouthO.fillColor = Theme.Splash.pipFace.cgColor
        mouthO.isHidden = true
        mouth.path = flat
        mouth.fillColor = nil
        mouth.strokeColor = Theme.Splash.pipFace.cgColor
        mouth.lineWidth = 33
        mouth.lineCap = .round
        art.addSublayer(mouth)
        art.addSublayer(mouthO)
        _ = height
    }

    private var lastBlink: CGFloat = -1, lastGaze: CGPoint?, lastHappy: Bool?, lastMouth: SplashMouth?

    /// `blink` 0 (open) ... 1 (closed), `gaze` in artwork units (y down like the SVG), `happy` swaps the eyes to
    /// the laughing arcs. Only touches layers whose value changed (a layer property write costs a commit even when equal).
    func apply(blink: CGFloat, gaze: CGPoint, happy isHappy: Bool, mouth kind: SplashMouth) {
        if blink != lastBlink || isHappy != lastHappy {
            let h = 186 - 164 * blink
            for r in eyeRects {
                r.frame = CGRect(x: r.frame.minX, y: 1080 - 691, width: 74, height: h)
                r.cornerRadius = min(r.bounds.width / 2, h / 2)
                r.isHidden = isHappy
            }
            lastBlink = blink
        }
        if isHappy != lastHappy {
            for s in happy { s.isHidden = !isHappy }
            lastHappy = isHappy
        }
        if kind != lastMouth {
            mouthO.isHidden = kind != .o
            mouth.isHidden = kind == .o
            switch kind {
            case .smile: mouth.path = smilePath
            case .grin: mouth.path = grinPath
            case .flat: mouth.path = flatPath
            case .o: break
            }
            lastMouth = kind
        }
        if gaze != lastGaze {
            eyes.transform = CATransform3DMakeTranslation(gaze.x, -gaze.y, 0)
            let m = CATransform3DMakeTranslation(gaze.x * 0.5, -gaze.y * 0.5, 0)
            mouth.transform = m
            mouthO.transform = m
            lastGaze = gaze
        }
    }

    /// Transform for the given size, squash and rotation (degrees, clockwise) about the tip anchor.
    static func transform(height: CGFloat, sx: CGFloat, sy: CGFloat, rotation: CGFloat) -> CATransform3D {
        let s = height / artHeight
        let t = CATransform3DMakeScale(s * sx, s * sy, 1)
        return CATransform3DRotate(t, -rotation * .pi / 180, 0, 0, 1)
    }
}

/// Everything that moves, as a pure function of the sequencer state and time. The window renders it once as model
/// values and once as a short keyframe lookahead that the render server plays without the main thread.
struct SplashFrame {
    var clipWidths: [CGFloat], tip: CGPoint, transform: CATransform3D, opacity: Float
    var blink: CGFloat, gaze: CGPoint, happy: Bool, mouth: SplashMouth, ready: Bool, alpha: CGFloat
}

/// The two title lines exactly as the design mock sets them (62 px, line-height 1 = 62 px pitch, top 50): one text
/// layer per line, placed from real font metrics, so the pitch never depends on how a text layer treats line height.
enum SplashTitle {
    static let lines = ["Sequence", "Studio"]
    static let fontSize: CGFloat = 62
    /// Distance between baselines (CSS `line-height: 1` at 62 px).
    static let lineHeight: CGFloat = 62
    static let top: CGFloat = 50
    static let x: CGFloat = 50
    /// Top of the version label (design y = 184).
    static let versionTop: CGFloat = 184

    static var font: NSFont { NSFont.systemFont(ofSize: fontSize, weight: NSFont.Weight(rawValue: 0.44)) }
    static func attributed(_ line: String) -> NSAttributedString {
        NSAttributedString(string: line, attributes: [
            .font: font, .foregroundColor: Theme.Splash.title, .kern: -0.035 * fontSize])
    }
    /// Baseline of line `i`, measured down from the window top: the font's content area is centered in the line box.
    static func baseline(_ i: Int) -> CGFloat {
        let f = font
        let ascent = f.ascender, descent = -f.descender
        return top + CGFloat(i) * lineHeight + (lineHeight - (ascent + descent)) / 2 + ascent
    }
    /// Text layer frame (window coordinates, y up): ascent above the baseline, descent plus padding below, so no glyph
    /// is clipped.
    static func frame(line i: Int, windowHeight: CGFloat) -> CGRect {
        let f = font
        let h = ceil(f.ascender - f.descender) + 6
        let layerTop = baseline(i) - f.ascender
        return CGRect(x: x, y: windowHeight - layerTop - h, width: 360, height: h)
    }
    /// Lowest ink of the block: "Studio" has no descender, so it is the last baseline.
    static var inkBottom: CGFloat { baseline(lines.count - 1) }
}

/// Borderless 800 x 500 startup splash (DECISIONS 2026-10-14). Content is drawn from `SplashSequencer` time on every
/// display-link frame: Pip drives along the mini timeline and the clips grow with the real startup progress (scene F1,
/// DECISIONS 2026-10-14), the status line is the real step.
@MainActor final class StartupSplashWindow: NSObject, StartupSplashPresenting {
    private static let size = Theme.Splash.size
    private static let pipHeight: CGFloat = SplashScene.pipWidth * SplashPip.artHeight / SplashPip.artWidth

    private let panel: NSPanel
    private let root = CALayer()
    private var clipLayers: [CALayer] = []
    private let status = CATextLayer()
    private(set) var titleLayers: [CATextLayer] = []
    private let pip = SplashPip(height: pipHeight)
    private var sequencer = SplashSequencer()
    private var statusText = ""
    private var shownStatus = ""
    private var lastAlpha: CGFloat = -1
    private var lastLinkTime: TimeInterval?
    private var linkDts: [Double] = []
    private var startTime: TimeInterval?
    private var link: CADisplayLink?
    private var selfRetain: StartupSplashWindow?
    var onGone: (() -> Void)?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private let blinks = StartupSplashWindow.blinkTimes()

    override init() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)
        let host = NSView(frame: NSRect(origin: .zero, size: Self.size))
        host.wantsLayer = true
        p.contentView = host
        p.animationBehavior = .none   // no system zoom-in on orderFront (looked like a slow grow)
        panel = p
        super.init()
        build(host: host)
    }

    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, frame: CGRect,
                      kern: CGFloat = 0, lineHeight: CGFloat? = nil) -> CATextLayer {
        let l = CATextLayer()
        let style = NSMutableParagraphStyle()
        if let lh = lineHeight { style.minimumLineHeight = lh; style.maximumLineHeight = lh }
        l.string = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern,
            .paragraphStyle: style])
        l.frame = frame
        l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        l.isWrapped = false
        return l
    }

    private func build(host: NSView) {
        let H = Self.size.height
        root.frame = CGRect(origin: .zero, size: Self.size)
        root.cornerRadius = Theme.Modal.radius
        root.masksToBounds = true
        host.layer?.addSublayer(root)

        let bg = CAGradientLayer()
        bg.frame = root.bounds
        bg.colors = [Theme.Splash.backgroundTop.cgColor, Theme.Splash.backgroundBottom.cgColor]
        bg.startPoint = CGPoint(x: 0.5, y: 1)
        bg.endPoint = CGPoint(x: 0.5, y: 0)
        root.addSublayer(bg)

        let field = CALayer()
        field.frame = CGRect(x: Theme.Splash.fieldX, y: 0, width: Self.size.width - Theme.Splash.fieldX, height: H)
        field.contentsGravity = .resizeAspectFill
        field.masksToBounds = true
        if let url = Bundle.main.url(forResource: "SplashField", withExtension: "png"), let img = NSImage(contentsOf: url) {
            field.contents = img
        }
        root.addSublayer(field)

        for (i, line) in SplashTitle.lines.enumerated() {
            let l = CATextLayer()
            l.string = SplashTitle.attributed(line)
            l.frame = SplashTitle.frame(line: i, windowHeight: H)
            l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            l.isWrapped = false
            titleLayers.append(l)
            root.addSublayer(l)
        }
        root.addSublayer(text(SQL10n.format("Version %@", AppVersion.display), size: 16, weight: .regular,
                              color: Theme.Splash.version, frame: CGRect(x: 54, y: H - 184 - 22, width: 340, height: 22)))
        addTimelineCard()

        status.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        status.frame = CGRect(x: 52, y: H - 451 - 18, width: 330, height: 18)
        root.addSublayer(status)
        root.addSublayer(text(SQL10n.string("Free and open source · GPL-3.0"), size: 11.5, weight: .regular,
                              color: Theme.Splash.credit, frame: CGRect(x: 52, y: H - 476 - 15, width: 330, height: 15)))
        root.addSublayer(pip.art)
        draw(elapsed: 0, animated: false)
    }

    private func addTimelineCard() {
        let H = Self.size.height
        func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: H - top - h, width: w, height: h) }
        let card = CALayer()
        card.frame = rect(SplashScene.cardX, SplashScene.cardTop, SplashScene.cardWidth, SplashScene.cardHeight)
        card.backgroundColor = Theme.Splash.cardFill.cgColor
        card.cornerRadius = SplashScene.cardRadius
        card.borderWidth = 1
        card.borderColor = Theme.Splash.cardBorder.cgColor
        root.addSublayer(card)
        // Ruler contents live in a clip layer with the card's rounded rect, so nothing pokes over the corners.
        let clip = CALayer()
        clip.frame = card.frame
        clip.cornerRadius = SplashScene.cardRadius
        clip.masksToBounds = true
        root.addSublayer(clip)
        // Ruler ticks every 14 pt in the top 22 pt.
        var x: CGFloat = SplashScene.cardX
        while x < SplashScene.cardX + SplashScene.cardWidth {
            let tick = CALayer()
            tick.frame = CGRect(x: x - SplashScene.cardX, y: SplashScene.cardHeight - SplashScene.rulerHeight,
                                width: 1, height: SplashScene.rulerHeight)
            tick.backgroundColor = Theme.Splash.rulerTick.cgColor
            clip.addSublayer(tick)
            x += 14
        }
        let line = CALayer()
        line.frame = CGRect(x: 0, y: SplashScene.cardHeight - SplashScene.rulerHeight - 1, width: SplashScene.cardWidth, height: 1)
        line.backgroundColor = Theme.Splash.rulerLine.cgColor
        clip.addSublayer(line)
        for c in SplashScene.clips {
            let l = CAGradientLayer()
            l.colors = [c.color.top.cgColor, c.color.bottom.cgColor]
            l.startPoint = CGPoint(x: 0.5, y: 1)
            l.endPoint = CGPoint(x: 0.5, y: 0)
            l.anchorPoint = CGPoint(x: 0, y: 0.5)
            l.bounds = CGRect(x: 0, y: 0, width: 0, height: SplashScene.clipHeight)
            l.position = CGPoint(x: c.start, y: H - SplashScene.rowTops[c.row] - SplashScene.clipHeight / 2)
            l.cornerRadius = SplashScene.clipRadius
            l.borderWidth = 1
            l.borderColor = Theme.Splash.clipBorder.cgColor
            root.addSublayer(l)
            clipLayers.append(l)
        }
    }

    /// Hashed blink schedule (no random state): roughly every 1.7 to 5.3 s, sometimes a double blink.
    private static func blinkTimes() -> [Double] {
        func hash(_ n: Double) -> Double { let x = sin(n * 127.1 + 311.7) * 43758.5453; return x - x.rounded(.down) }
        var out: [Double] = [], t = 1.1, i = 0.0
        while t < 300 {
            out.append(t)
            if hash(i + 0.5) > 0.78 { out.append(t + 0.34) }
            t += 1.7 + hash(i * 3.3) * 3.6
            i += 1
        }
        return out
    }

    private func blink(at t: Double) -> CGFloat {
        guard let b = blinks.last(where: { $0 <= t }) else { return 0 }
        let d = t - b
        guard d < 0.25 else { return 0 }
        let u = d < 0.1 ? d / 0.1 : 1 - (d - 0.1) / 0.15
        let c = CGFloat(min(1, max(0, u)))
        return c * c * (3 - 2 * c)
    }

    /// Pure frame at time `t` for the given sequencer state.
    private func frame(_ seq: SplashSequencer, _ t: TimeInterval) -> SplashFrame {
        let ready = seq.phase != .loading
        let amp: Double = reduceMotion ? 0 : 1
        // No scale-in: it was driven per tick on the main thread, so a blocked launch left Pip tiny for ~1.5 s.
        let intro = 1.0
        let tau = reduceMotion ? SplashScene.endTime
            : SplashScene.tau(progress: seq.progress, ready: ready, readyElapsed: seq.readyElapsed)
        let p = SplashScene.pose(at: tau)
        let breathe = CGFloat(sin(t * 1.9) * 0.011 * amp)
        let sway = 0.0 * amp   // no sway: a rotation about the tip reads as a bump
        let gx = p.ex + CGFloat(sin(t * 0.8) * 1.6 * amp) / (Self.pipHeight / SplashPip.artHeight)
        let widths = SplashScene.clips.map { reduceMotion ? $0.end - $0.start : SplashScene.clipWidth($0, at: tau) }
        return SplashFrame(
            clipWidths: widths,
            tip: CGPoint(x: p.x, y: Self.size.height - SplashScene.tipY - p.y),
            transform: SplashPip.transform(height: Self.pipHeight * CGFloat(intro), sx: p.sx * (1 - breathe * 0.5),
                                           sy: p.sy * (1 + breathe), rotation: p.r + CGFloat(sway)),
            opacity: 1,
            blink: p.happy || reduceMotion || ready ? 0 : blink(at: t), gaze: CGPoint(x: gx, y: p.ey),
            happy: p.happy, mouth: reduceMotion ? .smile : p.mouth, ready: ready || reduceMotion, alpha: CGFloat(seq.alpha))
    }

    private static let travelSteps = 60
    /// True once the one render-server travel animation (x and clip widths, same clock) has been added.
    private var travelOwned = false

    /// Draws the frame at `t` as model values. The travel (Pip's x and the clip widths) is NOT re-planned per tick: it is
    /// one precomputed time-based animation (`startTravel`) that the render server plays even while the main thread is
    /// blocked in startup work. A tick only writes y, transform, opacity, face and status.
    private func draw(elapsed t: TimeInterval, animated: Bool = true) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var f = frame(sequencer, t)
        if travelOwned {
            // Model holds the END of the travel; the running animation shows the in-between.
            f.tip.x = SplashScene.stations[4]
            f.clipWidths = SplashScene.clips.map { SplashScene.clipWidth($0, at: SplashScene.driveEnd) }
        }
        for (l, w) in zip(clipLayers, f.clipWidths) { l.bounds.size.width = w }
        pip.art.position = f.tip
        pip.art.transform = f.transform
        pip.art.opacity = f.opacity
        pip.apply(blink: f.blink, gaze: f.gaze, happy: f.happy, mouth: f.mouth)
        let text = f.ready ? SQL10n.string("Ready") : statusText
        if text != shownStatus {
            shownStatus = text
            status.string = NSAttributedString(string: text, attributes: [
                .font: Theme.Splash.statusFont, .foregroundColor: Theme.Splash.status])
        }
        if f.alpha != lastAlpha { panel.alphaValue = f.alpha; lastAlpha = f.alpha }
        if Self.trace {
            let px = pip.art.presentation()?.position.x
            let model = SplashScene.travelX(at: SplashScene.driveEnd * SplashSequencer.pace(t))
            let tr = pip.art.transform
            let pres = pip.art.presentation()?.transform.m11 ?? -1
            let b = panel.contentView?.bounds ?? .zero
            SQLog.info(String(format: "SQSplashTrace sinceLaunch %.3f t %.3f win %.0fx%.0f content %.0fx%.0f root %.0fx%.0f pipScale %.3f pres %.3f opacity %.2f link %@ model %.1f presX %.1f progress %.3f",
                              Self.sinceLaunch(), t, panel.frame.width, panel.frame.height, b.width, b.height,
                              root.bounds.width, root.bounds.height, Double(tr.m11), Double(pres), Double(pip.art.opacity),
                              fromLink ? "yes" : "no", Double(model), Double(px ?? -1), sequencer.progress))
        }
    }

    /// Adds the single travel animation: x and all clip widths sampled from the same time curve (`pace`), one duration,
    /// one clock. Never replaced afterwards.
    private func startTravel() {
        guard !reduceMotion, !travelOwned else { return }
        travelOwned = true
        let n = Self.travelSteps, d = SplashSequencer.minDisplay
        let us = (0...n).map { SplashSequencer.pace(Double($0) / Double(n) * d) }
        func anim(_ key: String, _ values: [Double]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: key)
            a.values = values
            a.duration = d
            a.calculationMode = .linear
            a.isRemovedOnCompletion = true
            return a
        }
        let tau = { (u: Double) in SplashScene.driveEnd * u }
        pip.art.add(anim("position.x", us.map { Double(SplashScene.travelX(at: tau($0))) }), forKey: "travel.x")
        for (l, c) in zip(clipLayers, SplashScene.clips) {
            l.add(anim("bounds.size.width", us.map { Double(SplashScene.clipWidth(c, at: tau($0))) }), forKey: "travel.w")
        }
    }

    private var fromLink = false

    /// Seconds since this process was started (kernel start time).
    private static func sinceLaunch() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let st = info.kp_proc.p_un.__p_starttime
        return Date().timeIntervalSince1970 - (Double(st.tv_sec) + Double(st.tv_usec) / 1e6)
    }

    private static let trace = ProcessInfo.processInfo.environment["SQ_SPLASH_TRACE"] != nil

    private var elapsed: TimeInterval {
        guard let s = startTime else { return 0 }
        return ProcessInfo.processInfo.systemUptime - s
    }

    private func tick() {
        let t = elapsed
        sequencer.advance(to: t)
        draw(elapsed: t)
        if sequencer.phase == .done { finishUp() }
    }

    private func finishUp() {
        if !linkDts.isEmpty {
            let ms = linkDts.map { $0 * 1000 }
            SQLog.info(String(format: "SQSplash frames %d, dt avg %.1f ms, max %.1f ms, over 25 ms: %d", ms.count,
                              ms.reduce(0, +) / Double(ms.count), ms.max() ?? 0, ms.filter { $0 > 25 }.count))
        }
        link?.invalidate()
        link = nil
        panel.orderOut(nil)
        selfRetain = nil
        let done = onGone
        onGone = nil
        done?()
    }

    @objc private func displayLinkFired(_ l: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastLinkTime { linkDts.append(now - last) }
        lastLinkTime = now
        fromLink = true
        tick()
        fromLink = false
    }

    // MARK: StartupSplashPresenting

    func show() {
        NSApp.setActivationPolicy(.regular)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - Self.size.width / 2, y: f.midY - Self.size.height / 2 + f.height * 0.06))
        }
        startTime = ProcessInfo.processInfo.systemUptime
        panel.orderFrontRegardless()
        selfRetain = self   // the reporter drops its reference at `finish`; the fade still has to run
        if let view = panel.contentView {
            let l = view.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        startTravel()
        tick()
        // First frames go to the render server before the heavy startup work blocks the main thread.
        panel.contentView?.displayIfNeeded()
        CATransaction.flush()
    }

    func update(_ log: StartupLog) {
        if let s = log.steps.last { statusText = SQL10n.string(s) + "…" }
        // The main thread is busy loading: draw now instead of waiting for the next display-link frame.
        tick()
        panel.contentView?.displayIfNeeded()
        CATransaction.flush()
    }

    /// Startup finished: clips to 100 %, "Ready", fade (the display link keeps running on the freed main thread).
    func close() {
        guard startTime != nil else { return }
        sequencer.requestFinish()
        tick()
    }

    /// Render harness: a still of the content at the given progress and time, window not shown.
    func renderStill(log: StartupLog, at time: TimeInterval = 4) -> NSView? {
        if let s = log.steps.last { statusText = SQL10n.string(s) + "…" }
        if log.isFinished { sequencer.requestFinish() }
        var t = 0.0
        while t < time { t += 0.05; sequencer.advance(to: t) }
        draw(elapsed: time, animated: false)
        return panel.contentView
    }
}

/// Render harness entry for the splash content (the real splash is built before the app controller exists).
@MainActor public enum StartupSplashRender {
    public static func view(log: StartupLog) -> NSView? {
        StartupSplashWindow().renderStill(log: log)
    }
}
