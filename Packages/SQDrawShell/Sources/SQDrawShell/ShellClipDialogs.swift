import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// Clip > Audio Gain (the Mac `AudioGainDialog.makeView`): five radio rows, each with its number field, the loudness note
/// and a live warning (yellow) under them. Normalize Loudness is off until a loudness was measured.
@MainActor
public enum ShellAudioGain {
    static let titles = ["Set Gain to", "Adjust Gain by", "Normalize Max Peak to", "Normalize All Peaks to", "Normalize Loudness to"]
    static let fieldIDs = ["set", "adjust", "peak", "peaks", "lufs"]
    /// The warning note's row (after the radio group and the loudness note).
    static let warningRow = 2

    public static func form(items: [AudioGainPlan.Item], target: Double, ready: Bool) -> ShellForm {
        let gainRange = AudioGain.minGainDB...AudioGain.maxGainDB
        let fields: [ShellForm.NumberField] = fieldIDs.enumerated().map { n, id in
            n == 4 ? .init(id: id, value: target, range: -40...0, step: 0.5, decimals: 1, unit: "LUFS", defaultValue: target)
                : .init(id: id, value: n == 0 && items.count == 1 ? (items[0].gainDB * 10).rounded() / 10 : 0, range: gainRange,
                        step: 0.1, decimals: 1, unit: "dB", defaultValue: 0)
        }
        var rows: [ShellForm.Row] = [.radioNumbers(id: "mode", options: titles, selected: 1, fields: fields),
                                     .text(AudioGainPlan.loudnessText(items: items, measuring: false)), .text(" ")]
        if let n = AudioGainPlan.peakModeNote(itemCount: items.count) { rows.append(.text(n)) }
        let form = ShellForm(rows)
        form.extraGapBefore = [1: 2]   // the Mac loudness note has a 4 pt top inset
        if !ready { form.disabled.insert("lufs") }
        func again() {
            let w = choice(form).flatMap { AudioGainPlan.warningText(choice: $0, items: items) }
            form.setNote(warningRow, w ?? " ", warning: w != nil)
        }
        form.onChange = { _, _ in again() }
        again()
        return form
    }

    /// The picked mode with its field's value.
    public static func choice(_ form: ShellForm) -> AudioGainChoice? {
        guard let i = form.index("mode"), fieldIDs.indices.contains(i) else { return nil }
        return AudioGainPlan.choice(index: i, value: form.number(fieldIDs[i]) ?? 0)
    }
}

/// Clip > Speed/Duration (the Mac `SpeedDurationSheet`) on the shared `SpeedDialogModel`: Speed %, Duration timecode,
/// the link between them, Frames (video), Reverse, Keep Pitch (audio) and Move Later Clips.
@MainActor
public enum ShellSpeedDuration {
    public final class State {
        public let form: ShellForm
        public internal(set) var model: SpeedDialogModel
        let timecode: Timecode
        init(form: ShellForm, model: SpeedDialogModel, timecode: Timecode) { self.form = form; self.model = model; self.timecode = timecode }
    }

    public static func make(model: SpeedDialogModel, timecode: Timecode) -> State {
        // `SpeedDurationSheet.buildView`: Speed % and Duration (a frame count shown as timecode) as scrub fields with the link
        // beside them, Frames for video, the three checks; Duration and the link are off for several clips, Keep Pitch
        // without audio.
        let fd = model.frameDuration
        let limit = SpeedDialogModel.percentRange.upperBound
        var rows: [ShellForm.Row] = [
            .number(label: "Speed", .init(id: "speed", value: model.percent, range: -limit...limit, step: 1, decimals: 1, unit: "%",
                                          defaultValue: 100)),
            .number(label: "Duration", .init(id: "duration", value: frameCount(model.duration, fd), range: 1...10_000_000,
                                             defaultValue: frameCount(model.duration, fd))),
        ]
        if model.hasVideo {
            rows.append(.popup(id: "frames", label: "Frames", options: TimeInterpolation.allCases.map(\.title),
                               selected: TimeInterpolation.allCases.firstIndex(of: model.timeInterpolation) ?? 0))
        }
        rows.append(.check(id: "reverse", title: "Reverse", on: model.reversed))
        rows.append(.check(id: "pitch", title: "Keep Pitch", on: model.keepsPitch))
        rows.append(.check(id: "ripple", title: "Move Later Clips", on: model.ripple))
        let form = ShellForm(rows)
        form.link = ShellForm.Link(id: "link", fields: ["speed", "duration"])
        form.set("link", .bool(model.isLinked))
        form.setFormat("duration", format: { frames in timecode.format(Time(Int64(frames.rounded()) * fd.value, fd.timescale)) },
                       parse: { text in timecode.parse(text).map { frameCount($0, fd) } })
        if !model.canEditDuration { form.disabled.insert("duration") }
        if !model.hasAudio { form.disabled.insert("pitch") }
        let state = State(form: form, model: model, timecode: timecode)
        state.form.onChange = { [weak state] id, v in
            guard let state else { return }
            switch (id, v) {
            case ("speed", .number(let p)): state.model.setPercent(p)
            case ("duration", .number(let f)): state.model.setDuration(Time(Int64(f.rounded()) * fd.value, fd.timescale))
            case ("link", .bool(let b)): state.model.isLinked = b
            case ("frames", .index(let i)):
                if TimeInterpolation.allCases.indices.contains(i) { state.model.timeInterpolation = TimeInterpolation.allCases[i] }
            case ("reverse", .bool(let b)): state.model.reversed = b
            case ("pitch", .bool(let b)): state.model.keepsPitch = b
            case ("ripple", .bool(let b)): state.model.ripple = b
            default: return
            }
            refresh(state)
        }
        return state
    }

    /// Frames in `t` (`SpeedDurationSheet.frameCount`).
    nonisolated static func frameCount(_ t: Time, _ fd: Time) -> Double {
        Double(t.value * fd.timescale) / Double(t.timescale * fd.value)
    }

    /// Writes the model back into the rows (a typed speed changes the duration and the other way round).
    static func refresh(_ s: State) {
        s.form.set("speed", .number(s.model.percent))
        s.form.set("duration", .number(frameCount(s.model.duration, s.model.frameDuration)))
        s.form.set("reverse", .bool(s.model.reversed))
    }

    /// The change to apply on OK; nil when nothing changed.
    public static func answer(_ s: State) -> SpeedChange? { s.model.hasChanges ? s.model.change : nil }
}

extension ShellHost {
    /// Clip > Speed/Duration (Ctrl+R): one undo step for the selected clips.
    func speedDuration() async {
        guard let model = session.speedDialogModel(), let tl = session.activeTimeline else { flash("Select a clip first."); return }
        let fd = tl.frameDuration
        let s = ShellSpeedDuration.make(model: model, timecode: Timecode(frameDuration: fd, dropFrame: fd == Time(1001, 30000) || fd == Time(1001, 60000)))
        let d = ShellDialog("Speed", informative: "")
        d.width = ShellDialog.M.widthS
        d.form = s.form
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first, let change = ShellSpeedDuration.answer(s) else { return }
        session.stopPlayback()
        _ = session.applySpeed(change)
    }

    /// Clip > Audio Gain (G), the Mac `AudioGainDialog`: Set / Adjust / Normalize Max Peak / Normalize All Peaks /
    /// Normalize Loudness. Loudness is measured before the dialog opens (the Mac measures while it is up).
    func audioGain() async {
        let clips = session.audioGainTargets
        guard !clips.isEmpty else { flash("Select an audio clip first."); return }
        var items = clips.map { c in
            AudioGainPlan.Item(id: c.id, name: c.name, gainDB: c.audioGainDB, peak: peak(of: c), volume: AudioGainPlan.volumePeak(of: c))
        }
        flash("Measuring loudness...")
        for i in items.indices { items[i].lufs = await session.measureLoudness(of: clips[i]) }
        let target = session.activeTimeline.map { AudioGain.targetLUFS(for: clips, in: $0) } ?? AudioTag.dialogue.targetLUFS
        let ready = items.contains { ($0.lufs ?? AudioGain.silentLUFS) > AudioGain.silentLUFS }
        let form = ShellAudioGain.form(items: items, target: target, ready: ready)
        let d = ShellDialog("Audio Gain", informative: AudioGainPlan.infoText(items: items)
            .replacingOccurrences(of: "Peak amplitude: -", with: "Peak amplitude: \u{2212}"))
        d.form = form
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first, let choice = ShellAudioGain.choice(form) else { return }
        let gains = AudioGainPlan.plan(choice, items: items)
        if gains.isEmpty { flash("The audio is silent or not analyzed yet."); return }
        session.setAudioGain(gains)
        if gains.count < items.count {
            flash(SQL10n.plural(items.count - gains.count, one: "%@ clip was skipped: silent or not analyzed yet.",
                                other: "%@ clips were skipped: silent or not analyzed yet."))
        }
        let clipping = AudioGainPlan.clippingClips(choice, items: items).count
        if clipping > 0 { flash(AudioGainPlan.warningText(choice: choice, items: items) ?? "") }
    }

    /// Clip > Match Loudness: each selected audio clip to its role's target (the Mac `requestMatchLoudness`).
    func matchLoudness() async {
        let clips = session.selectedAudioClips
        guard !clips.isEmpty else { flash("Select an audio clip first."); return }
        flash("Measuring loudness...")
        let targets = session.activeTimeline.map { t in Set(clips.map { AudioGain.targetLUFS(for: $0, in: t) }) } ?? []
        let n = await session.matchLoudness()
        let t = targets.count == 1 ? SQL10n.format(" to %@ LUFS", String(format: "%g", targets.first!)) : ""
        flash(n == 0 ? "The audio is silent: nothing to match." : SQL10n.plural(n, one: "Matched %@ clip", other: "Matched %@ clips") + t + ".")
    }

    /// Clip > Make Subclip (Ctrl+U) from the one media item selected in the Project panel (the Mac takes the Source
    /// monitor's clip first; that one is the host's, which runs before this).
    func makeSubclip() {
        let ids = selectedMediaIDs
        guard ids.count == 1, let m = ids.first else { flash("Open a clip in the Source view and set In and Out first."); return }
        if session.makeSubclip(of: m) == nil { flash(session.lastError ?? "Could not make a subclip.") }
        else { flash("Subclip added to the Project panel.") }
    }

    /// Sequence > Add Title (Ctrl+T): the title lines at the playhead.
    func addTitle() {
        session.stopPlayback()
        guard !session.addTitle().isEmpty else { if let e = session.lastError { flash(e) }; return }
        session.seek(to: session.playhead)
        flash("Title added. Double-click a line to type.")
    }

    /// Apply Video / Audio Transition and Apply Default Transitions to Selection, at the timeline's selected edits.
    func applyTransitions(_ scope: EditorSession.TransitionScope) {
        session.stopPlayback()
        let n = session.applyDefaultTransitions(scope: scope, edges: edgeSelection?())
        if n > 0 { flash(n == 1 ? "Transition applied." : "\(n) transitions applied.") }
        else if let m = session.lastError { flash(m) }
    }

    /// The commands of the Mac `execute` that open a dialog and need nothing but the session (and the hooks above).
    /// True when the command is one of these.
    func performDialogCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .newSequence: spawn { await self.newSequence() }
        case .sequenceSettings, .projectLiveDucking: spawn { await self.sequenceSettings() }
        case .projectNotes: spawn { await self.projectNotes() }
        case .goToTimecode: spawn { await self.goToTimecode() }
        case .find:
            if CommandRouting.findTarget(focus: dock.focused) == .captionsThenProject, showCaptionSearch?() == true { break }
            spawn { await self.find() }
        case .newTone: spawn { await self.toneDialog(editing: false) }
        case .toneSettings: spawn { await self.toneDialog(editing: true) }
        case .speedDuration: spawn { await self.speedDuration() }
        case .audioGain: spawn { await self.audioGain() }
        case .matchLoudness: spawn { await self.matchLoudness() }
        case .makeSubclip: makeSubclip()
        case .addTitle: addTitle()
        case .applyVideoTransition: applyTransitions(.video)
        case .applyAudioTransition: applyTransitions(.audio)
        case .applyDefaultTransitions: applyTransitions(.both)
        case .exportEDL, .exportFCPXML, .exportFinalCutXML, .exportOpenTimelineIO: spawn { await self.exportInterchange(c) }
        case .importTimeline: spawn { await self.chooseAndImportTimeline() }
        case .checkCuts: spawn { await self.checkCuts() }
        case .punchInCuts: spawn { await self.punchInCuts() }
        case .anonymize: anonymizeCommand()
        case .pasteAttributes: spawn { await self.pasteSettings() }
        case .autoDuck: spawn { await self.autoDuck() }
        case .removeSilences: spawn { await self.removeSilences() }
        case .syncAudioToReference: spawn { await self.syncAudio() }
        case .quickExport: spawn { await self.quickExport() }
        case .importProject: spawn { await self.importProjectAsBin() }
        default: return performViewCommand(c)
        }
        return true
    }
}
