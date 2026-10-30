import AppKit
import SQCore
import SQUIKit

/// Bodies of the About and Acknowledgments dialogs (windows plan section 3). The App only hands in the app icon, the
/// supporters and the click targets; layout lives here so tests can lay it out in a real `SQDialog` card.
@MainActor
public enum AboutDialog {
    /// Width of the body inside a `SQModal.Size.sList` card.
    public static var bodyWidth: CGFloat { SQModal.Size.sList.width - SQDialogMetrics.sidePad * 2 }

    private static func label(_ text: String, font: NSFont, color: NSColor, width: CGFloat, align: NSTextAlignment = .center) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = font
        t.textColor = color
        t.alignment = align
        t.isSelectable = false
        t.preferredMaxLayoutWidth = width
        t.translatesAutoresizingMaskIntoConstraints = false
        t.widthAnchor.constraint(equalToConstant: width).isActive = true
        return t
    }

    /// Icon, name, version line, tagline, link buttons, license, supporters (when any) and credits.
    /// `selector` maps a link button to the action sent to `target`; `supportSelector` is the supporters block's link.
    public static func makeBody(width: CGFloat, icon: NSImage, versionLine: String, discord: URL?, supporters: [String],
                                target: AnyObject?, selector: (AboutContent.Link) -> Selector, supportSelector: Selector) -> NSView {
        let iconView = NSImageView(image: icon)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 88).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 88).isActive = true
        iconView.setAccessibilityLabel("Sequence Studio app icon")

        let name = label("Sequence Studio", font: Theme.Typography.display, color: Theme.Colors.label, width: width)
        let version = label(versionLine, font: Theme.Typography.body, color: Theme.Colors.label2, width: width)
        let tagline = label(AboutContent.tagline, font: Theme.Typography.title, color: Theme.Colors.label2, width: 360)

        var buttons: [NSView] = []
        for l in AboutContent.links(discord: discord) {
            let b = SQButton(title: l.title, target: target, action: selector(l), style: .standard)
            b.setAccessibilityLabel(l.title)
            if l == .support { b.contentTintColor = Theme.Colors.support }
            b.sizeToFit()
            buttons.append(b)
        }
        let links = NSStackView(views: buttons)
        links.orientation = .horizontal
        links.spacing = Theme.Spacing.sm

        let license = label("License: " + AboutContent.license, font: Theme.Typography.body, color: Theme.Colors.label, width: width)

        var views: [NSView] = [iconView, name, version, tagline, links, license]
        if let s = supportersBlock(names: supporters, target: target, action: supportSelector) { views.append(s) }
        views.append(label(AboutContent.credits, font: Theme.Typography.caption, color: Theme.Colors.label3, width: width))
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Theme.Spacing.md
        stack.setCustomSpacing(Theme.Spacing.sm, after: name)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    /// "Supporters" heading, the names in a wrapping block that scrolls past a max height, one support link.
    /// nil (no block at all) when the list is empty.
    public static func supportersBlock(names: [String], target: AnyObject?, action: Selector) -> NSView? {
        guard !names.isEmpty else { return nil }
        let width: CGFloat = 300
        let inner = width - Theme.Spacing.md
        let heading = NSTextField(labelWithString: "Supporters")
        heading.font = Theme.Typography.titleStrong
        heading.textColor = Theme.Colors.label
        heading.setAccessibilityLabel("Supporters")

        let list = NSTextField(wrappingLabelWithString: names.joined(separator: "  \u{00B7}  "))
        list.font = Theme.Typography.body
        list.textColor = Theme.Colors.label2
        list.isSelectable = false
        list.preferredMaxLayoutWidth = inner
        let textHeight = ceil(list.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height)
        list.frame = NSRect(x: 0, y: 0, width: inner, height: textHeight)
        let maxHeight: CGFloat = 96
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = textHeight > maxHeight
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        scroll.setAccessibilityLabel("Supporters: " + names.joined(separator: ", "))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(textHeight, maxHeight)).isActive = true

        let link = SQButton(title: SupportEntry.support.menuTitle, target: target, action: action, style: .standard)
        link.sqToolTip = "Open the Sequence Studio support page"
        link.setAccessibilityLabel(SupportEntry.support.menuTitle)
        link.sizeToFit()

        let stack = NSStackView(views: [heading, scroll, link])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    /// The Acknowledgments list: name and version, then license and use, then the license note.
    public static func makeAcknowledgmentsBody(width: CGFloat) -> NSView {
        let rows = AboutContent.acknowledgments.map { a -> NSView in
            let title = label("\(a.name)  ·  \(a.version)", font: Theme.Typography.bodyStrong, color: Theme.Colors.label, width: width, align: .left)
            let sub = label("\(a.license). \(a.usedFor)", font: Theme.Typography.caption, color: Theme.Colors.label2, width: width, align: .left)
            let s = NSStackView(views: [title, sub])
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 2
            return s
        }
        let note = label(AboutContent.licenseNote, font: Theme.Typography.caption, color: Theme.Colors.label3, width: width, align: .left)
        let stack = NSStackView(views: rows + [note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }
}
