import AppKit
import SQCore
import SQUIKit

/// Track Mask: the row above Mode, "Track" and a pop-up of the sequence's other video tracks ("No track" first).
final class TrackMaskTrackRow: RowBackground, RowUpdating, ControlsRowProbing {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    private let label = makeLabel("Track")
    private let popup = SQPopup(frame: .zero, pullsDown: false)
    private var choices: [PictureTrackChoice] = []

    var rowProbe: ControlsRowProbe { ControlsRowProbe(label: label.frame, controls: [popup.frame]) }

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        self.effect = effect; self.model = model
        super.init(frame: .zero)
        popup.controlSize = .small
        popup.font = Theme.Typography.body
        popup.target = self; popup.action = #selector(changed)
        popup.sqToolTip = Tooltip.text("The video track whose picture limits this clip", shortcut: nil)
        popup.setAccessibilityLabel("Mask Track")
        addSubview(label); addSubview(popup)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let grid = ControlsGrid(width: bounds.width), h = bounds.height
        grid.place(label, height: h)
        popup.frame = grid.fillFrame(height: h)
    }

    @objc private func changed() {
        let i = popup.indexOfSelectedItem
        if choices.indices.contains(i) { model.setTrackMaskTrack(effect, choices[i].track) }
    }

    func update() {
        let fresh = model.pictureTrackChoices()
        // Items are rebuilt only when the tracks change, so an open pop-up is not reset while the playhead moves (the clip
        // name under the playhead is only a tooltip).
        if fresh.map({ [$0.track?.uuidString ?? "", $0.lane ?? ""] }) != choices.map({ [$0.track?.uuidString ?? "", $0.lane ?? ""] }) {
            popup.removeAllItems()
            for c in fresh { popup.addItem(withTitle: c.lane ?? c.title) }
        }
        if fresh != choices {
            choices = fresh
            for (i, c) in fresh.enumerated() where popup.numberOfItems > i {
                popup.item(at: i)?.sqHelp = c.lane == nil || c.title == c.lane ? nil : c.title
            }
        }
        let sel = model.trackMaskSelection(effect, in: choices)
        if popup.indexOfSelectedItem != sel { popup.selectItem(at: sel) }
    }
}
