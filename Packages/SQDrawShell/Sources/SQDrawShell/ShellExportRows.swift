import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQExport
import SQUIKit

/// One control of an Export settings row (`ExportSettingRow.Item`): what it shows, how wide it is and what it changes.
public struct ExportItem {
    public enum Kind {
        case popup(titles: [String], selected: Int, disabled: Set<Int>)
        case check(title: String, on: Bool)
        case scrub(ScrubFieldControl)
        /// The unit after a number field (`SQUnitLabel`).
        case unit(String)
        case text(String, tone: Tone, caption: Bool)
        case segmented(labels: [String], selected: Int, disabled: Set<Int>, segmentWidth: CGFloat)
        case button(String)
        /// The File Name capsule with the extension after the text (`ExportCapsuleField`).
        case field(TextFieldControl, suffix: String)
        /// The Folder capsule (read only, `ExportCapsuleField` with `isEditable = false`).
        case path(String)
    }
    public enum Tone: Sendable { case label, label2, label3, warning, green, red }
    /// `ExportSettingRow.Item`: `.fill` shares the room left, `.fit` takes the control's own width, `.fixed` a set width.
    public enum Width: Equatable, Sendable { case fill, fit, fixed(CGFloat) }
    public enum Value { case index(Int), bool(Bool), number(Double, final: Bool), press, text(String) }

    public var kind: Kind
    public var width: Width
    public var enabled = true
    public var action: (@MainActor (Value) -> Void)?

    public init(_ kind: Kind, width: Width, enabled: Bool = true, action: (@MainActor (Value) -> Void)? = nil) {
        self.kind = kind; self.width = width; self.enabled = enabled; self.action = action
    }
}

/// One row of the settings column (`ExportSettingRow`): label at 25, controls from 128 to the edge minus 12, 8 apart.
public struct ExportRow {
    public var title: String
    public var items: [ExportItem]
    public var dimmed = false
}

/// One `InspectorSection` of the settings column.
public struct ExportSection {
    public var title: String
    public var key: String
    public var defaultOpen: Bool
    public var rows: [ExportRow]
}

/// The rows of `ExportDialogView`'s settings column over the same `ExportDialogModel`, line for line (`videoRows`,
/// `audioRows`, `captionRows`, `rangeRows`, `outputRows`, `advancedRows`). `changed` runs after every edit: `rebuild`
/// true when the rows themselves may change (the Mac `reload()`), false for a value that only moves the summary.
@MainActor
public struct ExportSheetRows {
    public typealias Item = ExportItem
    let model: ExportDialogModel
    /// The codecs the encoder writes (the Mac list filtered to them).
    let codecs: [VideoCodec]
    /// The Size popup's "Custom" entry was chosen.
    let customSize: Bool
    let changed: @MainActor (_ rebuild: Bool) -> Void
    var setCustomSize: @MainActor (Bool) -> Void = { _ in }
    var chooseFolder: (@MainActor () -> Void)?
    var copyText: (@MainActor (String) -> Void)?
    var exportStems: (@MainActor () -> Void)?
    var checkAudio: (@MainActor () -> Void)?
    var fileName: TextFieldControl?

    static let numberFieldWidth: CGFloat = 84
    static let sizes: [(Int, Int)] = [(1080, 1920), (1920, 1080), (1080, 1080), (1080, 1350), (1280, 720), (3840, 2160), (2160, 3840)]
    static let allCodecs: [(String, VideoCodec)] = [("H.264", .h264), ("HEVC", .hevc), ("ProRes 422 Proxy", .prores422Proxy),
                                                    ("ProRes 422 LT", .prores422LT), ("ProRes 422", .prores422),
                                                    ("ProRes 422 HQ", .prores422HQ), ("ProRes 4444", .prores4444)]

    /// The sections with rows, in the Mac order; empty ones are left out.
    public func sections() -> [ExportSection] {
        let audioOnly = model.settings.audioOnly != nil
        let all: [ExportSection] = [
            ExportSection(title: "Video", key: "export.video", defaultOpen: true, rows: audioOnly ? [] : videoRows()),
            ExportSection(title: "Audio", key: "export.audio", defaultOpen: true, rows: model.settings.frameOutput != nil ? [] : audioRows()),
            ExportSection(title: "Captions", key: "export.captions", defaultOpen: true, rows: captionRows()),
            ExportSection(title: "Range", key: "export.range", defaultOpen: true, rows: rangeRows()),
            ExportSection(title: "Output", key: "export.output", defaultOpen: true, rows: outputRows()),
            ExportSection(title: "Advanced", key: "export.advanced", defaultOpen: false, rows: advancedRows()),
        ]
        return all.filter { !$0.rows.isEmpty }
    }

    // MARK: Item builders (`popup`, `check`, `scrub`, `units`, `segmented`, `text`)

    private func row(_ title: String, _ items: [Item], dimmed: Bool = false) -> ExportRow { ExportRow(title: title, items: items, dimmed: dimmed) }

    private func text(_ s: String, _ tone: Item.Tone = .label, width: Item.Width = .fit, caption: Bool = false) -> Item {
        Item(.text(SQL10n.string(s), tone: tone, caption: caption), width: width)
    }

    private func popup(_ titles: [String], selected: Int, disabled: Set<Int> = [], enabled: Bool = true,
                       rebuild: Bool = true, then: @escaping @MainActor (Int) -> Void) -> Item {
        let changed = changed
        return Item(.popup(titles: titles.map { SQL10n.string($0) }, selected: selected, disabled: disabled), width: .fill, enabled: enabled) { v in
            if case .index(let i) = v { then(i); changed(rebuild) }
        }
    }

    private func check(_ title: String, on: Bool, enabled: Bool = true, width: Item.Width = .fit, rebuild: Bool = true,
                       then: @escaping @MainActor (Bool) -> Void) -> Item {
        let changed = changed
        return Item(.check(title: SQL10n.string(title), on: on), width: width, enabled: enabled) { v in
            if case .bool(let b) = v { then(b); changed(rebuild) }
        }
    }

    private func button(_ title: String, enabled: Bool, then: (@MainActor () -> Void)?) -> Item {
        Item(.button(SQL10n.string(title)), width: .fit, enabled: enabled && then != nil) { v in
            if case .press = v { then?() }
        }
    }

    /// `ExportDialogView.scrub`: a number field; with a unit it is 84 wide and the unit follows it (`units`).
    private func scrub(value: Double, range: ClosedRange<Double>, step: Double, unit: String = "", decimals: Int = 0,
                       defaultValue: Double? = nil, enabled: Bool = true, rebuild: Bool = false,
                       then: @escaping @MainActor (Double) -> Void) -> [Item] {
        var f = ScrubFieldControl(value: value)
        f.range = range; f.step = step; f.decimals = decimals; f.defaultValue = defaultValue; f.isEnabled = enabled
        let changed = changed
        let field = Item(.scrub(f), width: unit.isEmpty ? .fill : .fixed(Self.numberFieldWidth), enabled: enabled) { v in
            guard case .number(let n, let final) = v else { return }
            then(n)
            changed(final && rebuild)
        }
        return unit.isEmpty ? [field] : [field, Item(.unit(unit), width: .fit)]
    }

    private func segmented(_ labels: [String], selected: Int, disabled: Set<Int> = [], width: CGFloat,
                           then: @escaping @MainActor (Int) -> Void) -> Item {
        let changed = changed
        return Item(.segmented(labels: labels.map { SQL10n.string($0) }, selected: selected, disabled: disabled, segmentWidth: width),
                    width: .fit) { v in
            if case .index(let i) = v { then(i); changed(true) }
        }
    }

    // MARK: Output

    func outputRows() -> [ExportRow] {
        var name = fileName ?? TextFieldControl(text: model.fileName)
        if !name.isEditing { name.text = model.fileName }
        name.alignment = .left
        let m = model, changed = changed
        let ext = model.fileExtension.isEmpty ? "" : "." + model.fileExtension
        let folder = model.outputDirectory.map { Self.abbreviated($0.path) } ?? SQL10n.string("Choose a folder\u{2026}")
        return [row("File Name", [Item(.field(name, suffix: ext), width: .fill) { v in
                    if case .text(let s) = v { m.fileName = s; changed(true) }
                }]),
                row("Folder", [Item(.path(folder), width: .fill), button("Change\u{2026}", enabled: true, then: chooseFolder)])]
            + chapterRows()
    }

    /// `NSString.abbreviatingWithTildeInPath`.
    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Video

    func videoRows() -> [ExportRow] {
        let s = model.settings, d = model.presetSettings, m = model
        let mastering = s.video.codec.isMastering
        if let output = s.frameOutput { return frameOutputRows(output, s: s, d: d) }
        var rows: [ExportRow] = []
        var list = Self.allCodecs.filter { codecs.contains($0.1) }
        if !list.contains(where: { $0.1 == s.video.codec }), let own = Self.allCodecs.first(where: { $0.1 == s.video.codec }) { list.append(own) }
        rows.append(row("Codec", [popup(list.map(\.0), selected: list.firstIndex { $0.1 == s.video.codec } ?? 0) { i in
            m.codec = list[i].1
            if list[i].1 == .h264, m.settings.video.profile == .main10 { m.edit { $0.video.profile = .automatic } }
        }]))
        let profiles: [(String, VideoProfile)]
        switch s.video.codec {
        case .h264: profiles = [("Automatic", .automatic), ("Baseline", .baseline), ("Main", .main), ("High", .high)]
        case .hevc: profiles = [("Automatic", .automatic), ("Main", .main), ("Main 10", .main10)]
        default: profiles = [("Automatic", .automatic)]
        }
        rows.append(row("Profile", [popup(profiles.map(\.0), selected: profiles.firstIndex { $0.1 == s.video.profile } ?? 0,
                                          enabled: !s.video.codec.isProRes) { i in m.edit { $0.video.profile = profiles[i].1 } }]))
        rows += sizeRows(s: s, d: d)
        rows.append(frameRateRow())
        if !mastering {
            let q = s.video.constantQuality
            var items = [popup(["Target bitrate", "Constant quality"], selected: q == nil ? 0 : 1) { i in
                m.edit { $0.video.constantQuality = i == 0 ? nil : 0.6 }
            }]
            if let q {
                items += scrub(value: (q * 100).rounded(), range: 5...100, step: 1, unit: "%", defaultValue: 60) { v in
                    m.edit { $0.video.constantQuality = v / 100 }
                }
            }
            rows.append(row("Rate Control", items))
        }
        let hardware = row("", [check("Use hardware encoding", on: s.video.hardwareEncoding, rebuild: false) { on in
            m.edit { $0.video.hardwareEncoding = on }
        }])
        if s.video.constantQuality != nil {
            rows.append(hardware)
            rows += encoderSpeedRows(mastering: mastering)
            rows += colorSpaceRows(s)
            return rows
        }
        let kinds = BitrateKind.available(for: s.video.codec)
        let target = scrub(value: model.bitrateMbps, range: 0.5...400, step: 0.5, unit: "Mbit/s", decimals: 1,
                           defaultValue: Double(d.video.bitrate.averageBitsPerSecond) / 1_000_000, enabled: !mastering) { v in
            m.bitrateMbps = v
        }
        if !mastering {
            let steps = QualityStep.allCases
            let current = s.video.qualityStep
            var titles = steps.map(\.title)
            if current == nil { titles.append("Custom") }
            rows.append(row("Quality", [popup(titles, selected: current.flatMap { steps.firstIndex(of: $0) } ?? steps.count) { i in
                guard i < steps.count else { return }
                m.edit { $0.video.applyQuality(steps[i]) }
            }]))
        }
        if kinds.isEmpty {
            rows.append(row("Bitrate", target))
        } else {
            var mode = popup(kinds.map(\.title), selected: kinds.firstIndex(of: model.bitrateKind) ?? 0) { i in m.bitrateKind = kinds[i] }
            mode.width = .fixed(96)
            rows.append(row("Bitrate", [mode] + target))
        }
        if mastering || model.bitrateKind.showsMaximum {
            rows.append(row("Max Bitrate", [check("Limit", on: model.hasMaxBitrate, enabled: !mastering, width: .fixed(96)) { on in
                m.hasMaxBitrate = on
            }] + scrub(value: model.maxBitrateMbps, range: 0.5...600, step: 0.5, unit: "Mbit/s", decimals: 1,
                       defaultValue: Double(d.video.bitrate.maxBitsPerSecond ?? d.video.bitrate.averageBitsPerSecond * 3 / 2) / 1_000_000,
                       enabled: !mastering && model.hasMaxBitrate) { v in m.maxBitrateMbps = v }))
        }
        rows.append(hardware)
        rows += encoderSpeedRows(mastering: mastering)
        rows += colorSpaceRows(s)
        return rows
    }

    private func frameRateRow() -> ExportRow {
        var rates = ExportDialogModel.frameRates
        if !rates.contains(model.fps) { rates.append(model.fps) }
        let m = model
        return row("Frame Rate", [popup(rates.map(Self.fpsText), selected: rates.firstIndex(of: model.fps) ?? 0) { i in m.fps = rates[i] }])
    }

    private func frameOutputRows(_ output: FrameOutput, s: ExportSettings, d: ExportSettings) -> [ExportRow] {
        var rows: [ExportRow] = []
        let m = model
        if case .sequence(let format) = output {
            let formats = FrameStillFormat.available
            rows.append(row("Image Format", [popup(formats.map(\.displayName), selected: formats.firstIndex(of: format) ?? 0) { i in
                m.edit { $0.frameOutput = .sequence(formats[i]) }
            }]))
        } else {
            rows.append(row("Format", [text("Animated GIF, loops, 256 colors per frame", width: .fixed(300))]))
        }
        rows += sizeRows(s: s, d: d)
        rows.append(frameRateRow())
        return rows
    }

    private func encoderSpeedRows(mastering: Bool) -> [ExportRow] {
        let speeds = EncoderSpeed.allCases
        let current = model.encoderSpeed
        let m = model
        var rows = [row("Encoder Speed", [popup(speeds.map(\.displayName), selected: speeds.firstIndex(of: current) ?? 0,
                                                enabled: !mastering) { i in
            m.encoderSpeed = speeds[i]
            var a = AppSettings.load(); a.exportEncoderSpeed = speeds[i]; a.save()
        }])]
        if !mastering, let hint = ExportDialogModel.encoderSpeedHint(current) {
            rows.append(row("", [text(hint, .label3, width: .fixed(260), caption: true)]))
        }
        return rows
    }

    private func sizeRows(s: ExportSettings, d: ExportSettings) -> [ExportRow] {
        var sizes = Self.sizes
        if let f = model.sequences.first(where: { $0.id == model.selectedID })?.format, f.isValid {
            let own = (f.width & ~1, f.height & ~1)
            if !sizes.contains(where: { $0 == own }) { sizes.insert(own, at: 0) }
        }
        let cur = (s.video.width, s.video.height)
        let match = sizes.firstIndex { $0 == cur }
        let isCustom = customSize || match == nil
        let names = sizes.map { "\($0.0) \u{00D7} \($0.1)" } + ["Custom"]
        let m = model, setCustom = setCustomSize
        var rows = [row("Size", [popup(names, selected: isCustom ? names.count - 1 : match ?? 0) { i in
            if i == sizes.count { setCustom(true) } else {
                setCustom(false)
                m.width = sizes[i].0; m.height = sizes[i].1
            }
        }])]
        if isCustom {
            let w = scrub(value: Double(s.video.width), range: 2...8192, step: 2, defaultValue: Double(d.video.width)) { v in m.width = Int(v) & ~1 }
            let h = scrub(value: Double(s.video.height), range: 2...8192, step: 2, defaultValue: Double(d.video.height)) { v in m.height = Int(v) & ~1 }
            rows.append(row("Custom Size", w + [text("\u{00D7}", .label3)] + h))
        }
        return rows
    }

    // MARK: Audio

    func audioRows() -> [ExportRow] {
        let s = model.settings, m = model
        let on = s.audio.enabled
        var rows: [ExportRow] = []
        if s.audioOnly == nil {
            rows.append(row("Include Audio", [check("Include audio in the file", on: on) { v in m.edit { $0.audio.enabled = v } }]))
            rows.append(row("Codec", [popup(["AAC", "PCM"], selected: s.audio.codec == .aac ? 0 : 1, enabled: on) { i in
                m.edit { $0.audio.codec = i == 0 ? .aac : .pcm }
            }]))
        }
        let rates = [44_100, 48_000, 96_000]
        rows.append(row("Sample Rate", [popup(["44.1 kHz", "48 kHz", "96 kHz"], selected: rates.firstIndex(of: s.audio.sampleRate) ?? 1,
                                              enabled: on, rebuild: false) { i in m.edit { $0.audio.sampleRate = rates[i] } }]))
        if s.effectiveAudio.codec == .aac {
            let rates = [128_000, 192_000, 256_000, 320_000]
            rows.append(row("Bitrate", [popup(["128 kbit/s", "192 kbit/s", "256 kbit/s", "320 kbit/s"],
                                              selected: rates.firstIndex(of: s.audio.bitrate) ?? 1, enabled: on, rebuild: false) { i in
                m.edit { $0.audio.bitrate = rates[i] }
            }]))
        } else {
            let depths = s.audioOnly == .flac ? [16, 24] : [16, 24, 32]
            rows.append(row("Bit Depth", [popup(depths.map { "\($0)-bit" }, selected: depths.firstIndex(of: s.audio.pcmBitDepth) ?? 1,
                                                enabled: on, rebuild: false) { i in m.edit { $0.audio.pcmBitDepth = depths[i] } }]))
        }
        var norm = [check("", on: s.audio.loudness != nil, enabled: on) { v in m.normalizeLoudness = v }]
        if let ln = s.audio.loudness {
            norm += scrub(value: ln.targetLUFS, range: -40...(-5), step: 1, unit: "LUFS", decimals: 1,
                          defaultValue: model.presetSettings.audio.loudness?.targetLUFS, enabled: on) { v in
                m.edit { $0.audio.loudness?.targetLUFS = v.rounded() }
            }
            let names = AudioDeliveryTarget.allCases.map(\.displayName)
            norm.append(popup(["Custom"] + names, selected: (model.deliveryTargetIndex ?? -1) + 1, enabled: on) { i in
                if i > 0 { m.edit { $0.audio.loudness = AudioDeliveryTarget.allCases[i - 1].normalization } }
            })
        }
        rows.append(row("Normalize", norm))
        if !model.loudnessRangeAvailable {
            rows.append(row("Loudness Range", [text("Needs a program of 60 s or more", .label3, width: .fill)]))
        }
        rows += audioCheckRows(enabled: on)
        rows += stemRows()
        rows += cutDownRows()
        return rows
    }

    private func cutDownRows() -> [ExportRow] {
        let plans = model.cutDownPlans
        guard !plans.isEmpty else { return [] }
        let m = model
        var rows: [ExportRow] = plans.map { plan in
            row("\(plan.targetSeconds) s", plan.ranges.enumerated().map { i, r in
                let k = ExportDialogModel.CutDownKey(target: plan.targetSeconds, index: i)
                let title = "\(Int(r.start.exportSeconds.rounded()))\u{2013}\(Int(r.end.exportSeconds.rounded())) s"
                return check(title, on: model.isCutDownChecked(k)) { v in m.setCutDownChecked(k, v) }
            })
        }
        let hint = model.outputDirectory == nil ? "Choose a folder first" : "One file per checked range"
        rows.append(row("Cut-downs", [button("Export Cut-downs", enabled: model.checkedCutDownCount > 0 && model.outputDirectory != nil,
                                             then: model.onExportCutDowns),
                                      text(hint, .label3, width: .fill)]))
        return rows
    }

    private func stemRows() -> [ExportRow] {
        guard model.canExportStems else { return [] }
        let m = model, changed = changed
        let size = ByteCountFormatter.string(fromByteCount: model.stemEstimatedBytes, countStyle: .file)
        var hint = model.outputDirectory == nil ? SQL10n.string("Choose a folder first")
            : SQL10n.format("About %@ in %@ files", size, String(model.activeStems.count))
        if let s = model.stemStatus { hint = SQL10n.localized(s) }
        let presets = model.stemPresets
        var rows = [row("Stem Roles", model.stemPlan.map { stem in
            check(stem.title, on: model.isStemChecked(stem.id)) { on in m.setStemChecked(stem.id, on) }
        })]
        var presetItems = [popup(["Preset"] + presets.map(\.name), selected: 0) { i in
            if i > 0 { m.applyStemPreset(presets[i - 1]) }
        }]
        if model.stemPresetStore != nil {
            presetItems.append(button("Save Choice", enabled: !model.activeStems.isEmpty) { m.saveStemSelection(); changed(true) })
        }
        rows.append(row("Stem Presets", presetItems))
        rows.append(row("Stems", [button(model.isExportingStems ? "Exporting\u{2026}" : "Export Stems",
                                         enabled: !model.isExportingStems && model.outputDirectory != nil && !model.activeStems.isEmpty,
                                         then: exportStems),
                                  text(hint, .label3, width: .fill)]))
        return rows
    }

    private func chapterRows() -> [ExportRow] {
        guard let c = model.chapters else { return [] }
        let chapterText = c.text
        var copy: (@MainActor () -> Void)?
        if let f = copyText { copy = { f(chapterText) } }
        let hint: String = c.warnings.isEmpty ? SQL10n.string("Paste into the video description") : SQL10n.localized(c.warnings[0])
        let tone: Item.Tone = c.warnings.isEmpty ? .label3 : .warning
        var rows: [ExportRow] = [row("Chapters", [button("Copy Chapters", enabled: true, then: copy), text(hint, tone, width: .fill)])]
        for w in c.warnings.dropFirst() { rows.append(row("Warning", [text(SQL10n.localized(w), .warning, width: .fill)])) }
        return rows
    }

    private func audioCheckRows(enabled: Bool) -> [ExportRow] {
        var hint = SQL10n.string("Loudness, true peak, clipping, gaps, dual mono, sync")
        if let e = model.audioCheckError { hint = SQL10n.localized(e) }
        let title = model.isCheckingAudio ? "Checking\u{2026}" : (model.hasAudioCheck ? "Check Again" : "Check Audio")
        var rows = [row("Audio Check", [button(title, enabled: enabled && !model.isCheckingAudio, then: checkAudio),
                                        text(hint, .label3, width: .fill)])]
        for f in model.audioFindings {
            let tone: Item.Tone = f.severity == .pass ? .green : (f.severity == .warning ? .warning : .red)
            let mark = f.severity == .pass ? "Pass" : (f.severity == .warning ? "Warning" : "Fail")
            rows.append(row(mark, [text(SQL10n.localized(f.message), tone, width: .fill)]))
        }
        return rows
    }

    // MARK: Captions and range

    func captionRows() -> [ExportRow] {
        let modes: [CaptionMode] = [.none, .burnIn, .sidecarSRT, .sidecarVTT, .sidecarITT]
        let m = model
        return [row("Captions", [segmented(["None", "Burn in", "SRT file", "VTT file", "iTT file"],
                                           selected: modes.firstIndex(of: model.captions) ?? 0,
                                           disabled: model.settings.audioOnly != nil ? [1] : [], width: 78) { i in m.captions = modes[i] }])]
    }

    private func coverRows() -> [ExportRow] {
        let formats: [CoverImageFormat] = [.png, .jpg]
        let m = model
        var items = [check("Also save cover image", on: model.coverImage != nil) { on in m.coverImage = on ? .png : nil }]
        guard let f = model.coverImage else { return [row("Cover", items)] }
        items.append(segmented(["PNG", "JPG"], selected: formats.firstIndex(of: f) ?? 0, width: 44) { i in m.coverImage = formats[i] })
        return [row("Cover", items), row("Cover Frame", [text(model.coverFrameText, .label3, width: .fixed(300))])]
    }

    func rangeRows() -> [ExportRow] {
        let fd = model.settings.video.frameDuration
        let m = model
        var rows = [row("Range", [segmented(["Entire", "In to Out", "Custom", "Selected"], selected: model.rangeMode,
                                            disabled: Set((model.canUseInOut ? [] : [1]) + (model.canUseSelection ? [] : [3])),
                                            width: 70) { i in m.rangeMode = i }])]
        if model.rangeMode == 2 {
            let r = model.rangeSeconds
            let total = model.sequences.first(where: { $0.id == model.selectedID })?.duration.exportSeconds ?? 0
            rows.append(row("Start", scrub(value: r.start, range: 0...max(total, 0.1), step: 0.5, unit: "s", decimals: 2,
                                           defaultValue: 0, rebuild: true) { v in m.setCustomRange(startSeconds: v) }))
            rows.append(row("End", scrub(value: r.end, range: 0...max(total, 0.1), step: 0.5, unit: "s", decimals: 2,
                                         defaultValue: total, rebuild: true) { v in m.setCustomRange(endSeconds: v) }))
        }
        if model.rangeMode == 3, model.selectedClipCount > 1 {
            rows.append(row("Files", [check("One file per clip", on: model.oneFilePerClip) { on in m.oneFilePerClip = on }]))
        }
        let duration = model.effectiveDuration(of: model.selectedID, settings: model.settings)
        rows.append(row("Duration", [text(ExportDecodeError.timecode(duration, frameDuration: fd), width: .fixed(200))]))
        if model.settings.audioOnly == nil, model.settings.frameOutput == nil { rows += coverRows() }
        if let r = model.sequences.first(where: { $0.id == model.selectedID })?.inOut {
            rows.append(row("In / Out", [text(ExportDecodeError.timecode(r.start, frameDuration: fd) + " \u{2013} "
                                              + ExportDecodeError.timecode(r.end, frameDuration: fd), width: .fixed(260))]))
        }
        return rows
    }

    // MARK: Advanced

    func advancedRows() -> [ExportRow] {
        let s = model.settings, d = model.presetSettings, m = model
        let mastering = s.video.codec.isMastering
        var rows: [ExportRow] = []
        if s.frameOutput != nil { return rows }
        let channels = row("Channels", [popup(["Mono", "Stereo"], selected: s.audio.channels == 1 ? 0 : 1,
                                              enabled: s.audioOnly != nil || s.audio.enabled, rebuild: false) { i in
            m.edit { $0.audio.channels = i == 0 ? 1 : 2 }
        }])
        let peak = s.audio.loudness.map { ln in
            row("True Peak Max", scrub(value: ln.truePeakCeilingDB, range: -9...0, step: 0.5, unit: "dBTP", decimals: 1,
                                       defaultValue: d.audio.loudness?.truePeakCeilingDB, enabled: s.audioOnly != nil || s.audio.enabled) { v in
                m.edit { $0.audio.loudness?.truePeakCeilingDB = v }
            })
        }
        if s.audioOnly != nil {
            rows.append(channels)
            if let peak { rows.append(peak) }
            return rows
        }
        rows.append(row("Keyframe Every", scrub(value: Double(s.video.keyframeInterval), range: 1...600, step: 1, unit: "frames",
                                                defaultValue: Double(d.video.keyframeInterval), enabled: !mastering) { v in
            m.edit { $0.video.keyframeInterval = Int(v) }
        }))
        rows.append(row("B-Frames", [check("Allow frame reordering", on: s.video.allowsFrameReordering, enabled: !mastering, rebuild: false) { on in
            m.edit { $0.video.allowsFrameReordering = on }
        }]))
        rows.append(row("Alpha", [check("Keep transparency (ProRes 4444)", on: s.video.preservesAlpha, enabled: s.video.codec == .prores4444) { on in
            m.edit { $0.video.preservesAlpha = on }
        }]))
        rows.append(row("Bit Depth", [text("\(s.video.bitDepth)-bit", width: .fixed(120))]))
        rows.append(channels)
        if let peak { rows.append(peak) }
        rows.append(row("Damaged Frames", [check("Continue on damaged frames", on: model.continueOnDamagedFrames, rebuild: false) { on in
            m.continueOnDamagedFrames = on
        }]))
        rows.append(row("HDR to SDR", [check("Adjust the conversion of HDR clips", on: s.hdrToSDR != nil) { on in
            m.edit { $0.hdrToSDR = on ? HDRToSDR() : nil }
        }]))
        if let h = s.hdrToSDR {
            rows.append(row("HDR Exposure", scrub(value: h.exposureStops, range: -4...4, step: 0.1, unit: "stops", decimals: 1,
                                                  defaultValue: 0) { v in m.edit { $0.hdrToSDR?.exposureStops = v } }))
            rows.append(row("HDR Gamut", [check("Compress colors outside Rec.709", on: h.compressesGamut, rebuild: false) { on in
                m.edit { $0.hdrToSDR?.compressesGamut = on }
            }]))
        }
        return rows
    }

    private func colorSpaceRows(_ s: ExportSettings) -> [ExportRow] {
        guard s.video.codec == .hevc else { return [row("Color Space", [text("Rec. 709 (tagged 1-1-1)", width: .fixed(200))])] }
        let m = model
        let titles = ["Rec. 709 (SDR)"] + HDRDelivery.Transfer.allCases.map { "Rec. 2020 \($0.title)" }
        let sel = s.hdrDelivery.flatMap { h in HDRDelivery.Transfer.allCases.firstIndex(of: h.transfer) }.map { $0 + 1 } ?? 0
        var rows = [row("Color Space", [popup(titles, selected: sel) { i in
            let peak = s.hdrDelivery?.peakNits ?? 1000
            m.edit { $0.hdrDelivery = i == 0 ? nil : HDRDelivery(transfer: HDRDelivery.Transfer.allCases[i - 1], peakNits: peak) }
        }])]
        if let h = s.hdrDelivery {
            rows.append(row("Peak Brightness", scrub(value: h.peakNits, range: 100...10_000, step: 50, unit: "nits",
                                                     defaultValue: 1000) { v in
                m.edit { $0.hdrDelivery = HDRDelivery(transfer: h.transfer, peakNits: v) }
            }))
        }
        return rows
    }

    static func fpsText(_ fps: Double) -> String {
        (fps == fps.rounded() ? "\(Int(fps))" : String(format: "%g", fps)) + " fps"
    }
}
