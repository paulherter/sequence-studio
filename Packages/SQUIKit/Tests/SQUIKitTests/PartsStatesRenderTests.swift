import AppKit
import Testing
@testable import SQUIKit

/// Draws the base controls in every state of the design boards (States board grid, Parts board "Controls" column) into
/// one PNG each, so they can be put next to the board with `scripts/compare-renders.py`. Does nothing unless
/// `SQ_PARTS_OUT=<dir>` is set (then writes `states@1x.png`, `states@2x.png`, `parts@1x.png`, `parts@2x.png`).
@MainActor
@Suite("Parts and States render", .serialized)
struct PartsStatesRenderTests {
    private static let out = ProcessInfo.processInfo.environment["SQ_PARTS_OUT"]

    enum State: Int, CaseIterable { case rest, hover, pressed, on, disabled, focus }

    /// A canvas with the board background; controls are drawn at board coordinates (1 px = 1 pt).
    @MainActor final class Canvas {
        let size: CGSize
        let scale: Int
        let rep: NSBitmapImageRep
        init(size: CGSize, scale: Int, background: NSColor) {
            self.size = size; self.scale = scale
            rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        /// Draws `view` with its top-left at (x, y) (board coordinates, y down).
        func place(_ view: NSView, x: CGFloat, y: CGFloat) {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: [.borderless], backing: .buffered, defer: true)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = view
            view.frame = NSRect(origin: .zero, size: view.frame.size)
            view.layoutSubtreeIfNeeded()
            let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            r.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: r)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let img = NSImage(size: view.bounds.size)
            img.addRepresentation(r)
            img.draw(in: NSRect(x: x, y: size.height - y - view.bounds.height, width: view.bounds.width, height: view.bounds.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }

        func write(_ url: URL) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    // MARK: Controls per state

    static func button(_ s: State) -> NSView {
        let b = SQButton(title: s == .on ? "Primary" : "Button", target: nil, action: nil, style: s == .on ? .accent : .standard)
        b.sizeToFit()
        b.isHovered = s == .hover
        b.isHighlighted = s == .pressed
        b.isEnabled = s != .disabled
        return b
    }
    static func iconButton(_ s: State) -> NSView {
        let b = SQButton(symbol: .snap, label: "Snap", target: nil, action: nil)
        b.frame.size = NSSize(width: 24, height: 22)
        b.isHovered = s == .hover
        b.isHighlighted = s == .pressed
        b.isEnabled = s != .disabled
        if s == .on { b.contentTintColor = Theme.Colors.accent }
        return b
    }
    static func popup(_ s: State) -> NSView {
        let p = SQPopup()
        p.addItems(withTitles: ["Normal", "Multiply"])
        p.frame.size = NSSize(width: 110, height: 22)
        p.isHovered = s == .hover
        p.isTracking = s == .pressed
        p.isEnabled = s != .disabled
        return p
    }
    static func segmented(_ s: State) -> NSView {
        let g = SQSegmented(labels: ["One", "Two"], segmentWidth: 0)
        g.sizeToFit()
        g.selectedSegment = s == .on ? 1 : 0
        if s == .hover || s == .pressed { g.hovered = 1 }
        g.isEnabled = s != .disabled
        return g
    }
    static func radio(_ s: State) -> NSView {
        let (_, rs) = SQRadioGroup.make(titles: [""], selected: s == .on ? 0 : nil)
        let r = rs[0]
        r.frame.size = NSSize(width: 14, height: 14)
        r.isEnabled = s != .disabled
        return r
    }
    static func checkbox(_ s: State) -> NSView {
        let c = SQCheckbox(title: "", target: nil, action: nil)
        c.frame.size = NSSize(width: 14, height: 14)
        c.state = s == .on ? .on : .off
        c.isEnabled = s != .disabled
        return c
    }
    static func slider(_ s: State) -> NSView {
        let sl = SQSlider(value: 0.5, minValue: 0, maxValue: 1)
        sl.frame.size = NSSize(width: 120, height: 20)
        sl.isHovered = s == .hover
        sl.isDragging = s == .pressed
        sl.isEnabled = s != .disabled
        return sl
    }
    static func field(_ s: State, text: String = "100.0") -> NSView {
        let f = SQTextField(string: text)
        f.frame.size = NSSize(width: 70, height: 22)
        f.isEnabled = s != .disabled
        return f
    }
    static func scroller(_ s: State) -> NSView {
        let sc = SQScroller(frame: NSRect(x: 0, y: 0, width: 12, height: 56))
        sc.knobProportion = 0.43
        sc.doubleValue = 0
        sc.isActive = s == .hover || s == .pressed
        sc.isPressed = s == .pressed
        sc.isEnabled = s != .disabled
        return sc
    }

    @Test func renderStatesAndParts() throws {
        guard let out = Self.out else { return }
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for scale in [1, 2] {
            // States board: columns Default, Hover, Pressed, Selected/on, Disabled, Focus; rows centered at the board row centers.
            let st = Canvas(size: CGSize(width: 1200, height: 720), scale: scale, background: Theme.Colors.panel)
            let rows: [(String, CGFloat, (State) -> NSView?)] = [
                ("button", 77, { Self.button($0) }),
                ("icon", 111, { Self.iconButton($0) }),
                ("popup", 145, { Self.popup($0) }),
                ("segmented", 179, { Self.segmented($0) }),
                ("radio", 213, { Self.radio($0) }),
                ("scroll", 264, { Self.scroller($0) }),
                ("checkbox", 500, { Self.checkbox($0) }),
                ("slider", 568, { Self.slider($0) }),
            ]
            for (_, cy, make) in rows {
                for s in State.allCases {
                    ControlShape.forcedFocus = s == .focus
                    guard let v = make(s) else { continue }
                    let size = v.frame.size == .zero ? v.fittingSize : v.frame.size
                    v.frame.size = size
                    st.place(v, x: 168 + 165.75 * CGFloat(s.rawValue), y: cy - size.height / 2)
                }
            }
            ControlShape.forcedFocus = false
            st.write(dir.appendingPathComponent("states@\(scale)x.png"))

            // Parts board, Controls column (x 464 .. 864).
            let pa = Canvas(size: CGSize(width: 1280, height: 480), scale: scale, background: Theme.Colors.panel)
            let b1 = SQButton(title: "Button", target: nil, action: nil, style: .standard); b1.sizeToFit()
            let b2 = SQButton(title: "Primary", target: nil, action: nil, style: .accent); b2.sizeToFit()
            let b3 = SQButton(title: "Quiet", target: nil, action: nil, style: .icon); b3.sizeToFit()
            b3.contentTintColor = Theme.Colors.label2
            let b4 = SQButton(title: "Dialog", target: nil, action: nil, style: .standard)
            b4.boxHeight = 26; b4.horizontalPadding = 16; b4.sizeToFit()
            let b5 = SQButton(title: "Dialog primary", target: nil, action: nil, style: .accent)
            b5.boxHeight = 26; b5.horizontalPadding = 16; b5.sizeToFit()
            pa.place(b1, x: 464, y: 79)
            pa.place(b2, x: 464 + 80, y: 79)
            pa.place(b3, x: 464 + 80 + 76, y: 79)
            pa.place(b4, x: 464 + 80 + 76 + 130, y: 77)
            pa.place(b5, x: 464, y: 110)
            let pop = SQPopup(); pop.addItems(withTitles: ["Popup"]); pop.frame.size = NSSize(width: 136, height: 22)
            pa.place(pop, x: 464, y: 168)
            let seg = SQSegmented(labels: ["Timeline", "Clips"], segmentWidth: 0); seg.sizeToFit()
            pa.place(seg, x: 464 + 165, y: 168)
            let srch = SQSearchField(frame: NSRect(x: 0, y: 0, width: 400, height: 22))
            srch.placeholderString = "Search"
            pa.place(srch, x: 464, y: 198)
            let fld = SQTextField(string: "Text value"); fld.frame.size = NSSize(width: 140, height: 22)
            pa.place(fld, x: 464, y: 252)
            let cb = SQCheckbox(title: "Off", target: nil, action: nil); cb.sizeToFit()
            let cb2 = SQCheckbox(title: "On", target: nil, action: nil); cb2.state = .on; cb2.sizeToFit()
            pa.place(cb, x: 464, y: 322)
            pa.place(cb2, x: 464 + 50, y: 322)
            let (_, rs) = SQRadioGroup.make(titles: ["Off", "On"], selected: 1)
            for (i, r) in rs.enumerated() { r.sizeToFit(); pa.place(r, x: 464 + 110 + CGFloat(i) * 50, y: 322) }
            // Reference: a translucent-color NSTextField label renders brighter than the color (peak ~203 for white 52 %,
            // expected ~133), an opaque gray label is exact; see the report.
            let lab = NSTextField(labelWithString: "Not transcribed yet.")
            lab.font = Theme.Typography.body; lab.textColor = Theme.Colors.label3; lab.sizeToFit()
            pa.place(lab, x: 464, y: 400)
            pa.write(dir.appendingPathComponent("parts@\(scale)x.png"))
        }
    }
}
