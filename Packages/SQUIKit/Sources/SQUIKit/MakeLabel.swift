import AppKit

@MainActor public func makeLabel(_ s: String, font: NSFont = Theme.Typography.body, color: NSColor = Theme.Colors.label2) -> NSTextField {
    let l = NSTextField(labelWithString: SQL10n.string(s))
    l.font = font; l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
}
