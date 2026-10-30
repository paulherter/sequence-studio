import AppKit
import SQCore
import SQMedia

// AudioGainChoice and AudioGainPlan live in SQCore (shared with the portable shell form); the waveform peak is in SQMedia
// (WaveformEnvelope.swift).

/// The Audio Gain sheet (key G). Opens with the current choice "Adjust Gain by 0 dB" like Premiere does for a
/// clip that has no gain yet.
@MainActor
public enum AudioGainDialog {
    private enum Row: Int, CaseIterable { case set, adjust, normalizeEach, normalizeTogether, normalizeLoudness }

    static func choice(index: Int, value v: Double) -> AudioGainChoice { AudioGainPlan.choice(index: index, value: v) }
    nonisolated public static func loudnessText(items: [AudioGainPlan.Item], measuring: Bool) -> String {
        AudioGainPlan.loudnessText(items: items, measuring: measuring)
    }
    nonisolated public static func warningText(choice: AudioGainChoice, items: [AudioGainPlan.Item]) -> String? {
        AudioGainPlan.warningText(choice: choice, items: items)
    }
    nonisolated public static func infoText(items: [AudioGainPlan.Item]) -> String { AudioGainPlan.infoText(items: items) }
    nonisolated public static func peakModeNote(itemCount: Int) -> String? { AudioGainPlan.peakModeNote(itemCount: itemCount) }

    /// The accessory view alone, so a test can render it. `loudnessTarget`: where the loudness row starts (the role table). `update` takes the items again once the loudness is measured.
    @MainActor
    public static func makeView(items: [AudioGainPlan.Item], measuring: Bool = false, loudnessTarget: Double = AudioTag.dialogue.targetLUFS)
        -> (view: NSView, group: SQRadioGroup, fields: [ScrubField], update: ([AudioGainPlan.Item], Bool) -> Void) {
        let titles = ["Set Gain to", "Adjust Gain by", "Normalize Max Peak to", "Normalize All Peaks to", "Normalize Loudness to"]
        let (group, radios) = SQRadioGroup.make(titles: titles, selected: 1)
        let gainRange = AudioGain.minGainDB...AudioGain.maxGainDB
        let fields = Row.allCases.map { r in
            r == .normalizeLoudness
                ? SQDialog.makeNumberField(range: -40...0, step: 0.5, decimals: 1, unit: "LUFS", defaultValue: loudnessTarget, width: nil)
                : SQDialog.makeNumberField(range: gainRange, step: 0.1, decimals: 1, unit: "dB", defaultValue: 0, width: nil)
        }
        for f in fields { f.leadingText = true }
        fields[0].value = items.count == 1 ? (items[0].gainDB * 10).rounded() / 10 : 0
        fields[Row.normalizeLoudness.rawValue].value = loudnessTarget
        let loudnessNote = SQDialog.formText(" ", top: 4)
        let warningNote = SQDialog.formText(" ")
        var current = items
        func refresh(_ measuring: Bool) {
            setNote(loudnessNote, loudnessText(items: current, measuring: measuring), warning: false)
            let ready = current.contains { ($0.lufs ?? AudioGain.silentLUFS) > AudioGain.silentLUFS }
            radios[Row.normalizeLoudness.rawValue].isEnabled = ready
            fields[Row.normalizeLoudness.rawValue].isEnabled = ready
            if !ready, group.selectedIndex == Row.normalizeLoudness.rawValue { group.select(Row.adjust.rawValue) }
            var warning: String?
            if let i = group.selectedIndex { warning = warningText(choice: choice(index: i, value: fields[i].value), items: current) }
            setNote(warningNote, warning ?? " ", warning: warning != nil)
        }
        func again() { refresh(false) }
        group.onChange = { _ in again() }
        for f in fields { f.onChange = { _ in again() } }
        let form = SQDialogForm(rows: (0..<fields.count).map { SQDialog.radioRow(radios[$0], field: fields[$0]) } + [loudnessNote, warningNote]
            + (peakModeNote(itemCount: items.count).map { [SQDialog.formText($0)] } ?? []))
        refresh(measuring)
        return (form, group, fields, { newItems, stillMeasuring in current = newItems; refresh(stillMeasuring) })
    }

    @MainActor private final class PresentState {
        var items: [AudioGainPlan.Item]
        var open = true
        init(items: [AudioGainPlan.Item]) { self.items = items }
    }

    private static func setNote(_ wrapper: NSView, _ text: String, warning: Bool) {
        guard let l = wrapper.subviews.first as? NSTextField else { return }
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = SQDialogMetrics.noteLine
        p.maximumLineHeight = SQDialogMetrics.noteLine
        l.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: Theme.Sheet.subFont, .foregroundColor: warning ? Theme.Colors.yellow : Theme.Colors.label2,
            .baselineOffset: 2, .paragraphStyle: p])
    }

    /// `measureLoudness` runs after the sheet is up (one clip at a time); the loudness row switches on when a value arrives.
    /// `completion` gets the items with whatever was measured by then.
    public static func present(on window: NSWindow, items: [AudioGainPlan.Item],
                               loudnessTarget: Double = AudioTag.dialogue.targetLUFS,
                               measureLoudness: ((Clip.ID) async -> Double?)? = nil,
                               completion: @escaping @MainActor (AudioGainChoice?, [AudioGainPlan.Item]) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Audio Gain"
        alert.informativeText = infoText(items: items).replacingOccurrences(of: "Peak amplitude: -", with: "Peak amplitude: \u{2212}")
        alert.width = SQModal.Size.s.width

        let state = PresentState(items: items)
        let ui = makeView(items: items, measuring: measureLoudness != nil, loudnessTarget: loudnessTarget)
        let group = ui.group, fields = ui.fields
        alert.accessoryView = ui.view
        alert.addButton("OK")
        alert.addButton("Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                state.open = false
                withExtendedLifetime(group) {}
                guard response == .first, let i = group.selectedIndex else { completion(nil, state.items); return }
                completion(choice(index: i, value: fields[i].value), state.items)
            }
        }
        guard let measureLoudness else { return }
        let update = ui.update
        Task { @MainActor in
            for n in state.items.indices {
                let value = await measureLoudness(state.items[n].id)
                guard state.open else { return }
                state.items[n].lufs = value
                update(state.items, n + 1 < state.items.count)
            }
        }
    }
}
