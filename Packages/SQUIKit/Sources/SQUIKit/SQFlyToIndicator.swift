import AppKit

/// The export send-off (docs/EXPORT-SENDOFF.md): the dialog card's picture holds where the card was, then presses, arcs
/// and folds into the status-bar job ring, which answers with a receive pulse. Purely visual. The math is pure (`plan`),
/// the AppKit part only builds layers with Core Animation keyframes (no per-frame main-thread work) and removes them once.
public enum SQFlyToIndicator {
    public struct Plan: Equatable, Sendable {
        /// False under Reduce Motion or with an unusable frame: the card does not move (Reduce Motion: it only fades).
        public var flies: Bool
        /// Length of the card tracks; 0 = no card at all.
        public var cardDuration: Double
        /// Normalized 0...1 times shared by every card track.
        public var keyTimes: [Double]
        public var positions: [CGPoint]
        public var scaleX: [Double]
        public var scaleY: [Double]
        /// Z rotation in radians.
        public var rotation: [Double]
        public var opacity: [Double]
        /// Accent tint over the picture, 0...1.
        public var tint: [Double]
        public var shadow: [Double]
        /// In the card's unscaled units.
        public var cornerRadius: [Double]
        /// Quadratic arc control point (same space as source/target).
        public var control: CGPoint
        public var pulseBegin: Double
        public var pulseDuration: Double
        /// End scale of the outline halo; 1 = opacity only.
        public var pulseGrowth: Double

        public var total: Double { max(cardDuration, pulseBegin + pulseDuration) }
    }

    public static let cardSeconds = 0.44
    /// Share of `cardSeconds` spent on the press before the card leaves.
    public static let pressShare = 0.14
    public static let pulseBeginSeconds = 0.38
    public static let pulseSeconds = 0.2
    public static let samples = 41
    public static let maxSway = 2.5 * Double.pi / 180

    static func smoothstep(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }

    /// Travel progress 0...1 at normalized card time `t` (0 during the press).
    static func travel(_ t: Double) -> Double { smoothstep((t - pressShare) / (1 - pressShare)) }

    static func arcControl(source s: CGPoint, target e: CGPoint) -> CGPoint {
        let dy = e.y - s.y
        let lift = -(dy == 0 ? 0 : dy / abs(dy)) * abs(dy) * 0.06
        return CGPoint(x: s.x + (e.x - s.x) * 0.85, y: s.y + dy * 0.15 + lift)
    }

    /// `source` and `target` in the same coordinate space. The card ends exactly on the target's frame.
    public static func plan(source: CGRect, target: CGRect, reduceMotion: Bool) -> Plan {
        let usable = source.width > 0 && source.height > 0 && target.width > 0 && target.height > 0
        let s = CGPoint(x: source.midX, y: source.midY)
        if !usable || reduceMotion {
            let fade = usable ? 0.2 : 0
            return Plan(flies: false, cardDuration: fade, keyTimes: [0, 1], positions: [s, s], scaleX: [1, 1], scaleY: [1, 1],
                        rotation: [0, 0], opacity: [1, 0], tint: [0, 0], shadow: [1, 0],
                        cornerRadius: [Double(Theme.Dialog.cardRadius), Double(Theme.Dialog.cardRadius)], control: s,
                        pulseBegin: usable ? 0.08 : 0, pulseDuration: reduceMotion ? 0.22 : pulseSeconds, pulseGrowth: 1)
        }
        let e = CGPoint(x: target.midX, y: target.midY)
        let c = arcControl(source: s, target: e)
        let endX = Double(target.width / source.width), endY = Double(target.height / source.height)
        let r0 = Double(Theme.Dialog.cardRadius), r1 = Double(min(source.width, source.height)) / 2
        var p = Plan(flies: true, cardDuration: cardSeconds, keyTimes: [], positions: [], scaleX: [], scaleY: [], rotation: [],
                     opacity: [], tint: [], shadow: [], cornerRadius: [], control: c,
                     pulseBegin: pulseBeginSeconds, pulseDuration: pulseSeconds, pulseGrowth: 1.7)
        for i in 0..<samples {
            let t = Double(i) / Double(samples - 1)
            let u = travel(t)
            let press = t < pressShare ? sin(.pi / 2 * t / pressShare) : 1
            let dip = (1 - u)  // the press eases out as the card travels, so the end scale is exact
            let a = 1 - u, b = u
            let x = a * a * Double(s.x) + 2 * a * b * Double(c.x) + b * b * Double(e.x)
            let y = a * a * Double(s.y) + 2 * a * b * Double(c.y) + b * b * Double(e.y)
            p.keyTimes.append(t)
            p.positions.append(CGPoint(x: x, y: y))
            p.scaleX.append((1 - 0.03 * press * dip) * pow(endX, u))
            p.scaleY.append((1 - 0.04 * press * dip) * pow(endY, pow(u, 0.85)))
            p.rotation.append(-maxSway * sin(.pi * u))
            p.opacity.append(1 - smoothstep((u - 0.78) / 0.22))
            p.tint.append(smoothstep((u - 0.45) / 0.4))
            p.shadow.append(1 - smoothstep(u / 0.4))
            p.cornerRadius.append(r0 + (r1 - r0) * pow(u, 1.5))
        }
        return p
    }

    /// The card's picture and its frame in its window's coordinates, taken while the card is still showing.
    public struct Snapshot {
        let image: NSImage
        let windowFrame: CGRect
    }

    @MainActor public static func snapshot(of card: NSView) -> Snapshot? {
        guard card.window != nil, let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return nil }
        card.cacheDisplay(in: card.bounds, to: rep)
        let image = NSImage(size: card.bounds.size)
        image.addRepresentation(rep)
        return Snapshot(image: image, windowFrame: card.convert(card.bounds, to: nil))
    }

    /// Puts the card's picture over `host`'s content where the card was (call right before the sheet closes), so nothing
    /// blinks while the export's preflight runs. Then `send(to:)` or `cancel()`. The sheet window shares the host's
    /// frame, so window coordinates match.
    @MainActor public static func hold(_ shot: Snapshot, in host: NSWindow) -> SendOff? {
        guard let content = host.contentView else { return nil }
        return SendOff(shot: shot, content: content)
    }

    @MainActor public final class SendOff {
        private let overlay = PassThroughView()
        private let shot: Snapshot
        private let card = CALayer()
        private let picture = CALayer()
        private let tint = CALayer()
        private var finished = false

        init(shot: Snapshot, content: NSView) {
            self.shot = shot
            overlay.frame = content.bounds
            overlay.autoresizingMask = [.width, .height]
            overlay.wantsLayer = true
            content.addSubview(overlay, positioned: .above, relativeTo: nil)
            let frame = overlay.convert(shot.windowFrame, from: nil)
            let scale = content.window?.backingScaleFactor ?? 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.bounds = CGRect(origin: .zero, size: frame.size)
            card.position = CGPoint(x: frame.midX, y: frame.midY)
            card.shadowColor = Theme.black(1).cgColor
            card.shadowOpacity = 0.45
            card.shadowRadius = 18
            card.shadowOffset = CGSize(width: 0, height: -6)
            card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: Theme.Dialog.cardRadius,
                                     cornerHeight: Theme.Dialog.cardRadius, transform: nil)
            picture.frame = card.bounds
            picture.contents = shot.image
            picture.contentsGravity = .resize
            picture.contentsScale = scale
            picture.cornerRadius = Theme.Dialog.cardRadius
            picture.cornerCurve = .continuous
            picture.borderWidth = Theme.Overlay.edgeWidth
            picture.borderColor = Theme.Colors.overlayEdge.cgColor
            picture.masksToBounds = true
            tint.frame = picture.bounds
            tint.backgroundColor = Theme.Colors.accent.cgColor
            tint.opacity = 0
            picture.addSublayer(tint)
            card.addSublayer(picture)
            overlay.layer?.addSublayer(card)
            CATransaction.commit()
        }

        /// The export was queued: the card folds into `indicator` (a view in the same window), which pulses.
        public func send(to indicator: NSView?, reduceMotion: Bool? = nil) {
            guard !finished else { return }
            finished = true
            let reduce = reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let overlay = self.overlay
            let source = overlay.convert(shot.windowFrame, from: nil)
            let target = indicator.flatMap { $0.window === overlay.window ? overlay.convert($0.convert($0.bounds, to: nil), from: nil) : nil } ?? .zero
            var p = plan(source: source, target: target, reduceMotion: reduce)
            if target == .zero { p.cardDuration = 0.2; p.pulseDuration = 0 }  // no ring: plain fade in place
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { overlay.removeFromSuperview() } }
            animateCard(p)
            if p.pulseDuration > 0 { pulse(target: target, plan: p) }
            CATransaction.commit()
        }

        /// A preflight question comes up or the export was canceled: the picture fades out quickly.
        public func cancel() {
            guard !finished else { return }
            finished = true
            let overlay = self.overlay
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { overlay.removeFromSuperview() } }
            card.add(Self.track("opacity", [1, 0], times: [0, 1], duration: Theme.Motion.fast), forKey: "fade")
            card.opacity = 0
            CATransaction.commit()
        }

        private static func track(_ key: String, _ values: [Any], times: [Double], duration: Double, begin: Double = 0) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: key)
            a.values = values
            a.keyTimes = times.map { NSNumber(value: $0) }
            a.duration = duration
            a.beginTime = begin == 0 ? 0 : CACurrentMediaTime() + begin
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            return a
        }

        private func animateCard(_ p: Plan) {
            guard p.cardDuration > 0 else { card.opacity = 0; return }
            let d = p.cardDuration, t = p.keyTimes
            let move = Self.track("position", p.positions.map { NSValue(point: $0) }, times: t, duration: d)
            move.calculationMode = .cubic
            card.add(move, forKey: "move")
            card.add(Self.track("transform.scale.x", p.scaleX, times: t, duration: d), forKey: "sx")
            card.add(Self.track("transform.scale.y", p.scaleY, times: t, duration: d), forKey: "sy")
            card.add(Self.track("transform.rotation.z", p.rotation, times: t, duration: d), forKey: "sway")
            card.add(Self.track("opacity", p.opacity, times: t, duration: d), forKey: "fade")
            card.add(Self.track("shadowOpacity", p.shadow.map { $0 * 0.45 }, times: t, duration: d), forKey: "shadow")
            picture.add(Self.track("cornerRadius", p.cornerRadius, times: t, duration: d), forKey: "fold")
            tint.add(Self.track("opacity", p.tint, times: t, duration: d), forKey: "tint")
            // Model values at the end state, so nothing flashes back between the last frame and removal.
            card.opacity = 0
            card.position = p.positions.last ?? card.position
        }

        private func pulse(target: CGRect, plan p: Plan) {
            let side = max(target.width, target.height)
            let box = CGRect(x: target.midX - side / 2, y: target.midY - side / 2, width: side, height: side)
            let halo = CALayer()
            halo.frame = box
            halo.cornerRadius = side / 2
            halo.borderWidth = 2
            halo.borderColor = Theme.Colors.accent.cgColor
            halo.opacity = 0
            overlay.layer?.addSublayer(halo)
            let grow = Self.track("transform.scale", [1, p.pulseGrowth], times: [0, 1], duration: p.pulseDuration, begin: p.pulseBegin)
            grow.timingFunction = Theme.Motion.Curve.easeOut.timingFunction
            halo.add(grow, forKey: "grow")
            halo.add(Self.track("opacity", p.flies ? [0.9, 0] : [0.6, 0], times: [0, 1], duration: p.pulseDuration, begin: p.pulseBegin), forKey: "fade")
            guard p.flies else { return }
            let disc = CALayer()
            disc.frame = box.insetBy(dx: side * 0.15, dy: side * 0.15)
            disc.cornerRadius = disc.frame.width / 2
            disc.backgroundColor = Theme.Colors.accent.cgColor
            disc.opacity = 0
            overlay.layer?.addSublayer(disc)
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.55
            spring.toValue = 1
            spring.damping = 9
            spring.stiffness = 260
            spring.mass = 1
            spring.duration = p.pulseDuration
            spring.beginTime = CACurrentMediaTime() + p.pulseBegin
            spring.fillMode = .both
            spring.isRemovedOnCompletion = false
            disc.add(spring, forKey: "receive")
            disc.add(Self.track("opacity", [0.7, 0.45, 0], times: [0, 0.4, 1], duration: p.pulseDuration, begin: p.pulseBegin), forKey: "fade")
        }
    }

    /// The overlay never takes clicks: the editor stays usable during the send-off.
    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
