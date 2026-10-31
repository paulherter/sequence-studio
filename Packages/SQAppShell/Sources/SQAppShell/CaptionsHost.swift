import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQExport
import SQInspectorUI
import SQTranscribe
import SQUIKit

/// The Text panel of the shared shell (Windows app, Mac `SQ_SHARED_UI`): the shared-toolkit `TextPanelDraw` (List: find /
/// replace, the caption list, the row menu; Look: the caption look; Templates: the Library's text templates) on the
/// dock's Text card, wired like the Mac host (App/Sources/AppController+Captions.swift, EditorPanels+TextTemplatesTab).
/// The Transcribe tab (and with it Create Captions… and the overwrite question) appears once `useTranscription` gives the
/// panel a service: the Mac passes `SpeechAnalyzerTranscriber`; Windows has none yet (`UnavailableTranscriptionService`).
/// Coordinates: `frame` in points, events arrive in pixels.
@MainActor
public final class CaptionsHost {
    public let panel: TextPanelDraw
    public private(set) var frame: CGRect = .zero
    public private(set) var hasFocus = false
    private var isPressed = false
    /// The session changed since the Look tab last read it.
    private var stale = true
    /// The Templates tab's tile pictures (image slot `TextTemplateTileAtlas.slot`; the hosts upload `templateImage`).
    public let templatePictures = TextTemplateTileAtlas()
    /// The tile atlas for the renderer: (slot, image, generation), nil before the first picture.
    public var templateImage: (Int, RGBAImage, Int)? {
        templatePictures.image.height > 0 ? (TextTemplateTileAtlas.slot, templatePictures.image, templatePictures.generation) : nil
    }
    /// The Look tab's swatches: the app's SQ color picker popover, anchor in window points (Windows: `InspectorHost`).
    /// nil: swatches do nothing (both apps wire it to the Effect Controls picker).
    public var pickColor: (@MainActor (_ current: EffectColor, _ anchor: CGRect,
                                       _ change: @escaping @MainActor (EffectColor?) -> Void) -> Void)? {
        didSet {
            guard let pick = pickColor else { panel.onPickColor = nil; return }
            panel.onPickColor = { [weak self] (current: EffectColor, anchor: CGRect,
                                              change: @escaping @MainActor (EffectColor?) -> Void) in
                let origin = self?.frame.origin ?? .zero
                pick(current, anchor.offsetBy(dx: origin.x, dy: origin.y), change)
            }
        }
    }

    weak var shell: ShellHost?

    public init(session: EditorSession, menus: MenuController, shell: ShellHost) {
        self.shell = shell
        panel = TextPanelDraw(session: session)
        shell.runAutoCaptions = { [weak self] in self?.autoCaptions() != nil }
        registerAudioCommands()
        shell.editCaptionInPanel = { [weak self] in self?.editCaption($0) ?? false }
        let list = panel.captions
        list.createHint = AppPlatform.transcriptionHint
        panel.onMenu = { [weak self, weak menus] items, anchor in
            guard let self, let menus else { return }
            let r = anchor.offsetBy(dx: frame.minX, dy: frame.minY)
            menus.present(items: items, at: CGPoint(x: r.minX, y: r.maxY), anchor: r)
        }
        list.onSeek = { [weak session] t in session?.seek(to: t) }
        panel.onStatus = { [weak shell] in shell?.onStatus?($0) }
        list.onImportSRT = { [weak list, weak shell] in
            guard let list, let url = (shell?.files as? PanelFileChooser)?.chooseSubtitles() else { return }
            guard let data = try? Data(contentsOf: url) else { shell?.onStatus?(SQL10n.string("Could not open the subtitle file.")); return }
            list.importSubtitles(data: data, fileExtension: url.pathExtension)
        }
        list.onExportSRT = { [weak list, weak shell, weak session] in
            guard let list, let shell else { return }
            let cues = list.exportItems.map { SRTCue(lines: $0.lines, range: $0.range) }
            guard !cues.isEmpty else { shell.onStatus?(SQL10n.string("There are no captions to export.")); return }
            let name = (session?.activeTimeline?.name ?? "Captions") + ".srt"
            guard let url = (shell.files as? PanelFileChooser)?.chooseSRTLocation(suggestedName: name) else { return }
            do {
                try SRTWriter.write(cues, range: .entireSequence, to: url)
                shell.onStatus?(SQL10n.plural(cues.count, one: "Exported %@ caption.", other: "Exported %@ captions."))
            } catch {
                shell.onStatus?(SQL10n.format("Could not write the SRT file: %@", SQL10n.errorText(error)))
            }
        }
        // Save Current as Look…, Save as New, Rename: the shell's name field dialog (nil = canceled).
        panel.style.askName = { [weak shell] title, initial, done in
            guard let shell else { return done(initial) }
            Task { @MainActor in
                let d = ShellDialog(SQL10n.string(title))
                d.form = ShellForm([.field(id: "name", label: SQL10n.string("Name"), value: initial)])
                d.addButton(SQL10n.string("OK"), role: .default)
                d.addButton(SQL10n.string("Cancel"), role: .cancel)
                done(await shell.ask(d) == .first ? d.form?.text("name") : nil)
            }
        }
        panel.useLibrary(LibraryStores.presetStore)
        templatePictures.decodePicture = TemplatePictureDecoder.decode
        panel.templates.picture = { [weak self] in self?.templatePictures.picture(for: $0) }
        // The session's change hook is shared: keep whoever set it before.
        let previous = session.onChange
        session.onChange = { [weak self] change in
            previous?(change)
            self?.stale = true
        }
    }

    /// Adds the Transcribe tab over `service` (one model per sequence); Create Captions… and "Replace the transcript?" open
    /// the shell dialogs.
    public func useTranscription(_ service: @escaping @MainActor () -> any TranscriptionService) {
        panel.useTranscription(service)
        panel.transcript.onCreateCaptions = { [weak self] in
            guard let self, let m = panel.transcript.model else { return }
            Task { @MainActor in await self.createCaptions(model: m) }
        }
        panel.transcript.onConfirmOverwrite = { [weak self] in
            guard let self, let m = panel.transcript.model else { return }
            Task { @MainActor in await self.confirmOverwrite(model: m) }
        }
    }

    /// The Create Captions dialog over `model`'s transcript (the Mac `CaptionsTabView.presentCreateCaptions`): the chosen
    /// style and limits go into the model, then it makes the captions. False when canceled.
    @discardableResult
    public func createCaptions(model: CaptionsPanelModel) async -> Bool {
        guard let shell else { return false }
        let styles = Self.styles(of: model)
        guard let c = await shell.askCreateCaptions(styles: styles, selected: model.selectedPresetIndex) else { return false }
        model.selectedPresetIndex = c.style
        model.setOptions(maxCharsPerLine: c.maxChars, lines: c.lines, minDuration: CaptionsPanelModel.minDuration(seconds: c.minSeconds),
                         gapFrames: c.gapFrames)
        model.createCaptions()
        return true
    }

    /// The model's presets as the dialog's style list (limits of each preset; the gap in frames of the model's sequence).
    public static func styles(of model: CaptionsPanelModel) -> [ShellCaptionStyle] {
        let fd = Double(model.frameDuration.value) / Double(max(model.frameDuration.timescale, 1))
        return model.presets.map { n in
            ShellCaptionStyle(name: n.name, maxChars: n.preset.maxCharsPerLine, lines: n.preset.maxLines,
                              minSeconds: Double(n.preset.minDuration.value) / Double(max(n.preset.minDuration.timescale, 1)),
                              gapFrames: fd > 0 ? Int((Double(n.preset.gap.value) / Double(max(n.preset.gap.timescale, 1)) / fd).rounded()) : 0)
        }
    }

    /// Transcribing again with a transcript present: the "Replace the transcript?" question (the Mac `confirmOverwrite`).
    public func confirmOverwrite(model: CaptionsPanelModel) async {
        guard let shell, model.needsOverwriteConfirmation else { return }
        if await shell.confirmReplaceTranscript() { model.confirmOverwrite() } else { model.cancelOverwrite() }
    }

    /// Places the panel on the dock's Text card (`card` in points, nil while the card is hidden).
    public func layout(_ card: CGRect?) {
        frame = card ?? .zero
        guard frame.width > 0 else { hasFocus = false; return }
        panel.size = frame.size
        // The List tab reads the session each draw; the Look tab only after a change (its state reads are heavier).
        if stale, panel.tab == .style || panel.tabs.contains(.transcript) { panel.sync(); stale = false }
        if panel.tab == .templates { templatePictures.prepare(panel.templates.shownTiles) }
        _ = panel.tick()
    }

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        guard frame.width > 0, frame.height > 0 else { return }
        panel.theme = theme
        templatePictures.background = Self.tileBackground(theme)
        c.saveGState()
        c.clip(to: frame)
        c.translateBy(x: frame.minX, y: frame.minY)
        panel.draw(&c)
        c.restoreGState()
    }

    /// The Mac `Theme.Colors.tileBackground`: #222222 in dark, the content color 4 % toward black in light (sRGB bytes).
    static func tileBackground(_ t: DrawTheme) -> (UInt8, UInt8, UInt8) {
        guard !t.palette.isDark else { return (34, 34, 34) }
        let c = t.content
        func b(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * 0.96 * 255).rounded()))) }
        return (b(c.r), b(c.g), b(c.b))
    }

    /// Routes one event in pixels; true when the panel took it.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        guard frame.width > 0 else { return false }
        func local(_ x: Float, _ y: Float) -> CGPoint {
            CGPoint(x: CGFloat(x / scale) - frame.minX, y: CGFloat(y / scale) - frame.minY)
        }
        func inside(_ q: CGPoint) -> Bool { CGRect(origin: .zero, size: frame.size).contains(q) }
        switch e {
        case .mouseDown(let x, let y, let m):
            let q = local(x, y)
            hasFocus = inside(q)
            guard hasFocus else { return false }
            isPressed = true
            panel.mouseDown(at: q, modifiers: m)
        case .mouseDragged(let x, let y):
            guard isPressed else { return false }
            panel.mouseDragged(to: local(x, y))
        case .mouseUp(let x, let y):
            guard isPressed else { return false }
            isPressed = false
            panel.mouseUp(at: local(x, y))
        case .mouseMoved(let x, let y):
            let q = local(x, y)
            panel.mouseMoved(to: inside(q) ? q : nil)
            if inside(q) { HostHover.current.offerTip(panel.help(at: q)) }
            return false
        case .scroll(let x, let y, _, let dy, _):
            let q = local(x, y)
            guard inside(q) else { return false }
            _ = panel.scroll(at: q, dy: CGFloat(dy / scale))
        case .keyDown(let k, let m):
            guard hasFocus else { return false }
            return panel.key(k, modifiers: m)
        }
        return true
    }
}
