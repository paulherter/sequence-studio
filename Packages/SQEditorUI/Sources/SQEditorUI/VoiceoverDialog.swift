import AppKit
import SQCore

/// What the voiceover dialog hands back.
public struct VoiceoverRequest: Sendable, Equatable {
    public var text: String
    public var voiceID: String
    /// 0...1, 0.5 = the normal speed of the voice.
    public var rate: Double
}

/// A voice as the dialog lists it (the app layer fills this from the system voices; no AVFoundation here).
public struct VoiceoverVoiceChoice: Sendable, Equatable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// Last voice and rate used.
public enum VoiceoverMemory {
    private static let voiceKey = "sq.voiceover.voice", rateKey = "sq.voiceover.rate"
    public static func voice(_ d: UserDefaults = .standard) -> String? { d.string(forKey: voiceKey) }
    public static func rate(_ d: UserDefaults = .standard) -> Double {
        d.object(forKey: rateKey) == nil ? Voiceover.defaultRate : Voiceover.clampedRate(d.double(forKey: rateKey))
    }
    public static func remember(voice: String, rate: Double, _ d: UserDefaults = .standard) {
        d.set(voice, forKey: voiceKey); d.set(Voiceover.clampedRate(rate), forKey: rateKey)
    }
}

/// "Voiceover from Text" sheet: the script, a voice, the speaking rate. The voice is rendered on this Mac; "Insert at Playhead"
/// puts the result on a free audio track.
@MainActor
public enum VoiceoverDialog {
    public static func present(on window: NSWindow, voices: [VoiceoverVoiceChoice], initialVoice: String?, initialRate: Double,
                               completion: @escaping @MainActor (VoiceoverRequest?) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Voiceover from Text"
        alert.informativeText = "The voice is made on this Mac and added as an audio clip at the playhead."
        alert.width = SQModal.Size.s.width
        let ui = makeView(voices: voices, initialVoice: initialVoice, initialRate: initialRate)
        alert.accessoryView = ui.view
        alert.initialFirstResponder = ui.controller.field
        alert.addButton("Insert at Playhead")
        alert.addButton("Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                withExtendedLifetime(ui.controller) {}
                guard response == .first, let r = ui.controller.request else { completion(nil); return }
                completion(r)
            }
        }
    }

    public static func makeView(voices: [VoiceoverVoiceChoice], initialVoice: String?, initialRate: Double)
        -> (view: NSView, controller: VoiceoverFieldsController) {
        let c = VoiceoverFieldsController(voices: voices, initialVoice: initialVoice, initialRate: initialRate)
        return (c.view, c)
    }
}

@MainActor
public final class VoiceoverFieldsController: NSObject {
    let field = SQDialog.makeField(placeholder: "Type or paste the text to speak", width: nil)
    private let popup = SQPopup(frame: .zero, pullsDown: false)
    private let rate: NumericSlider
    private let hint = SQDialog.caption("")
    private let voices: [VoiceoverVoiceChoice]
    public let view: NSView

    /// The request, or nil while the text is empty or no voice is installed.
    public var request: VoiceoverRequest? {
        let text = Voiceover.cleaned(field.stringValue)
        guard !text.isEmpty, popup.indexOfSelectedItem >= 0, popup.indexOfSelectedItem < voices.count else { return nil }
        return VoiceoverRequest(text: text, voiceID: voices[popup.indexOfSelectedItem].id, rate: Voiceover.rate(forSpeedFactor: rate.value))
    }

    init(voices: [VoiceoverVoiceChoice], initialVoice: String?, initialRate: Double) {
        self.voices = voices
        popup.addItems(withTitles: voices.map(\.title))
        if let i = voices.firstIndex(where: { $0.id == initialVoice }) { popup.selectItem(at: i) }
        rate = NumericSlider(value: Voiceover.speedFactor(rate: initialRate), range: 0.5...2, defaultValue: 1,
                             step: 0.05, decimals: 2, unit: "x")
        rate.fieldWidth = 72; rate.gap = 12; rate.field.leadingText = true
        rate.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hint.font = Theme.Typography.body
        hint.textColor = Theme.Colors.label2
        view = SQDialogForm(rows: [SQDialog.fieldRow(field), SQDialog.formRow("Voice", popup),
                                   SQDialog.formRow("Speed", rate),
                                   SQDialog.pad(hint, SQDialogMetrics.insets(0, 0))])
        super.init()
        NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        rate.onChange = { [weak self] _ in self?.refresh() }
        rate.onEnd = { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() { hint.stringValue = Self.hintText(for: field.stringValue, rate: Voiceover.rate(forSpeedFactor: rate.value), hasVoices: !voices.isEmpty) }

    /// "About 12 s." under the fields; explains when nothing can be made.
    nonisolated static func hintText(for text: String, rate: Double, hasVoices: Bool) -> String {
        Voiceover.hintText(for: text, rate: rate, hasVoices: hasVoices)
    }
}
