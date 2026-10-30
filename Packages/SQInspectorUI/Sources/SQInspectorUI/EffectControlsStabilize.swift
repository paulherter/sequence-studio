import AppKit
import SQCore

/// Stabilizer: the row under Method. Start (Stop while it runs; adding the effect never starts it) where the values of a parameter row sit, then a
/// progress bar with the percentage while analyzing (the step's name while there is no share yet), else the state
/// ("Not analyzed", "Analyzed", why the last analysis failed, or why the method is off).
final class StabilizeAnalyzeRow: RowBackground, RowUpdating {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    private let button = SQButton(title: "Start", target: nil, action: nil)
    private let progress = TranscribeProgressBar()
    private let status = makeLabel("", font: Theme.Typography.caption, color: Theme.Colors.label3)

    init(effect: ClipEffect.ID, model: EffectControlsModel) {
        self.effect = effect; self.model = model
        super.init(frame: .zero)
        button.target = self
        button.action = #selector(pressed)
        status.lineBreakMode = .byTruncatingTail
        for v in [button, progress, status] as [NSView] { addSubview(v) }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { model.analyzeOrCancelStabilizer(effect) }

    override func layout() {
        super.layout()
        let h = bounds.height, bh = Theme.Metrics.quietButton
        let bw = max(button.intrinsicContentSize.width, 72)
        button.frame = NSRect(x: ControlsMetrics.valueX, y: ((h - bh) / 2).rounded(), width: bw, height: bh)
        let x = button.frame.maxX + ControlsGrid.gap
        let w = max(bounds.width - x - EC.trailing, 0)
        if progress.isHidden {
            status.frame = NSRect(x: x, y: (h - EC.labelHeight) / 2, width: w, height: EC.labelHeight)
        } else {
            let pct: CGFloat = 36
            progress.frame = NSRect(x: x, y: (h - 4) / 2, width: max(w - pct - ControlsGrid.gap, 0), height: 4)
            status.frame = NSRect(x: progress.frame.maxX + ControlsGrid.gap, y: (h - EC.labelHeight) / 2, width: pct, height: EC.labelHeight)
        }
    }

    func update() {
        let state = model.stabilizeStatus(effect)
        switch state {
        case .analysing(let p):
            button.title = "Stop"
            button.isEnabled = true
            button.sqToolTip = Tooltip.text("Stop the analysis", shortcut: nil)
            progress.isHidden = false
            progress.doubleValue = p
            status.stringValue = "\(Int((p * 100).rounded(.down))) %"
            status.sqToolTip = nil
        case .working(let step):
            button.title = "Stop"
            button.isEnabled = true
            button.sqToolTip = Tooltip.text("Stop the analysis", shortcut: nil)
            progress.isHidden = true
            status.stringValue = step
            status.sqToolTip = step
        case .failed(let why):
            button.title = "Start Again"
            button.isEnabled = true
            button.sqToolTip = Tooltip.text("Try the analysis again", shortcut: nil)
            progress.isHidden = true
            status.stringValue = why
            status.sqToolTip = why
        case .notAnalysed, .analysed, .needsAnalysis:
            button.title = state == .notAnalysed ? "Start" : "Start Again"
            button.isEnabled = true
            button.sqToolTip = Tooltip.text("Measure the camera shake of this clip", shortcut: nil)
            progress.isHidden = true
            status.stringValue = state == .analysed ? "Analyzed" : state == .needsAnalysis ? "New frames need analyzing" : "Not analyzed"
            status.sqToolTip = nil
        case .blocked(let why):
            button.title = "Start"
            button.isEnabled = false
            button.sqToolTip = why
            progress.isHidden = true
            status.stringValue = why
            status.sqToolTip = why
        }
        needsLayout = true   // the button title and the progress bar change the layout
    }
}
