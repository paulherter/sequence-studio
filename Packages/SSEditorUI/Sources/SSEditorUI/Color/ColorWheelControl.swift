import AppKit

/// Final Cut style colour wheel: puck in a hue/saturation disc plus a vertical master (luma) slider on the right.
/// Drag = follow pointer, Shift = fine, double-click = reset (disc: puck to centre, slider: master to 0).
/// One gesture = `onBegin` → `onChange`* → `onEnd`, so the host can make one undo step per drag.
public final class ColorWheelControl: NSControl {
    public enum Part: Sendable { case wheel, master }

    public var hue: Double = 0 { didSet { if hue != oldValue { needsDisplay = true } } }
    /// 0…1.
    public var amount: Double = 0 { didSet { if amount != oldValue { needsDisplay = true } } }
    /// -1…1.
    public var master: Double = 0 { didSet { if master != oldValue { needsDisplay = true } } }
    public var title: String = "" { didSet { needsDisplay = true } }
    /// false hides the luminance slider (tint wheels).
    public var showsMaster = true { didSet { needsDisplay = true } }

    public var onBegin: ((Part) -> Void)?
    public var onChange: ((Part) -> Void)?
    public var onEnd: ((Part) -> Void)?

    private static let sliderWidth: CGFloat = 14
    private static let gap: CGFloat = 10
    private static let puck: CGFloat = 9
    private var wheelImage: NSImage?
    private var wheelImageDiameter: CGFloat = 0

    private var dragPart: Part?
    private var dragAnchorValue = ColorWheelMath.reset
    private var dragAnchorPoint = (0.0, 0.0)
    private var dragFine = false

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 130) }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.colorWell)
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Geometry

    private var discRect: NSRect {
        let labelH: CGFloat = title.isEmpty ? 0 : 16
        let availW = bounds.width - (showsMaster ? Self.sliderWidth + Self.gap : 0)
        let d = max(0, min(availW, bounds.height - labelH))
        return NSRect(x: (availW - d) / 2, y: labelH + (bounds.height - labelH - d) / 2, width: d, height: d)
    }
    private var radius: Double { Double(discRect.width) / 2 }
    private var center: NSPoint { NSPoint(x: discRect.midX, y: discRect.midY) }
    private var sliderRect: NSRect {
        let d = discRect
        return NSRect(x: d.maxX + Self.gap, y: d.minY, width: Self.sliderWidth, height: d.height)
    }

    /// Disc-local, y-up coordinates.
    private func local(_ p: NSPoint) -> (Double, Double) { (Double(p.x - center.x), Double(center.y - p.y)) }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let disc = discRect
        if !title.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Fonts.small, .foregroundColor: Theme.Colors.label2]
            let s = NSAttributedString(string: title, attributes: attrs)
            s.draw(at: NSPoint(x: disc.midX - s.size().width / 2, y: 0))
        }
        guard disc.width > 4 else { return }

        Theme.Colors.field.setFill()
        NSBezierPath(ovalIn: disc).fill()
        wheelBackdrop(diameter: disc.width).draw(in: disc)
        Theme.Colors.fieldEdge.setStroke()
        let ring = NSBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()

        // Crosshair
        Theme.white(0.14).setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: disc.minX + 6, y: disc.midY)); cross.line(to: NSPoint(x: disc.maxX - 6, y: disc.midY))
        cross.move(to: NSPoint(x: disc.midX, y: disc.minY + 6)); cross.line(to: NSPoint(x: disc.midX, y: disc.maxY - 6))
        cross.lineWidth = 0.5
        cross.stroke()

        // Puck
        let o = ColorWheelMath.offset(of: .init(hue: hue, amount: amount), radius: radius)
        let pc = NSPoint(x: center.x + o.dx, y: center.y - o.dy)
        let pr = NSRect(x: pc.x - Self.puck / 2, y: pc.y - Self.puck / 2, width: Self.puck, height: Self.puck)
        Theme.black(0.45).setFill()
        NSBezierPath(ovalIn: pr.insetBy(dx: -1, dy: -1)).fill()
        Theme.Colors.fillPressed.setFill()
        let puckPath = NSBezierPath(ovalIn: pr)
        puckPath.fill()
        (dragPart == .wheel ? Theme.Colors.accent : Theme.white(0.9)).setStroke()
        puckPath.lineWidth = 1.5
        puckPath.stroke()

        if showsMaster { drawSlider() }
    }

    private func drawSlider() {
        let r = sliderRect
        let track = NSRect(x: r.midX - 2, y: r.minY, width: 4, height: r.height)
        Theme.Colors.field.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        Theme.Colors.fieldEdge.setStroke()
        NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
        // Centre tick (neutral)
        Theme.white(0.35).setFill()
        NSRect(x: r.minX + 1, y: r.midY - 0.5, width: r.width - 2, height: 1).fill()
        // Knob
        let y = r.minY + CGFloat(ColorWheelMath.y(forMaster: master, height: Double(r.height)))
        let knob = NSRect(x: r.minX, y: y - 4, width: r.width, height: 8)
        Theme.black(0.4).setFill()
        NSBezierPath(roundedRect: knob.insetBy(dx: -1, dy: -1), xRadius: 4, yRadius: 4).fill()
        (dragPart == .master ? Theme.Colors.accentFill : Theme.white(0.88)).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 4, yRadius: 4).fill()
    }

    /// Hue wedges fading to transparent at the centre; cached per size.
    private func wheelBackdrop(diameter: CGFloat) -> NSImage {
        if let img = wheelImage, wheelImageDiameter == diameter { return img }
        let size = NSSize(width: diameter, height: diameter)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = rect.width / 2
            ctx.saveGState()
            ctx.addEllipse(in: rect)
            ctx.clip()
            let steps = 120
            for i in 0..<steps {
                let a0 = CGFloat(i) / CGFloat(steps) * 2 * .pi
                let a1 = CGFloat(i + 1) / CGFloat(steps) * 2 * .pi + 0.01
                ctx.setFillColor(NSColor(hue: CGFloat(i) / CGFloat(steps), saturation: 0.85, brightness: 0.75, alpha: 0.55).cgColor)
                ctx.move(to: c)
                ctx.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
                ctx.fillPath()
            }
            ctx.restoreGState()
            // Fade to the dark centre.
            let colors = [Theme.black(0.85).cgColor, Theme.black(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.addEllipse(in: rect)
                ctx.clip()
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
                ctx.restoreGState()
            }
            return true
        }
        wheelImage = img
        wheelImageDiameter = diameter
        return img
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        let inSlider = showsMaster && sliderRect.insetBy(dx: -4, dy: -4).contains(p)
        let (dx, dy) = local(p)
        let inDisc = hypot(dx, dy) <= radius + Double(Self.puck)
        guard inSlider || inDisc else { return }
        let part: Part = inSlider ? .master : .wheel

        if event.clickCount == 2 {
            onBegin?(part)
            switch part {
            case .wheel: hue = 0; amount = 0
            case .master: master = 0
            }
            onChange?(part)
            onEnd?(part)
            sendAction(action, to: target)
            return
        }

        dragPart = part
        onBegin?(part)
        anchor(at: p, fine: event.modifierFlags.contains(.shift))
        apply(p, event: event)
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard dragPart != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let fine = event.modifierFlags.contains(.shift)
        if fine != dragFine { anchor(at: p, fine: fine) }   // re-anchor so toggling Shift does not jump the puck
        apply(p, event: event)
    }

    public override func mouseUp(with event: NSEvent) {
        guard let part = dragPart else { return }
        dragPart = nil
        onEnd?(part)
        needsDisplay = true
    }

    private func anchor(at p: NSPoint, fine: Bool) {
        dragFine = fine
        dragAnchorValue = .init(hue: hue, amount: amount)
        dragAnchorPoint = local(p)
        if dragPart == .master {
            dragAnchorValue = .init(hue: 0, amount: master)   // amount carries the master value
            dragAnchorPoint = (0, Double(p.y))
        }
    }

    private func apply(_ p: NSPoint, event: NSEvent) {
        guard let part = dragPart else { return }
        switch part {
        case .wheel:
            let v = ColorWheelMath.drag(start: dragAnchorValue, startPoint: dragAnchorPoint, point: local(p),
                                        radius: radius, fine: dragFine)
            hue = v.hue
            amount = v.amount
        case .master:
            let h = Double(sliderRect.height)
            let y = Double(p.y - sliderRect.minY)
            if dragFine {
                let start = ColorWheelMath.y(forMaster: dragAnchorValue.amount, height: h)
                master = ColorWheelMath.master(forY: start + (y - (dragAnchorPoint.1 - Double(sliderRect.minY))) * ColorWheelMath.fineFactor, height: h)
            } else {
                master = ColorWheelMath.master(forY: y, height: h)
            }
        }
        onChange?(part)
        sendAction(action, to: target)
    }
}
