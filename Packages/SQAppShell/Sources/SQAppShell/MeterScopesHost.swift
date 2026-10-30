import Foundation
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQEditorSession

/// The audio meter strip right of the timeline and the Scopes card right of the Program monitor (shown from the
/// monitor menu's "Scopes"), wired to the engine as the Mac host wires `AudioMeterPanelView` and `ScopesPanelView`
/// (App/Sources/EditorPanels.swift).
@MainActor
public final class MeterScopesHost {
    public let meter = MeterPanel()
    public let scopes = ScopesPanel()
    public var showsScopes = false
    /// Image slots of the two scope pictures.
    /// shortcut: fixed slots 2 and 3 of the four; upgrade to a slot allocator when timeline thumbnails take slots.
    public static let scopeSlotBase = 2
    /// Meter strip width (points): the 48 pt meter, the gap and the 40 pt loudness columns, plus the card inset.
    public static let meterWidth: CGFloat = 104
    public static let scopesWidth: CGFloat = 320
    private var options: PanelStripOptions?
    private var pixelScale: Float = 1
    private weak var menus: MenuController?
    private let session: EditorSession
    private let engine: any ProgramEngine
    private let picture: any AppPictureSource

    public init(session: EditorSession, engine: any ProgramEngine, picture: any AppPictureSource, menus: MenuController) {
        self.session = session
        self.engine = engine
        self.picture = picture
        self.menus = menus
        meter.reading = { [weak engine] in
            guard let engine, let r = engine.meterReading else { return nil }
            return (ObjectIdentifier(engine), r.sequence, r.peaks)
        }
        meter.loudnessReading = { [weak engine] in engine?.loudnessLevels.map(LoudnessReading.init) }
        meter.loudnessTargetProvider = { [weak session] in LoudnessTarget(delivery: session?.activeTimeline?.deliveryTarget) }
        meter.monoProvider = { [weak session] in session?.activeTimeline?.channelLayout == .mono }
        meter.onResetLoudness = { [weak engine] in engine?.resetLoudnessMeter() }
        // Listening volume, Dim and Solo/Mute only change what the speakers play (the Mac PlaybackEngine stages).
        meter.onMonitorGainChange = { [weak picture] in picture?.setMonitorGain($0) }
        meter.onChannelMonitorChange = { [weak picture] in picture?.setChannelMonitor($0) }
        meter.onMenu = { [weak menus] items, p in menus?.present(items: items, at: p, pointer: p) }
        scopes.onMenu = { [weak menus] items, r in menus?.present(items: items, at: CGPoint(x: r.minX, y: r.maxY), anchor: r) }
    }

    /// Gives the Scopes tab its "..." in `dock`'s strip (the Mac panel header's options button); it opens the tab menu.
    public func dock(in dock: ShellDock) {
        let o = PanelStripOptions(panel: .scopes, dock: dock)
        o.onOpen = { [weak self, weak dock] p in
            guard let dock else { return }
            self?.menus?.present(items: dock.tabMenu(.scopes), at: p)
        }
        options = o
    }

    /// Splits the screen's cards (pixels): returns the monitor and timeline rects left for those panels.
    public func layout(monitor: DrawRect, timeline: DrawRect, scale: Float, gap: Float) -> (monitor: DrawRect, timeline: DrawRect) {
        var m = monitor, t = timeline
        let mw = min(Float(Self.meterWidth) * scale, t.w / 4)
        meter.layout(DrawRect(x: t.x + t.w - mw, y: t.y, w: mw, h: t.h), scale: scale)
        t.w -= mw + gap
        if showsScopes {
            let sw = min(Float(Self.scopesWidth) * scale, m.w / 2)
            scopes.emptyText = session.activeTimeline == nil ? ("No picture to measure", "Open a sequence to see its scopes.") : nil
            scopes.layout(DrawRect(x: m.x + m.w - sw, y: m.y, w: sw, h: m.h), scale: scale)
            m.w -= sw + gap
            updateScopes()
        }
        meter.poll(now: ProcessInfo.processInfo.systemUptime)
        return (m, t)
    }

    /// Places the meter and the Scopes on their dock cards (pixels; zero = not shown).
    public func layout(meter m: DrawRect, scopes r: DrawRect, scale: Float) {
        pixelScale = scale
        meter.layout(m, scale: scale)
        if showsScopes, r.w > 0, r.h > 0 {
            scopes.emptyText = session.activeTimeline == nil ? ("No picture to measure", "Open a sequence to see its scopes.") : nil
            scopes.layout(r, scale: scale)
            updateScopes()
        }
        meter.poll(now: ProcessInfo.processInfo.systemUptime)
    }

    private func updateScopes() {
        guard picture.hasPicture else { return }
        let generation = picture.pictureGeneration
        if let gpu = picture as? any ScopeCountsSource, scopes.measure(from: gpu, generation: generation) { return }
        guard let p = picture.scopePicture() else { return }
        scopes.update(nv12: p.bytes, width: p.width, height: p.height, fullRange: p.fullRange, rgba: p.rgba,
                      generation: generation)
    }

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        meter.theme = theme
        meter.draw(&c)
        if showsScopes { scopes.theme = theme; scopes.draw(&c, slotBase: Self.scopeSlotBase); options?.draw(&c, theme: theme) }
    }

    /// The scope pictures for the renderer's image slots: (slot, image, generation).
    /// Also the monitor's own image (the Slip two-up, `monitorImage`), so the renderer loop has one list to upload.
    public var images: [(Int, RGBAImage, Int)] {
        let extra = monitorImage?().map { [$0] } ?? []
        guard showsScopes else { return extra }
        return extra + scopes.images.enumerated().compactMap { i, img in
            img.map { (Self.scopeSlotBase + i, $0, scopes.imageGeneration * 2 + i) }
        }
    }
    public var monitorImage: (() -> (Int, RGBAImage, Int)?)?

    public func handle(_ e: InputEvent) -> Bool {
        if meter.handle(e) { return true }
        if showsScopes, options?.handle(e, scale: pixelScale) == true { return true }
        return showsScopes && scopes.handle(e)
    }
}

