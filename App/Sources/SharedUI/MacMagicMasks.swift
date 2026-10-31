import Accelerate
import AppKit
import SQAppShell
import SQDrawKit
import SQAnalysis
import SQCore
import SQEditorSession
import SQEditorUI
import SQInspectorUI
import SQMonitorUI
import SQPlayback

/// The Mask tool's Magic mode on the Mac shared UI (SQAppShell `AppMagicMasks`): the AppKit UI's `MagicMaskTool` (Vision /
/// Core ML segmentation, `MagicMatteStore`) picks the clicked object of the parked frame and stores its matte; the Program
/// engine shows it. The tool talks to an AppKit `TransformOverlayView` that is never shown: the shared overlay draws the
/// masks from Effect Controls.
/// The hover highlight rides the Mask Tint picture (`hover`, `maskTint`). Tracking and corrections: MacMagicMasks+Track.swift.
/// The hover preview over an unselected clip is `hover(_:target:)` with that clip (`MagicMaskTool.previewMatte`).
/// shortcut: no pick tint or click dots on the shared overlay; upgrade by drawing `magicPick` as an image slot.
@MainActor
final class MacMagicMasks: AppMagicMasks {
    private let overlay = TransformOverlayView(frame: .zero)
    let tool: MagicMaskTool
    private var target: Clip.ID?
    let model: EffectControlsModel
    let session: EditorSession
    var out: (String) -> Void = { _ in }
    /// Tracked frames changed (a run ended or a click corrected a frame): the timeline's weak-tracking strip is read again
    /// (`MagicTrackHealthCache.forget`, as the AppKit `EditorPanels+MaskTool`).
    var onTracked: () -> Void = {}
    var trackLine = TrackStatusLine()
    var pickWatch = MagicPickWatch()
    var magicOn = false
    private var hoverPoint: Vec2?
    /// The clip the pointer hovers (the selected one, or an unselected one previewed).
    private var hoverTarget: Clip.ID?
    /// The object under the pointer as a tint plane (`hasHover`): hard labels first, the soft matte once it is made.
    private var hoverPlane: (key: String, plane: TintPlane)?
    /// Mask Tint: each stored matte as its 30 % tint alpha (0...1), read off the main thread.
    private let tints = MatteTintCache<TintPlane> { m in
        var a = [Float](repeating: 0, count: m.width * m.height), lo: Float = 0, hi: Float = 1, k: Float = 0.3
        m.values.withUnsafeBufferPointer { vDSP_vclip($0.baseAddress!, 1, &lo, &hi, &a, 1, vDSP_Length(a.count)) }
        vDSP_vsmul(a, 1, &k, &a, 1, vDSP_Length(a.count))
        return TintPlane(width: m.width, height: m.height, alpha: a)
    }
    struct TintPlane { let width: Int, height: Int, alpha: [Float] }
    private static func plane(_ m: SubjectMatte, alpha k: Float) -> TintPlane {
        var a = [Float](repeating: 0, count: m.width * m.height), lo: Float = 0, hi: Float = 1, k = k
        m.values.withUnsafeBufferPointer { vDSP_vclip($0.baseAddress!, 1, &lo, &hi, &a, 1, vDSP_Length(a.count)) }
        vDSP_vsmul(a, 1, &k, &a, 1, vDSP_Length(a.count))
        return TintPlane(width: m.width, height: m.height, alpha: a)
    }
    /// The last composed tint: the keys and the size it was made from.
    private var tintMade: (keys: [String], image: RGBAImage, generation: Int)?
    private var tintGeneration = 0

    init(model: EffectControlsModel, session: EditorSession, status rawStatus: @escaping (String) -> Void) {
        self.model = model
        self.session = session
        // Every line goes through here and is noted, so a run's silent end clears only its own "Tracking…" line.
        var noteWrote: () -> Void = {}
        let status: (String) -> Void = { s in noteWrote(); rawStatus(s) }
        tool = MagicMaskTool(model: model, overlay: overlay)
        tool.targetClip = { [weak self] in self?.target }
        tool.mediaURL = { [weak session] id in session?.project.media(id).map { URL(fileURLWithPath: $0.path) } }
        tool.isPlaying = { [weak session] in session?.isPlaying ?? false }
        tool.onStatus = status
        tool.onPicked = { [weak session] in session?.engine.redraw() }
        out = status
        tool.onMaskChanged = { session.engine.redraw() }
        tool.onCorrect = { [weak self] id, at, subtract in self?.magicCorrect(id, at: at, subtract: subtract) }
        noteWrote = { [weak self] in self?.trackLine.wrote() }
        model.onTrackMask = { [weak self] id, forward in self?.trackMask(id, forward: forward) }
        model.onTrackMagic = { [weak self] id, command in self?.trackMagicMask(id, command) }
        let previousChange = session.onChange
        session.onChange = { [weak self] change in
            previousChange?(change)
            guard change.contains(.project) else { return }
            self?.projectChanged()
        }
        // Mattes a stopped run left in memory are written when the project is released; orphans go as in the AppKit UI.
        let previous = session.onReleaseProject
        session.onReleaseProject = { project, dirty in
            previous?(project, dirty)
            MagicMatteStore.shared.saveUnsaved(among: project.magicMatteCacheKeys)
            if dirty { MagicMatteStore.shared.forgetWritten() } else {
                MatteRemovalJournal.shared.sweep(MagicMatteStore.shared, keeping: project.magicMatteCacheKeys)
            }
        }
        // Hover and a pick see the frame in the file's pixel shape and deinterlaced, as the AppKit host sets them.
        tool.session.pixelAspect = { [weak session] url in
            session?.project.media.first { $0.path == url.path }?.info?.video?.displayPixelAspect ?? .square
        }
        tool.session.deinterlace = { [weak session] url in
            session?.project.media.first { $0.path == url.path }?.info?.video?.deinterlaceFieldOrder
        }
    }

    func refresh(target: Clip.ID?, magicOn: Bool, isPlaying: Bool) {
        self.target = target
        if magicOn != self.magicOn {
            self.magicOn = magicOn
            if magicOn { SubjectMaskEngine.shared.prewarm() } else {
                // The track a pick started belongs to the Magic tool: it ends with it (frames so far are saved).
                MaskTrackActivity.shared.stopAutomatic(reason: "the tool was switched")
                hoverPoint = nil; hoverPlane = nil
                stopUnusedSubjectModelLoad()
            }
        }
        overlay.maskTool = magicOn ? .magic : nil
        tool.refresh()
    }

    func hover(_ p: Vec2?, target: Clip.ID?) {
        self.target = target
        hoverPoint = p
        hoverTarget = target
        if p == nil { hoverPlane = nil } else { updateHover() }
    }

    /// Polled once per frame by the monitor (`hasHover`): the segmentation finishing or the soft matte arriving shows up
    /// without the pointer moving.
    var hasHover: Bool { updateHover(); return hoverPlane != nil }

    private func updateHover() {
        guard let p = hoverPoint else { hoverPlane = nil; return }
        let found: (label: UInt8, matte: SubjectMatte, soft: Bool, frame: Time)?
        if let id = hoverTarget, id != model.clip?.id {
            // An unselected clip under the pointer: its frame is previewed, nothing is selected.
            let clip = session.displayTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id }
            found = clip.flatMap { tool.previewMatte($0, localPlayhead: session.playhead - $0.start, at: p) }
        } else {
            found = tool.hoverMatte(at: p)
        }
        guard let hit = found else { hoverPlane = nil; return }
        let key = "hover:\(hoverTarget.map(\.uuidString) ?? ""):\(hit.label):\(hit.soft):\(hit.frame.value)/\(hit.frame.timescale)"
        if hoverPlane?.key == key { return }
        hoverPlane = (key, Self.plane(hit.matte, alpha: 0.45))
    }

    func click(_ p: Vec2, target: Clip.ID?, subtract: Bool, newMask: Bool) {
        self.target = target
        overlay.maskTool = .magic
        let tool = tool
        Task { @MainActor in await tool.click(p, subtract: subtract, newMask: newMask) }
    }

    /// The Mac `updateMaskTint` reads: a Face / Skin mask its narrowed matte, the whole person where that is missing;
    /// the tints are laid over each other (alpha 1 - (1 - a1)(1 - a2)...) in one white coverage picture.
    func maskTint(masks: [ClipMask.ID], pts: Double) -> MaskTintPicture {
        var waiting = false
        var found: [(key: String, plane: TintPlane)] = []
        for id in masks {
            if let k = model.magicPartKey(id) {
                if let a = tints.image(key: k, pts: pts, ready: {}) { found.append(("\(k)@\(pts)", a)); continue }
                if tints.isPending(key: k, pts: pts) { waiting = true }
            }
            guard let k = model.magicCacheKey(id) else { continue }
            if let a = tints.image(key: k, pts: pts, ready: {}) { found.append(("\(k)@\(pts)", a)); continue }
            if tints.isPending(key: k, pts: pts) { waiting = true }
        }
        if let h = hoverPlane { found.append(h) }
        guard let first = found.first?.plane else { return MaskTintPicture(waiting: waiting) }
        let size = (first.width, first.height)
        let keys = found.map(\.key) + ["\(tints.revision)"]
        if let made = tintMade, made.keys == keys { return MaskTintPicture(image: (made.image, made.generation), waiting: waiting) }
        let n = size.0 * size.1
        var inverse = [Float](repeating: 1, count: n)                 // product of (1 - a_i)
        var one: Float = 1, minusOne: Float = -1
        for f in found where f.plane.alpha.count == n {      // one clip: its mattes share a size
            var rest = [Float](repeating: 0, count: n)
            vDSP_vsmsa(f.plane.alpha, 1, &minusOne, &one, &rest, 1, vDSP_Length(n))
            vDSP_vmul(inverse, 1, rest, 1, &inverse, 1, vDSP_Length(n))
        }
        var k: Float = -255, b: Float = 255
        vDSP_vsmsa(inverse, 1, &k, &b, &inverse, 1, vDSP_Length(n))      // alpha = (1 - product) * 255
        var px = [UInt8](repeating: 255, count: n * 4)
        px.withUnsafeMutableBufferPointer { out in vDSP_vfixu8(inverse, 1, out.baseAddress! + 3, 4, vDSP_Length(n)) }
        tintGeneration += 1
        let image = RGBAImage(width: size.0, height: size.1, pixels: px)
        tintMade = (keys, image, tintGeneration)
        return MaskTintPicture(image: (image, tintGeneration), waiting: waiting)
    }
}
