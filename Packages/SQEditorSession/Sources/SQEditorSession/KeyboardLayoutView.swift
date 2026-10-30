import AppKit
import Foundation

extension KeyboardLayout.Style {
    /// The layout of the current keyboard input source; US when unknown.
    @MainActor public static var system: KeyboardLayout.Style {
        let id = NSTextInputContext.current?.selectedKeyboardInputSource ?? ""
        if ["German", "Swiss", "Austrian"].contains(where: { id.localizedCaseInsensitiveContains($0) }) { return .german }
        if id.isEmpty, ["DE", "AT", "CH"].contains(Locale.current.region?.identifier ?? "") { return .german }
        return .us
    }
}

/// The Mac keyboard with keys colored by command group (board "Windows"). Click a key to select it.
/// The view is the board's well: `content` fill, radius 8, 16 pt around the 840 x 234 picture.
@MainActor
public final class KeyboardLayoutView: NSView {
    public var model = KeyboardLayoutModel(map: .premiereDefault) { didSet { needsDisplay = true } }
    public var selectedKey: Key? { didSet { needsDisplay = true } }
    public var onSelect: ((Key) -> Void)?
    public var style: KeyboardLayout.Style = .us { didSet { caps = KeyboardLayout.caps(style); needsDisplay = true } }
    private var caps = KeyboardLayout.caps(.us)

    public override var isFlipped: Bool { true }
    public static let padding: CGFloat = 16
    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(KeyboardLayout.height) + 2 * Self.padding)
    }

    /// Board colors of the command groups (the system palette in the dark appearance).
    public static func color(_ g: KeyGroup) -> NSColor {
        switch g {
        case .transport: Theme.Colors.accent
        case .marking: .systemOrange
        case .tools: .systemGreen
        case .editing: .systemPurple
        case .clipboard: .systemCyan
        case .view: .systemGray
        case .file: .systemRed
        case .audio: .systemYellow
        case .keyframes: .systemPink
        case .other: .systemGray
        }
    }

    private static let keyRadius: CGFloat = Theme.Radius.overlay   // board `.key` was 7; 8 = overlay token

    private func rect(_ c: KeyCap) -> NSRect {
        NSRect(x: (bounds.width - CGFloat(KeyboardLayout.width)) / 2 + c.x, y: Self.padding + c.y, width: c.w, height: c.h)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let well = NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.well, yRadius: Theme.Radius.well)
        Theme.Colors.content.setFill()
        well.fill()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label, .paragraphStyle: para]
        for cap in caps where !cap.isGhost {
            let r = rect(cap)
            let group = cap.key.flatMap { model.group(for: $0) }
            (group.map { Self.color($0).withAlphaComponent(0.24) } ?? Theme.Colors.fill2).setFill()
            NSBezierPath(roundedRect: r, xRadius: Self.keyRadius, yRadius: Self.keyRadius).fill()
            let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.keyRadius - 0.5, yRadius: Self.keyRadius - 0.5)
            edge.lineWidth = 1
            (group.map { Self.color($0).withAlphaComponent(0.6) } ?? Theme.Colors.fieldEdge).setStroke()
            edge.stroke()
            if let k = cap.key, k == selectedKey {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: Self.keyRadius + 1, yRadius: Self.keyRadius + 1)
                ring.lineWidth = 2
                Theme.Colors.yellow.setStroke()
                ring.stroke()
            }
            let s = cap.label as NSString
            let h = s.size(withAttributes: attrs).height
            s.draw(in: NSRect(x: r.minX + 2, y: r.midY - h / 2, width: r.width - 4, height: h), withAttributes: attrs)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let key = caps.first(where: { $0.key != nil && !$0.isGhost && rect($0).contains(p) })?.key else { return }
        selectedKey = key
        onSelect?(key)
    }
}
