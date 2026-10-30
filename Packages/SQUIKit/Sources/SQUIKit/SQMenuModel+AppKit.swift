import AppKit

// The AppKit side of SQMenu: label dots as tagged NSImages, the NSMenu bridge, `NSMenuItem.sqHelp`. The model, navigation
// and layout are portable (`SQMenuModel.swift`); the Windows app draws them through SQDrawKit.

/// Color dot of a label menu row. An NSMenuItem image tagged with its color; the bridge turns it into `.swatch`.
public enum SQMenuDot {
    static let tag = "sq.dot:"
    @MainActor public static func image(rgb: UInt32) -> NSImage {
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            Theme.hex(rgb).setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
        img.accessibilityDescription = tag + String(rgb, radix: 16)
        return img
    }
    /// The dot for a Theme color (marker palette): the same tagged image, from the color's sRGB value.
    @MainActor public static func image(color: NSColor) -> NSImage {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return image(rgb: byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent))
    }
    static func rgb(of image: NSImage?) -> UInt32? {
        guard let d = image?.accessibilityDescription, d.hasPrefix(tag) else { return nil }
        return UInt32(d.dropFirst(tag.count), radix: 16)
    }
}

// MARK: NSMenu bridge

extension SQMenuItem {
    private static let systemEditExtras: Set<String> = ["Writing Tools", "AutoFill", "Schreibtools", "AutoAusfüllen", "Automatisch ausfüllen"]

    /// Converts an NSMenu (titles, enabled, state, key equivalents, images, submenus) so existing builders work unchanged.
    /// Items without their own image get a symbol from `SQMenuIconTable`. Actions run through `performActionForItem`.
    @MainActor
    public static func items(from menu: NSMenu) -> [SQMenuItem] {
        var out: [SQMenuItem] = []
        for (index, ns) in menu.items.enumerated() where !ns.isHidden {
            if ns.isSeparatorItem { out.append(.separator); continue }
            // macOS appends these to any Edit menu; the board has neither.
            if systemEditExtras.contains(ns.title) { continue }
            if ns.isSectionHeader { out.append(.header(ns.title)); continue }
            var item = SQMenuItem(title: ns.title)
            item.isEnabled = ns.isEnabled
            item.isChecked = ns.state == .on
            item.help = ns.sqHelp
            if let id = ns.identifier?.rawValue, id.hasPrefix(SQMenuShortcut.hintPrefix) {
                item.shortcut = String(id.dropFirst(SQMenuShortcut.hintPrefix.count))
            } else {
                item.shortcut = SQMenuShortcut.glyphs(key: ns.keyEquivalent, modifiers: ns.keyEquivalentModifierMask)
            }
            // The board has no menu icons: only color dots (label menus) are drawn; other item images are ignored.
            if let rgb = SQMenuDot.rgb(of: ns.image) { item.icon = .swatch(rgb) }
            if let sub = ns.submenu {
                item.submenu = items(from: sub)
                if item.submenu?.isEmpty == true { item.isEnabled = false }
            } else {
                item.action = { menu.performActionForItem(at: index) }
            }
            out.append(item)
        }
        while out.last?.kind == .separator { out.removeLast() }
        return out
    }
}

private nonisolated(unsafe) var sqHelpKey: UInt8 = 0

extension NSMenuItem {
    /// Help text for the item, shown by the SQ menu as a caption line. Never use `NSMenuItem.toolTip` (the system tooltip).
    public var sqHelp: String? {
        get { objc_getAssociatedObject(self, &sqHelpKey) as? String }
        set { objc_setAssociatedObject(self, &sqHelpKey, newValue?.isEmpty == false ? newValue : nil, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }
}
