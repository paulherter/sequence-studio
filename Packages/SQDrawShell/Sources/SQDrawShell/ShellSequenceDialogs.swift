import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// New Sequence and Sequence Settings, translated from the Mac `SequenceSettingsSheet`: Name, Preset, Frame Size, Pixel
/// Shape, Frame Rate, Sample Rate; Sequence Settings adds Channels, Live Ducking, Timeline mode, Starts at, Display and
/// Preview Quality. The rules (preset follows the fields, Starts at keeps its time across rate changes) are the Mac ones.
@MainActor
public enum ShellSequenceSettings {
    static let customTitle = "Custom"
    static let qualities: [SequencePreviewQuality?] = [nil, .full, .half, .quarter]

    /// The form's rows plus the state its rules need.
    public final class State {
        public let form: ShellForm
        public let isNew: Bool
        let original: SequenceFormat
        let shapes: [PixelAspect]
        var target: DeliveryTarget?
        var start: TimecodeStartEntry
        let duckingChoices: [ProjectLiveDuckingChoices.Choice]
        init(form: ShellForm, isNew: Bool, original: SequenceFormat, shapes: [PixelAspect], target: DeliveryTarget?,
             start: TimecodeStartEntry, duckingChoices: [ProjectLiveDuckingChoices.Choice]) {
            self.form = form; self.isNew = isNew; self.original = original; self.shapes = shapes; self.target = target
            self.start = start; self.duckingChoices = duckingChoices
        }
    }

    /// "29.97", "24": the rate with trailing zeros dropped (`SequenceSettingsSheet.label`).
    static func rateLabel(_ d: Time) -> String {
        let s = String(format: "%.3f", Double(d.timescale) / Double(d.value))
        return s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    static func sampleRateTitle(_ r: Int) -> String {
        "\(r / 1000).\(r % 1000 / 100) kHz".replacingOccurrences(of: ".0 ", with: " ")
    }

    public static func make(settings: SequenceSettings, isNew: Bool, projectDucking: ProjectLiveDucking? = nil,
                            preferredDucking: LiveDucking? = nil) -> State {
        let format = settings.format
        let shapes = PixelAspect.presets + (PixelAspect.presets.contains(format.pixelAspect) ? [] : [format.pixelAspect])
        let presets = [customTitle] + SequenceFormatPresets.named.map(\.name)
        var rates = SequenceFormatPresets.frameRates.map { $0.label + " fps" }
        if SequenceFormatPresets.frameRate(format.frameDuration) == nil { rates.append(rateLabel(format.frameDuration) + " fps") }
        let rate = SequenceFormatPresets.frameRates.firstIndex { $0.frameDuration == format.frameDuration } ?? rates.count - 1
        var audio = SequenceFormatPresets.sampleRates.map(sampleRateTitle)
        if !SequenceFormatPresets.sampleRates.contains(format.audioSampleRate) { audio.append("\(format.audioSampleRate) Hz") }
        let sr = SequenceFormatPresets.sampleRates.firstIndex(of: format.audioSampleRate) ?? audio.count - 1
        let start = TimecodeStartEntry(start: settings.timecodeStart, frameDuration: format.frameDuration,
                                       framesOnly: settings.timecodeDisplay == .frames)
        let ducking = ProjectLiveDuckingChoices.choices(current: projectDucking, preferences: preferredDucking)
        let dims = 1...Double(SequenceFormatPresets.maxDimension)
        var rows: [ShellForm.Row] = [
            .field(id: "name", label: "Name", value: settings.name),
            .caption("Video"),
            .popup(id: "preset", label: "Preset", options: presets, selected: 0),
            .size(label: "Frame Size", width: .init(id: "width", value: Double(format.width), range: dims),
                  height: .init(id: "height", value: Double(format.height), range: dims)),
            .popup(id: "shape", label: "Pixel Shape",
                   options: shapes.map { $0.isSquare ? "Square" : "Anamorphic \(PixelAspectChoices.ratioText($0))" },
                   selected: shapes.firstIndex(of: format.pixelAspect) ?? 0),
            .popup(id: "rate", label: "Frame Rate", options: rates, selected: rate),
            .caption("Audio"),
            .popup(id: "audio", label: "Sample Rate", options: audio, selected: sr),
        ]
        if !isNew {
            rows += [
                .segmented(id: "channels", label: "Channels", options: ["Stereo", "Mono"], selected: settings.channelLayout == .mono ? 1 : 0,
                           segmentWidth: 84),
                .popup(id: "ducking", label: "Live Ducking", options: ducking.map(\.title),
                       selected: ProjectLiveDuckingChoices.index(of: projectDucking, in: ducking)),
                .text("Music tracks get quieter while a Dialogue track speaks, in playback and export. Applies to the whole project; a track can opt out in its header menu."),
                .caption("Working"),
                .segmented(id: "mode", label: "Timeline", options: ["Normal", "Fast Cut"], selected: settings.editMode == .magnetic ? 1 : 0,
                           segmentWidth: 84),
                .text("Normal keeps classic tracks. Fast Cut closes gaps on the main track by itself."),
                .caption("Timecode"),
                .field(id: "start", label: "Starts at", value: start.text),
                .segmented(id: "display", label: "Display", options: ["Timecode", "Frames"],
                           selected: settings.timecodeDisplay == .frames ? 1 : 0, segmentWidth: 84),
                .caption("Preview"),
                .popup(id: "quality", label: "Quality",
                       options: qualities.map { q in q.flatMap { MonitorQuality(rawValue: $0.rawValue)?.title } ?? "App setting" },
                       selected: qualities.firstIndex(of: settings.previewQuality) ?? 0),
                .text("Starts at and Display change only what is shown. Quality is used while this sequence is open."),
            ]
        }
        let form = ShellForm(rows)
        // `SequenceSettingsSheet.accessory`: the short popups and Starts at are 120 wide, Live Ducking 200.
        for id in ["shape", "rate", "audio", "start", "quality"] { form.controlWidths[id] = 120 }
        form.controlWidths["ducking"] = 200
        let state = State(form: form, isNew: isNew, original: format, shapes: shapes, target: settings.deliveryTarget,
                          start: start, duckingChoices: ducking)
        syncPreset(state)
        form.onChange = { [weak state] id, v in
            guard let state else { return }
            switch id {
            case "preset":
                guard case .index(let i) = v, i > 0, SequenceFormatPresets.named.indices.contains(i - 1) else { return }
                let n = SequenceFormatPresets.named[i - 1]
                state.target = n.deliveryTarget
                state.form.set("width", .number(Double(n.format.width)))
                state.form.set("height", .number(Double(n.format.height)))
                if let r = SequenceFormatPresets.frameRates.firstIndex(where: { $0.frameDuration == n.format.frameDuration }) {
                    state.form.set("rate", .index(r))
                }
                refreshStart(state)
            case "width", "height", "shape": syncPreset(state)
            case "rate": syncPreset(state); refreshStart(state)
            case "display": refreshStart(state)
            case "start": state.start.setText(state.form.text("start") ?? "")
            default: break
            }
        }
        return state
    }

    /// Frame duration the rate popup shows right now.
    static func frameDuration(_ s: State) -> Time {
        let rates = SequenceFormatPresets.frameRates, i = s.form.index("rate") ?? -1
        return rates.indices.contains(i) ? rates[i].frameDuration : s.original.frameDuration
    }

    /// Frame rate or Display changed: the start stays a time and is written again in the new rate and mode.
    static func refreshStart(_ s: State) {
        guard !s.isNew else { return }
        s.start.setText(s.form.text("start") ?? s.start.text)
        s.start.reconfigure(frameDuration: frameDuration(s), framesOnly: s.form.index("display") == 1)
        s.form.set("start", .text(s.start.text))
    }

    /// The preset popup follows the fields: the preset when size and rate match one, else Custom.
    static func syncPreset(_ s: State) {
        let named = SequenceFormatPresets.named
        if let c = chosen(s), let n = named.first(where: { $0.format == c && $0.deliveryTarget == s.target })
            ?? SequenceFormatPresets.preset(matching: c), let i = named.firstIndex(where: { $0.name == n.name }) {
            s.form.set("preset", .index(i + 1))
        } else { s.form.set("preset", .index(0)) }
    }

    /// The format in the fields; nil when the size is not a number in range.
    static func chosen(_ s: State) -> SequenceFormat? {
        guard let w = s.form.number("width"), let h = s.form.number("height"), w.isFinite, h.isFinite,
              w >= 1, h >= 1, w <= Double(SequenceFormatPresets.maxDimension), h <= Double(SequenceFormatPresets.maxDimension)
        else { return nil }
        let j = s.form.index("audio") ?? -1
        let sr = SequenceFormatPresets.sampleRates.indices.contains(j) ? SequenceFormatPresets.sampleRates[j] : s.original.audioSampleRate
        var f = SequenceFormat(width: Int(w.rounded()), height: Int(h.rounded()), frameDuration: frameDuration(s), audioSampleRate: sr)
        f.pixelAspect = s.shapes[max(0, min(s.form.index("shape") ?? 0, s.shapes.count - 1))]
        return f.isValid ? f : nil
    }

    /// The edited settings and the project's Live Ducking choice (nil when unchanged); nil when the size or Starts at is
    /// not usable (the Mac sheet stays open then).
    public static func answer(_ s: State, settings: SequenceSettings, projectDucking: ProjectLiveDucking?)
        -> (settings: SequenceSettings, ducking: ProjectLiveDucking??)? {
        guard let f = chosen(s) else { return nil }
        var out = settings
        out.name = s.form.text("name") ?? settings.name
        out.format = f
        out.deliveryTarget = s.target
        var ducking: ProjectLiveDucking?? = nil
        if !s.isNew {
            s.start.setText(s.form.text("start") ?? s.start.text)
            guard s.start.isValid else { return nil }
            out.channelLayout = s.form.index("channels") == 1 ? .mono : .stereo
            out.editMode = s.form.index("mode") == 1 ? .magnetic : .normal
            out.timecodeDisplay = s.form.index("display") == 1 ? .frames : .timecode
            out.timecodeStart = s.start.start
            out.previewQuality = qualities[max(0, min(s.form.index("quality") ?? 0, qualities.count - 1))]
            let i = s.form.index("ducking") ?? -1
            if s.duckingChoices.indices.contains(i) {
                var c = s.duckingChoices[i].setting
                if c?.isOn == true { c?.timing = projectDucking?.timing }
                if c != projectDucking { ducking = .some(c) }
            }
        }
        return (out, ducking)
    }
}

extension ShellHost {
    /// File > New > Sequence…: the active sequence's format as the start (the Mac `requestNewSequence`).
    func newSequence() async {
        let base = session.activeTimeline?.format ?? SequenceFormat(frameDuration: Time(1001, 30000))
        let settings = SequenceSettings(name: session.suggestedSequenceName, format: base)
        let s = ShellSequenceSettings.make(settings: settings, isNew: true)
        guard let r = await askSequenceSettings(s, title: "New Sequence", info: "", button: "Create", settings: settings,
                                                projectDucking: nil) else { return }
        session.stopPlayback()
        _ = session.addSequence(name: r.settings.name, format: r.settings.format, deliveryTarget: r.settings.deliveryTarget)
    }

    /// Sequence > Sequence Settings… of the active sequence (one undo step; the project's Live Ducking on its own).
    func sequenceSettings() async {
        guard let current = session.activeTimeline?.settings else { flash("Open a sequence first."); return }
        let duck = session.project.liveDucking
        let s = ShellSequenceSettings.make(settings: current, isNew: false, projectDucking: duck, preferredDucking: LiveDucking.current())
        guard let r = await askSequenceSettings(s, title: "Sequence Settings", info: "Clips keep their scale and position.",
                                                button: "OK", settings: current, projectDucking: duck) else { return }
        if let d = r.ducking { session.setProjectLiveDucking(d) }
        session.stopPlayback()
        _ = session.applySequenceSettings(r.settings)
    }

    private func askSequenceSettings(_ s: ShellSequenceSettings.State, title: String, info: String, button: String,
                                     settings: SequenceSettings, projectDucking: ProjectLiveDucking?)
        async -> (settings: SequenceSettings, ducking: ProjectLiveDucking??)? {
        let d = ShellDialog(title, informative: info)
        d.width = 600   // Mac SequenceSettingsSheet widthM (SQModal.Size.m is AppKit-only and does not build on Windows)
        d.form = s.form
        d.addButton(button)
        d.addButton("Cancel", role: .cancel)
        // OK closes only with a usable size and Starts at (the Mac `canConfirm`); nothing typed is lost.
        d.canClose = { r in
            r != .first || ShellSequenceSettings.answer(s, settings: settings, projectDucking: projectDucking) != nil
        }
        guard await ask(d) == .first else { return nil }
        return ShellSequenceSettings.answer(s, settings: settings, projectDucking: projectDucking)
    }

    /// File > Project Notes…: the project's free text, one undo step on OK.
    func projectNotes() async {
        // `ProjectNotesDialog`: a multi-line box over the sheet width, the caret in it.
        let form = ShellForm([.textBox(id: "notes", value: session.project.notes, height: 180)])
        form.beginEditing("notes")
        let d = ShellDialog("Project Notes", informative: "Notes stay with the project file: who it is for, deadlines, delivery specs, to-dos.")
        d.width = 520
        d.form = form
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first, let text = form.text("notes"), text != session.project.notes else { return }
        session.setProjectNotes(text)
    }

    /// The active sequence's timecode (start offset and display) for typed positions.
    func sequenceTimecode() -> Timecode? {
        guard let tl = session.activeTimeline else { return nil }
        let fd = tl.frameDuration
        var tc = Timecode(frameDuration: fd, dropFrame: fd == Time(1001, 30000) || fd == Time(1001, 60000))
        tc.origin = tl.timecodeStart
        tc.framesOnly = tl.timecodeDisplay == .frames
        return tc
    }

    /// Go to Timecode: the Mac focuses the monitor's timecode field (`focusTimecode`); a host without that hook gets
    /// a dialog: type a position, the playhead goes there.
    /// shortcut: the dialog stays for hosts that do not set `focusTimecode` (Windows until it wires the monitor card).
    func goToTimecode() async {
        guard let tc = sequenceTimecode() else { flash("Open a sequence first."); return }
        if let focus = focusTimecode, focus() { return }
        let form = ShellForm([.field(id: "tc", label: "Timecode", value: tc.position(session.playhead))])
        let d = ShellDialog("Go to Timecode", informative: "hh:mm:ss:ff, a shorter form like 1:00, or frames.")
        d.width = 360
        d.form = form
        d.addButton("Go")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first else { return }
        guard let t = tc.parsePosition(form.text("tc") ?? "") else { flash("That is not a timecode."); return }
        session.seek(to: max(t, .zero))
    }

    /// New Tone and Tone Settings (the Mac `ToneDialog`): frequency and level of a sine tone.
    func toneDialog(editing: Bool) async {
        let sel = session.selectedTone
        if editing, sel == nil { flash("Select a tone clip first."); return }
        let spec = sel?.spec ?? .default
        let hz = ToneSpec.frequencyRange, lv = ToneSpec.levelRange
        let form = ShellForm([
            .slider(id: "hz", label: "Frequency", value: spec.frequencyHz,
                    range: Double(hz.lowerBound) / 1000...Double(hz.upperBound) / 1000, unit: "Hz"),
            .slider(id: "db", label: "Level", value: spec.levelDB, range: Double(lv.lowerBound) / 100...Double(lv.upperBound) / 100, unit: "dB"),
        ])
        let d = ShellDialog("Tone Settings", informative: "Sine tone, 1 kHz at -12 dB by default")
        d.width = 400
        d.form = form
        d.addButton(editing ? "OK" : "Add")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first else { return }
        let out = ToneSpec(frequencyHz: form.number("hz") ?? spec.frequencyHz, levelDB: form.number("db") ?? spec.levelDB)
        session.stopPlayback()
        if editing, let sel { session.setTone(sel.id, out) }
        else if session.addToneClip(out) == nil { flash(session.lastError ?? "Could not add the tone.") }
        else { session.seek(to: session.playhead) }
    }
}
