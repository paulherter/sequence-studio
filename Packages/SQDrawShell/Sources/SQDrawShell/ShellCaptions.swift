import Foundation
import SQCore
import SQUIKit

/// One entry of the Create Captions style list with the limits of its preset.
public struct ShellCaptionStyle: Sendable, Equatable {
    public var name: String
    public var maxChars: Int
    /// 1 or 2.
    public var lines: Int
    public var minSeconds: Double
    public var gapFrames: Int
    public init(name: String, maxChars: Int, lines: Int, minSeconds: Double, gapFrames: Int) {
        self.name = name; self.maxChars = maxChars; self.lines = lines; self.minSeconds = minSeconds; self.gapFrames = gapFrames
    }
}

/// What the Create Captions dialog returned.
public struct ShellCreateCaptionsChoice: Sendable, Equatable {
    public var style: Int
    public var maxChars: Int
    public var lines: Int
    public var minSeconds: Double
    public var gapFrames: Int
}

/// The Captions dialogs of the Mac Text panel: Create Captions (`CreateCaptionsDialog`) and the "Replace the transcript?"
/// question (`CaptionsPanelView.makeOverwriteDialog`). They need a transcript, which the shared Text panel's Transcribe tab makes;
/// the hooks that call them are `CaptionsHost.createCaptions(model:)` and `confirmOverwrite(model:)`.
extension ShellHost {
    /// The limits the Mac dialog shows for a preset: Characters 8...100, Min. Duration to 2 decimals, Caption Gap in frames.
    static func captionFields(_ s: ShellCaptionStyle) -> (chars: Double, lines: Int, minSeconds: Double, gap: Double) {
        (Double(min(max(s.maxChars, 8), 100)), s.lines <= 1 ? 0 : 1, (s.minSeconds * 100).rounded() / 100, Double(max(s.gapFrames, 0)))
    }

    public func askCreateCaptions(styles: [ShellCaptionStyle], selected: Int) async -> ShellCreateCaptionsChoice? {
        guard !styles.isEmpty else { return nil }
        let pick = min(max(selected, 0), styles.count - 1)
        let first = Self.captionFields(styles[pick])
        let d = ShellDialog("Create Captions", informative: "Captions are made from the transcript of the whole sequence.")
        d.width = ShellDialog.M.widthS
        let form = ShellForm([
            .popup(id: "style", label: "Style", options: styles.map(\.name), selected: pick),
            .number(label: "Characters", ShellForm.NumberField(id: "chars", value: first.chars, range: 8...100, step: 1, defaultValue: first.chars)),
            .segmented(id: "lines", label: "Lines", options: ["One", "Two"], selected: first.lines, segmentWidth: 0),
            .number(label: "Min. Duration", ShellForm.NumberField(id: "minDuration", value: first.minSeconds, range: 0...60, step: 0.05,
                                                                  decimals: 2, unit: "s", defaultValue: first.minSeconds)),
            .number(label: "Caption Gap", ShellForm.NumberField(id: "gap", value: first.gap, range: 0...120, step: 1, unit: "frames",
                                                                defaultValue: first.gap)),
        ])
        // A new style refills the four limits with its own.
        form.onChange = { id, value in
            guard id == "style", case .index(let i) = value, styles.indices.contains(i) else { return }
            let v = Self.captionFields(styles[i])
            form.set("chars", .number(v.chars))
            form.set("lines", .index(v.lines))
            form.set("minDuration", .number(v.minSeconds))
            form.set("gap", .number(v.gap))
        }
        d.form = form
        d.addButton("Create")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first, let f = d.form else { return nil }
        f.commitEditing()
        return ShellCreateCaptionsChoice(style: min(max(f.index("style") ?? pick, 0), styles.count - 1),
                                         maxChars: Int((f.number("chars") ?? first.chars).rounded()),
                                         lines: (f.index("lines") ?? first.lines) + 1,
                                         minSeconds: max(0, f.number("minDuration") ?? first.minSeconds),
                                         gapFrames: Int((f.number("gap") ?? first.gap).rounded()))
    }

    /// "Replace the transcript?": transcribing again drops the current transcript with the user's edits. True = go on.
    public func confirmReplaceTranscript() async -> Bool {
        let d = ShellDialog("Replace the transcript?",
                            informative: "Transcribing again replaces the current transcript, including your edits. Media is not changed.")
        d.addButton("Transcribe Again")
        d.addButton("Cancel", role: .cancel)
        return await ask(d) == .first
    }
}
