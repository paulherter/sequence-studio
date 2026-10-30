import AppKit
import SQCore
import SQUIKit

/// Row under the Project panel's search field: the "Sorted by" switch (Folders, Day, Camera, Kind) and the filter chips.
/// Active tokens come first (click removes one); the rest are one-click suggestions built from what the project holds
/// (Unused, Today, the cameras and frame rates that exist). Display only: nothing here moves or edits media.
@MainActor
final class ProjectFilterBar: NSView {
    static let gap: CGFloat = Theme.Spacing.xs
    private static let maxSuggestions = 6

    var onGrouping: ((MediaGrouping) -> Void)?
    var onAdd: ((MediaFilterToken) -> Void)?
    var onRemove: ((MediaFilterToken) -> Void)?
    /// Called when the wanted height changes (it follows the width: chips wrap).
    var onHeightChange: ((CGFloat) -> Void)?

    private let caption = NSTextField(labelWithString: "Sorted by")
    private let segmented = SQSegmented(labels: MediaGrouping.allCases.map(\.title), segmentWidth: 54)
    private var chips: [(chip: LibraryChip, token: MediaFilterToken, active: Bool)] = []
    private(set) var height: CGFloat = 0
    private var laidOutWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        caption.font = Theme.Typography.caption
        caption.textColor = Theme.Colors.label3
        segmented.target = self
        segmented.action = #selector(groupingChanged)
        addSubview(caption); addSubview(segmented)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the chips for the current tokens and project media.
    func update(grouping: MediaGrouping, tokens: [MediaFilterToken], media: [MediaRef]) {
        segmented.selectedSegment = MediaGrouping.allCases.firstIndex(of: grouping) ?? 0
        chips.forEach { $0.chip.removeFromSuperview() }
        chips = []
        for t in tokens { addChip(t, active: true) }
        var suggestions: [MediaFilterToken] = [MediaFilterToken(.usage, "unused"), MediaFilterToken(.day, "today")]
        suggestions += MediaFilterQuery.values(for: .camera, in: media).prefix(3).map { MediaFilterToken(.camera, $0) }
        suggestions += MediaFilterQuery.values(for: .fps, in: media).prefix(2).map { MediaFilterToken(.fps, $0) }
        suggestions += MediaFilterQuery.values(for: .label, in: media).prefix(1).map { MediaFilterToken(.label, $0) }
        for t in suggestions where !tokens.contains(t) && chips.count < tokens.count + Self.maxSuggestions { addChip(t, active: false) }
        laidOutWidth = 0
        needsLayout = true
    }

    private func addChip(_ token: MediaFilterToken, active: Bool) {
        let chip = LibraryChip(frame: .zero)
        chip.title = active ? token.title + " ×" : token.title
        chip.state = active ? .on : .off
        chip.target = self
        chip.action = #selector(chipClicked(_:))
        chip.sqToolTip = active ? "Remove this filter" : "Show only \(token.title.lowercased())"
        addSubview(chip)
        chips.append((chip, token, active))
    }

    @objc private func groupingChanged() {
        let i = segmented.selectedSegment
        if MediaGrouping.allCases.indices.contains(i) { onGrouping?(MediaGrouping.allCases[i]) }
    }

    @objc private func chipClicked(_ sender: LibraryChip) {
        guard let hit = chips.first(where: { $0.chip === sender }) else { return }
        if hit.active { onRemove?(hit.token) } else { onAdd?(hit.token) }
    }

    override func layout() {
        super.layout()
        let pad = Theme.Spacing.sm
        let rowH = Theme.Metrics.quietField
        let cap = caption.intrinsicContentSize
        caption.frame = NSRect(x: pad, y: (rowH - cap.height) / 2, width: cap.width, height: cap.height)
        let segW = segmented.intrinsicContentSize.width
        segmented.frame = NSRect(x: pad + cap.width + Self.gap * 2, y: 0, width: segW, height: rowH)
        var x = pad, y = rowH + Self.gap
        let maxX = bounds.width - pad
        for c in chips {
            let w = c.chip.intrinsicContentSize.width
            if x > pad, x + w > maxX { x = pad; y += LibraryChip.height + Self.gap }
            c.chip.frame = NSRect(x: x, y: y, width: w, height: LibraryChip.height)
            x += w + Self.gap
        }
        let h = chips.isEmpty ? rowH + Self.gap : y + LibraryChip.height + Self.gap
        if abs(h - height) > 0.5 || laidOutWidth != bounds.width {
            laidOutWidth = bounds.width
            if abs(h - height) > 0.5 { height = h; onHeightChange?(h) }
        }
    }
}
