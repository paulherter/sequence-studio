import Foundation
import SQAudioFX
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawTimeline
import SQEditorSession
import SQUIKit

/// The seams between the shared panel hosts (this package) and the platform app around them (the Windows port plan,
/// "Panel status: Mac on shared UI"): the Windows app (Windows/SQWinApp, D3D12 + FFmpeg + WASAPI) and the Mac shared UI
/// (App/Sources/SharedUI, Metal + AVFoundation) each implement them in a small backend file.
public enum AppPlatform {
    /// The Captions panel's note under Create Captions… while no transcriber runs on the shared UI.
    /// shortcut: one text for both platforms; the Mac transcriber (SQTranscribe) is not wired to the shared UI yet.
    public static let transcriptionHint = "Transcription is not available on the shared UI yet"
}

/// File choosers the panel hosts need beyond the shell's `ShellFilePicker` (modal, return nil when canceled).
@MainActor
public protocol PanelFileChooser: AnyObject {
    /// Captions > Import: an .srt / .vtt file.
    func chooseSubtitles() -> URL?
    /// Captions > Export SRT: where to write.
    func chooseSRTLocation(suggestedName: String) -> URL?
    /// Program monitor > Export Frame: where to write the PNG.
    func choosePNGLocation(suggestedName: String) -> URL?
    /// Marker List > Export CSV (File > Export Markers as CSV…): where to write.
    func chooseCSVLocation(suggestedName: String) -> URL?
    /// Color: LUT files (.cube, .3dl); `multiple` for Add LUTs to Library… (the Mac `allowsMultipleSelection`).
    func chooseLUTs(multiple: Bool) -> [URL]
}

/// The LUT files the choosers offer.
public enum LUTFileTypes {
    public static let extensions = ["cube", "3dl"]
}

/// A CPU copy of the picture the Program monitor shows: NV12 planes (luma, then interleaved chroma) or RGBA rows.
public struct AppPicture: Sendable {
    public var bytes: [UInt8]
    public var width: Int, height: Int
    public var fullRange: Bool
    public var rgba: Bool

    public init(bytes: [UInt8], width: Int, height: Int, fullRange: Bool, rgba: Bool) {
        self.bytes = bytes
        self.width = width
        self.height = height
        self.fullRange = fullRange
        self.rgba = rgba
    }
}

/// What the meters, scopes and monitor hosts need of the platform's Program engine beyond `ProgramEngine`: its picture
/// and the speaker-only monitoring stages. The Windows engine is one itself; the Mac taps `PlaybackEngine` (MacPictureTap).
@MainActor
public protocol AppPictureSource: AnyObject {
    /// A frame was composited (the monitor shows a picture, not the empty card).
    var hasPicture: Bool { get }
    /// Changes whenever the shown picture changes (scopes and uploads skip unchanged frames).
    var pictureGeneration: Int { get }
    /// The shown picture on the CPU (scopes); nil while none is readable yet.
    func scopePicture() -> AppPicture?
    /// Frames the playback skipped (the monitor's drop dot).
    var skippedFrames: Int { get }
    /// Listening volume / Dim: speakers only (meters and export unaffected).
    func setMonitorGain(_ setting: MonitorGain.Setting)
    /// Monitoring Solo / Mute per output channel: speakers only.
    func setChannelMonitor(_ state: ChannelMonitor)
}

/// One engine a shared monitor host drives (the Program engine, the Source engine, a pane of the slip / trim two-up):
/// its transport and timeline (`player`), its picture (`AppPictureSource`) and Export Frame. Windows: `WinProgramEngine`;
/// Mac: a `PlaybackEngine` behind MacMonitorEngine (App/Sources/SharedUI).
@MainActor
public protocol AppMonitorEngine: AppPictureSource {
    /// The transport and timeline the hosts drive (SourceMonitorCore, the two-up's seeks).
    var player: any ProgramEngine { get }
    /// Per frame: advance the engine's clock and decodes (an engine without a window layer renders here).
    func tick()
    /// The project's media changed (Windows: the engine's path table; the Mac resolver is shared, nothing to do).
    func setMedia(_ media: [MediaRef])
    /// Export Frame: the shown frame as a PNG where the user picks; outcome lines go to `status`.
    func exportFrame(suggestedName: String, files: (any PanelFileChooser)?, status: @escaping @MainActor @Sendable (String) -> Void)
}

extension AppMonitorEngine {
    /// Export Frame from the CPU picture (`scopePicture`): the default when the platform has no full-size render.
    /// shortcut: the shown picture, not a full-size render; upgrade per platform with a playback-quality render.
    public func exportShownFrame(suggestedName: String, files: (any PanelFileChooser)?, status: (String) -> Void) {
        guard let p = scopePicture() else { status("No frame to export"); return }
        guard let url = files?.choosePNGLocation(suggestedName: suggestedName) else { return }
        do {
            try p.rgbaImage.pngData().write(to: url)
            status("Exported \(url.lastPathComponent)")
        } catch {
            status("Export Frame failed: \(error.localizedDescription)")
        }
    }
}

extension AppPicture {
    /// The picture as 8-bit RGBA rows (NV12 converted).
    public var rgbaImage: RGBAImage {
        rgba ? RGBAImage(width: width, height: height, pixels: bytes)
             : RGBAImage(nv12: bytes, width: width, height: height, fullRange: fullRange)
    }
}

/// What the monitor hosts ask of the platform beyond the Program engine.
@MainActor
public protocol AppMonitorBackend: AnyObject {
    /// The Source monitor's own engine (with sound).
    func makeSourceEngine() -> any AppMonitorEngine
    /// A silent engine for one pane of the slip / trim two-up.
    func makeStillEngine() -> any AppMonitorEngine
    /// Thumbnails and waveforms (the timeline's media store; the Source waveform and the angle tiles read it).
    var timelineMedia: (any TimelineMediaSource)? { get }
}

/// The pointer shape the shared UI asks for; each platform maps it to its cursors (Windows IDC_* and drawn tool cursors,
/// Mac NSCursor and `TimelineCursors`). The panels' own requests come through `HostHover.cursor`.
public typealias AppPointerShape = DrawCursor

/// The portable pointer rules: what the window shows over the shared panels this frame.
public enum AppPointer {
    public struct Facts: Sendable, Equatable {
        /// The dock divider under the pointer (nil: none).
        public var divider: SplitAxis?
        /// The Keystones bar's edge under the pointer (resize).
        public var keystoneEdge = false
        /// The eyedropper samples.
        public var sampling = false
        /// A text editor without its own caret rect is open (the monitor's on-canvas text field).
        public var textEditing = false
        /// The pointer is over the Program picture with the Type tool (Create in Text mode).
        public var typeToolOverPicture = false
        /// The Hand tool over the timeline.
        public var handOverTimeline = false
        /// The shape the panel under the pointer asked for (`HostHover.cursor`: timeline tool cursors, resize edges).
        public var panel: DrawCursor?

        public init(divider: SplitAxis? = nil, keystoneEdge: Bool = false, sampling: Bool = false, textEditing: Bool = false,
                    typeToolOverPicture: Bool = false, handOverTimeline: Bool = false, panel: DrawCursor? = nil) {
            self.divider = divider
            self.keystoneEdge = keystoneEdge
            self.sampling = sampling
            self.textEditing = textEditing
            self.typeToolOverPicture = typeToolOverPicture
            self.handOverTimeline = handOverTimeline
            self.panel = panel
        }
    }

    /// The eyedropper wins, then dividers and edges (a drag starts there), then text, then the panel's request, then the
    /// tool's own shape.
    public static func shape(_ f: Facts) -> AppPointerShape {
        if f.sampling { return .crosshair }
        if let axis = f.divider { return axis == .horizontal ? .resizeLeftRight : .resizeUpDown }
        if f.keystoneEdge { return .resizeLeftRight }
        if f.textEditing || f.typeToolOverPicture { return .iBeam }
        if let p = f.panel { return p }
        if f.handOverTimeline { return .openHand }
        return .arrow
    }
}

/// The eyedropper's screen sample (color picker, text block rows, Color Key): Windows reads the desktop through GDI per
/// event (`WinScreenSample`); the Mac runs its own loupe window over every screen (`SQLoupe`, ScreenCaptureKit).
@MainActor
public protocol AppScreenSampler: AnyObject {
    /// The platform's own eyedropper (pointer, loupe and click outside the draw list); it answers `done` once (nil =
    /// canceled). Nil: the host samples per event with the two calls below and draws the loupe itself.
    var ownEyedropper: ((_ done: @escaping @MainActor (SQColorValue?) -> Void) -> Void)? { get }
    /// The screen color under the pointer (nil when unreadable).
    func colorUnderPointer() -> SQColorValue?
    /// The screen pixels around the pointer for the drawn loupe.
    func loupeUnderPointer() -> ColorLoupe?
}

/// The Mask tool's Magic mode: a segmenter picks the object under a click and stores its matte (Mac: the AppKit UI's
/// `MagicMaskTool`, Vision / Core ML; Windows: none yet, `MonitorHost.magic` stays nil and a click tells the status line).
@MainActor
public protocol AppMagicMasks: AnyObject {
    /// A Magic click at `p` (frame fraction) on the overlay's clip `target`: Option subtracts, Shift starts a new mask.
    func click(_ p: Vec2, target: Clip.ID?, subtract: Bool, newMask: Bool)
    /// Per frame while Magic is on, once when it goes off: the segmenter prepares the parked frame of `target`.
    func refresh(target: Clip.ID?, magicOn: Bool, isPlaying: Bool)
    /// Mask Tint (the Mac `EditorPanels.updateMaskTint`): the stored mattes of `masks` (Magic masks of the Effect
    /// Controls clip) at source time `pts` (seconds), laid over each other as one coverage picture (white, alpha = the
    /// 30 % tints composited). `image` nil: none is in yet; `waiting`: a read still runs, so the host keeps the last tint.
    func maskTint(masks: [ClipMask.ID], pts: Double) -> MaskTintPicture
    /// The pointer rests at `p` (frame fraction) on the overlay's clip with the Magic tool, or left the picture (nil): the
    /// segmenter may prepare a hover highlight, which `maskTint` then lays over the tint (the Mac AppKit hover highlight).
    func hover(_ p: Vec2?, target: Clip.ID?)
    /// A hover highlight is ready or pending for the shown frame: `maskTint` is asked even without a stored Magic mask.
    var hasHover: Bool { get }
}

/// One Mask Tint answer (`AppMagicMasks.maskTint`): the coverage picture with a generation that moves when it changes.
public struct MaskTintPicture {
    public var image: (RGBAImage, generation: Int)?
    public var waiting: Bool
    public init(image: (RGBAImage, generation: Int)? = nil, waiting: Bool = false) { self.image = image; self.waiting = waiting }
}

extension AppMagicMasks {
    /// A segmenter without stored mattes draws no tint.
    public func maskTint(masks: [ClipMask.ID], pts: Double) -> MaskTintPicture { MaskTintPicture() }
    public func hover(_ p: Vec2?, target: Clip.ID?) {}
    public var hasHover: Bool { false }
}
